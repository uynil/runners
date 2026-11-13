import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchConnection: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var activated = false
    @Published private(set) var paired = false
    @Published private(set) var installed = false
    @Published private(set) var reachable = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var receipts: [UUID: MapReceipt] = [:]
    @Published private(set) var transfers: [UUID: String] = [:]
    @Published private(set) var storageReport: MapStorageReport?
    @Published private(set) var removals: [UUID: String] = [:]
    @Published private(set) var navigationSettings = NavigationSettings.load() ?? NavigationSettings()
    @Published private var appliedNavigationSettings: UUID?
    private var pendingRemovals: [UUID: MapRemovalCommand] = [:]
    let activities = PhoneActivityStore()
    private let session: WCSession?
    #if targetEnvironment(simulator)
    private var simulatorTasks: [UUID: Task<Void, Never>] = [:]
    @Published private var simulatorProgress: [UUID: Double] = [:]
    #endif

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        try? navigationSettings.save()
        if let data = UserDefaults.standard.data(forKey: "pendingMapRemovals"),
           let pending = try? JSONDecoder().decode([UUID: MapRemovalCommand].self, from: data) {
            pendingRemovals = pending
            for id in pending.keys { removals[id] = "移除请求待确认，可重试相同请求" }
        }
        session?.delegate = self
        session?.activate()
    }

    func refresh() {
        guard let session else { error = "此设备不支持 Apple Watch 连接。"; return }
        activated = session.activationState == .activated
        guard activated else { session.activate(); return }
        paired = session.isPaired
        installed = session.isWatchAppInstalled
        reachable = session.isReachable
        checkedAt = Date()
        receive(session.receivedApplicationContext)
        acknowledgeActivities()
        #if !targetEnvironment(simulator)
        for transfer in session.outstandingFileTransfers {
            if let raw = transfer.file.metadata?["routeID"] as? String, let id = UUID(uuidString: raw) {
                transfers[id] = "等待系统传输"
            }
        }
        #endif
    }

    func send(_ bundle: RouteMapBundle) {
        guard let session, activated, paired, installed else { error = "请先配对 Watch 并安装 Runners。"; return }
        guard bundle.schemaVersion <= (storageReport?.supportedMapSchema ?? 1) else {
            error = "请先更新并打开 Watch 上的 Runners，等待地图同步能力确认。"; return
        }
        do {
            let data = try MapBundleStorage.encode(bundle)
            let checksum = MapBundleStorage.digest(data)
            if receipts[bundle.id]?.checksum == checksum { transfers[bundle.id] = "Watch 已保存线路和地图"; return }
            #if targetEnvironment(simulator)
            sendInSimulator(bundle, data: data, checksum: checksum, session: session)
            return
            #else
            guard !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["checksum"] as? String == checksum }) else {
                transfers[bundle.id] = "已排队，等待系统传输"; return
            }
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runners/Outbox")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pending = Set(session.outstandingFileTransfers.map { $0.file.fileURL.standardizedFileURL })
            for old in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where !pending.contains(old.standardizedFileURL) {
                try FileManager.default.removeItem(at: old)
            }
            let used = try pending.reduce(0) { total, url in
                total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            guard used + data.count <= MapBundleStorage.quotaBytes else { throw MapError.invalid("传输队列空间已满，请等待已排队地图传输完成。") }
            let url = folder.appendingPathComponent(checksum + ".runnersmap")
            try data.write(to: url, options: .atomic)
            session.transferFile(url, metadata: ["routeID": bundle.id.uuidString, "checksum": checksum])
            transfers[bundle.id] = "已排队，等待 Watch 接收"
            error = nil
            #endif
        } catch { self.error = error.localizedDescription }
    }

    func status(for bundle: RouteMapBundle) -> String {
        if let data = try? MapBundleStorage.encode(bundle), receipts[bundle.id]?.checksum == MapBundleStorage.digest(data) {
            return "Watch 已校验保存线路和地图"
        }
        if hasTransfer(bundle.id) { return "正在传输或等待 Watch 接收" }
        if let status = transfers[bundle.id], !status.hasPrefix("Watch") { return status }
        return receipts[bundle.id] == nil ? "尚未发送到 Watch" : "Watch 已有其他版本，当前版本未确认"
    }

    func hasTransfer(_ id: UUID) -> Bool {
        #if targetEnvironment(simulator)
        return simulatorTasks[id] != nil
        #else
        return session?.outstandingFileTransfers.contains { $0.file.metadata?["routeID"] as? String == id.uuidString } ?? false
        #endif
    }
    func progress(for id: UUID) -> Double? {
        #if targetEnvironment(simulator)
        return simulatorProgress[id]
        #else
        guard let file = session?.outstandingFileTransfers.last(where: { $0.file.metadata?["routeID"] as? String == id.uuidString }),
              file.progress.totalUnitCount > 0 else { return nil }
        return min(1, max(0, file.progress.fractionCompleted))
        #endif
    }
    func cancelTransfer(_ id: UUID) {
        #if targetEnvironment(simulator)
        simulatorTasks[id]?.cancel()
        #endif
        for file in session?.outstandingFileTransfers ?? [] where file.file.metadata?["routeID"] as? String == id.uuidString {
            file.cancel()
        }
        transfers[id] = "已取消传输；若文件已到表端，以实际回执为准"
    }

    #if targetEnvironment(simulator)
    private func sendInSimulator(_ bundle: RouteMapBundle, data: Data, checksum: String, session: WCSession) {
        guard simulatorTasks[bundle.id] == nil else { return }
        guard session.isReachable else { error = "模拟器需要同时打开手机和手表 App。"; return }
        // Clear unsupported file transfers left by older simulator builds.
        for file in session.outstandingFileTransfers where file.file.metadata?["routeID"] as? String == bundle.id.uuidString { file.cancel() }
        simulatorProgress[bundle.id] = 0
        transfers[bundle.id] = "模拟器前台传输中"
        simulatorTasks[bundle.id] = Task {
            defer { simulatorTasks[bundle.id] = nil; simulatorProgress[bundle.id] = nil }
            do {
                let uuid = MapChunk.transferID(for: checksum)
                for offset in stride(from: 0, to: data.count, by: MapChunk.size) {
                    try Task.checkCancellation()
                    let end = min(data.count, offset + MapChunk.size)
                    let chunk = MapChunk(id: uuid, checksum: checksum, total: data.count, offset: offset, data: data.subdata(in: offset..<end))
                    try await SimulatorConnectivity.send(["simulatorMapChunk": JSONEncoder().encode(chunk)], session: session)
                    simulatorProgress[bundle.id] = Double(end) / Double(data.count)
                }
                transfers[bundle.id] = "模拟器文件已送达，等待 Watch 保存回执"
                error = nil
            } catch {
                transfers[bundle.id] = Task.isCancelled ? "模拟器传输已取消" : "模拟器传输失败，可重试：\(error.localizedDescription)"
            }
        }
    }
    #endif

    func removeFromWatch(_ id: UUID) {
        guard let session, activated, paired, installed, let receipt = receipts[id] else {
            error = "需要有效的 Watch 地图回执才能移除。"; return
        }
        let command = pendingRemovals[id] ?? MapRemovalCommand(mapID: id, expectedChecksum: receipt.checksum)
        do {
            let data = try JSONEncoder().encode(command)
            pendingRemovals[id] = command
            UserDefaults.standard.set(try JSONEncoder().encode(pendingRemovals), forKey: "pendingMapRemovals")
            if !session.outstandingUserInfoTransfers.contains(where: { ($0.userInfo["removeMap"] as? Data) == data }) {
                #if targetEnvironment(simulator)
                Task {
                    do { try await SimulatorConnectivity.send(["simulatorRemoveMap": data], session: session) }
                    catch { removals[id] = "模拟器移除发送失败，可重试：\(error.localizedDescription)" }
                }
                #else
                session.transferUserInfo(["removeMap": data])
                #endif
            }
            removals[id] = "移除请求已排队，等待 Watch 确认"
        } catch { self.error = "无法创建地图移除请求。" }
    }

    private func receive(_ context: [String: Any]) {
        appliedNavigationSettings = (context["navigationSettingsApplied"] as? String).flatMap(UUID.init(uuidString:))
        if let data = context["mapRemovals"] as? Data, let decoded = try? JSONDecoder().decode([MapRemovalReceipt].self, from: data) {
            for receipt in decoded where pendingRemovals[receipt.mapID]?.id == receipt.commandID {
                removals[receipt.mapID] = receipt.message
                pendingRemovals[receipt.mapID] = nil
            }
            if let data = try? JSONEncoder().encode(pendingRemovals) { UserDefaults.standard.set(data, forKey: "pendingMapRemovals") }
        }
        if let data = context["mapStorage"] as? Data {
            storageReport = try? JSONDecoder().decode(MapStorageReport.self, from: data)
        }
        guard let data = context["mapReceipts"] as? Data,
              let decoded = try? JSONDecoder().decode([MapReceipt].self, from: data) else { return }
        receipts = Dictionary(decoded.map { ($0.routeID, $0) }, uniquingKeysWith: { _, newer in newer })
        for receipt in decoded { transfers[receipt.routeID] = "Watch 已校验保存线路和地图" }
    }

    func requestActivitySync() {
        guard let session, activated, paired, installed else {
            activities.error = "请先连接已安装 Runners 的 Watch；本地历史仍可查看。"; return
        }
        #if targetEnvironment(simulator)
        Task {
            do {
                try await SimulatorConnectivity.send(["simulatorRequestActivities": true], session: session)
                activities.syncMessage = "已请求 Watch 重试同步；收到记录后更新列表。"
            } catch { activities.error = "模拟器请同时打开两端 App 后重试。" }
        }
        #else
        if !session.outstandingUserInfoTransfers.contains(where: { $0.userInfo["requestActivities"] as? Bool == true }) {
            session.transferUserInfo(["requestActivities": true])
        }
        activities.syncMessage = "同步请求已排队，等待 Watch 处理。"
        #endif
    }

    var navigationSettingsStatus: String {
        guard activated, paired, installed else { return "等待 Watch 连接" }
        return appliedNavigationSettings == navigationSettings.version ? "Watch 已应用" : "等待 Watch 应用"
    }

    func updateNavigationSettings(junctionHaptics: Bool? = nil, offRouteHaptics: Bool? = nil) {
        var updated = navigationSettings
        updated.version = UUID()
        updated.junctionHaptics = junctionHaptics ?? updated.junctionHaptics
        updated.offRouteHaptics = offRouteHaptics ?? updated.offRouteHaptics
        do {
            try updated.save()
            navigationSettings = updated
            if activated { acknowledgeActivities() }
        } catch { self.error = "无法保存导航设置。" }
    }

    private func acknowledgeActivities() {
        activities.reload()
        do {
            let receipts = Array(activities.entries.prefix(100)).map(\.receipt)
            let context = ["activityReceipts": try JSONEncoder().encode(receipts),
                           "navigationSettings": try JSONEncoder().encode(navigationSettings)]
            if let session, (session.applicationContext as NSDictionary) != (context as NSDictionary) {
                try session.updateApplicationContext(context)
            }
        } catch { activities.error = "运动接收回执与导航设置同步待重试。" }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["kind"] as? String == "activity" else { return }
        do {
            guard (try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MapBundleStorage.maximumBytes else {
                throw MapError.invalid("运动文件超过大小限制。")
            }
            try PhoneActivityStore.storage.save(Data(contentsOf: file.fileURL))
            Task { @MainActor in self.acknowledgeActivities(); self.activities.syncMessage = "运动记录已校验保存在手机。" }
        } catch {
            Task { @MainActor in self.activities.error = "运动接收失败，Watch 原始记录保留。" }
        }
    }

    #if targetEnvironment(simulator)
    nonisolated private static let activityChunks = MapChunkReceiver(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runners/SimulatorActivities"))
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let raw = message["simulatorActivityChunk"] as? Data else { replyHandler(["error": "未知模拟器请求"]); return }
        do {
            let chunk = try JSONDecoder().decode(MapChunk.self, from: raw)
            if let data = try Self.activityChunks.accept(chunk) {
                try PhoneActivityStore.storage.save(data)
                Self.activityChunks.finish(chunk.id)
                Task { @MainActor in self.acknowledgeActivities(); self.activities.syncMessage = "运动记录已校验保存在手机。" }
            }
            replyHandler(["ok": true])
        } catch { replyHandler(["error": error.localizedDescription]) }
    }
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext["mapReceipts"] as? Data
        let storage = applicationContext["mapStorage"] as? Data
        let removals = applicationContext["mapRemovals"] as? Data
        let settings = applicationContext["navigationSettingsApplied"] as? String
        Task { @MainActor in
            var context: [String: Any] = [:]
            if let data { context["mapReceipts"] = data }
            if let storage { context["mapStorage"] = storage }
            if let removals { context["mapRemovals"] = removals }
            if let settings { context["navigationSettingsApplied"] = settings }
            self.receive(context)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let raw = fileTransfer.file.metadata?["routeID"] as? String
        let message = error?.localizedDescription
        if error == nil, fileTransfer.file.fileURL.deletingLastPathComponent().lastPathComponent == "Outbox" {
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
        Task { @MainActor in
            if let raw, let id = UUID(uuidString: raw), self.receipts[id] == nil || message != nil {
                self.transfers[id] = message.map { "传输失败：\($0)" } ?? "文件已传送，等待 Watch 校验确认"
            }
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in self.error = message; self.refresh() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        Task { @MainActor in self.activated = false; self.reachable = false }
    }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            self.activated = false
            self.paired = false
            self.installed = false
            self.reachable = false
            self.checkedAt = nil
            self.receipts = [:]
            self.transfers = [:]
            self.storageReport = nil
            self.appliedNavigationSettings = nil
            self.removals = [:]
            self.pendingRemovals = [:]
            UserDefaults.standard.removeObject(forKey: "pendingMapRemovals")
            self.session?.activate()
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }
}
