import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchMapReceiver: NSObject, ObservableObject, WCSessionDelegate {
    let activities = WatchActivityTransfer()
    @Published private(set) var bundles: [RouteMapBundle] = []
    @Published private(set) var error: String?
    private let session: WCSession?
    private var activityProtected = true
    private var pendingNavigationSettings: NavigationSettings?
    private static var removalURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runners/map-removals.json")
    }
    private static var storage: MapBundleStorage {
        MapBundleStorage(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runners/Maps"))
    }

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        reload()
        session?.delegate = self
        session?.activate()
    }

    func syncActivities() { activities.sync(session: session) }

    func reload() {
        do {
            let result = try Self.storage.scan()
            bundles = result.bundles.sorted { $0.map.downloadedAt > $1.map.downloadedAt }
            error = result.invalidCount > 0 ? "有 \(result.invalidCount) 个地图包损坏，请从手机重新同步；其他地图可用。" : nil
        }
        catch { self.error = error.localizedDescription }
    }

    func remove(_ id: UUID) {
        guard !activityProtected else { error = "运动期间不能移除地图。"; return }
        do { try Self.storage.remove(id); reload(); acknowledge() }
        catch { self.error = error.localizedDescription }
    }

    func setActivityProtected(_ value: Bool) {
        activityProtected = value
        if !value { applyNavigationSettings(); processRemovals() }
    }

    private func receiveNavigationSettings(_ data: Data?) {
        guard let data, let settings = try? JSONDecoder().decode(NavigationSettings.self, from: data),
              settings.version != NavigationSettings.load()?.version else { return }
        pendingNavigationSettings = settings
        applyNavigationSettings()
    }

    private func applyNavigationSettings() {
        guard !activityProtected, let settings = pendingNavigationSettings else { return }
        do {
            try settings.save()
            pendingNavigationSettings = nil
            acknowledge()
        } catch { self.error = "导航设置保存失败，等待重试。" }
    }

    private func processRemovals() {
        guard !activityProtected else { return }
        do {
            var queue = try MapRemovalQueue.load(from: Self.removalURL)
            try queue.apply(to: Self.storage, activityProtected: activityProtected)
            try queue.save(to: Self.removalURL)
            reload(); acknowledge()
        } catch { self.error = "地图移除待重试：\(error.localizedDescription)" }
    }

    #if targetEnvironment(simulator)
    nonisolated private static let chunkReceiver = MapChunkReceiver(directory:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runners/SimulatorIncoming"))

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let raw = message["simulatorMapChunk"] as? Data {
            do {
                let chunk = try JSONDecoder().decode(MapChunk.self, from: raw)
                if let data = try Self.chunkReceiver.accept(chunk) {
                    let storage = MapBundleStorage(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runners/Maps"))
                    try storage.saveData(data)
                    Self.chunkReceiver.finish(chunk.id)
                    Task { @MainActor in self.reload(); self.acknowledge() }
                }
                replyHandler(["ok": true])
            } catch { replyHandler(["error": error.localizedDescription]) }
        } else if let raw = message["simulatorRemoveMap"] as? Data {
            let reply = SimulatorReply(replyHandler)
            Task { @MainActor in
                do { try self.acceptRemoval(raw); reply.call(["ok": true]) }
                catch { reply.call(["error": error.localizedDescription]) }
            }
        } else if message["simulatorRequestActivities"] as? Bool == true {
            let reply = SimulatorReply(replyHandler)
            Task { @MainActor in self.syncActivities(); reply.call(["ok": true]) }
        } else { replyHandler(["error": "未知模拟器请求"]) }
    }
    #endif

    private func acceptRemoval(_ data: Data) throws {
        let command = try JSONDecoder().decode(MapRemovalCommand.self, from: data)
        var queue = try MapRemovalQueue.load(from: Self.removalURL)
        if !queue.pending.contains(where: { $0.id == command.id }), !queue.results.contains(where: { $0.commandID == command.id }) {
            guard queue.pending.count < 20 else { throw MapError.invalid("地图移除队列已满。") }
            queue.pending.append(command)
            try queue.save(to: Self.removalURL)
        }
        processRemovals()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if userInfo["requestActivities"] as? Bool == true {
            Task { @MainActor in self.syncActivities() }
            return
        }
        guard let data = userInfo["removeMap"] as? Data else { return }
        Task { @MainActor in
            do { try self.acceptRemoval(data) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func acknowledge() {
        do {
            let receipts = try bundles.map { bundle -> MapReceipt in
                let data = try Data(contentsOf: Self.storage.fileURL(bundle.id))
                let savedAt = try Self.storage.fileURL(bundle.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
                return MapReceipt(routeID: bundle.id, checksum: MapBundleStorage.digest(data), receivedAt: savedAt)
            }
            let used = try bundles.reduce(Int64(0)) { total, bundle in
                total + Int64(try Self.storage.fileURL(bundle.id).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
            let available = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
            let report = MapStorageReport(mapBytes: used, availableBytes: available, reportedAt: Date(), supportedMapSchema: 3)
            let removals = try MapRemovalQueue.load(from: Self.removalURL).results
            var context: [String: Any] = ["mapReceipts": try JSONEncoder().encode(receipts),
                                          "mapStorage": try JSONEncoder().encode(report),
                                          "mapRemovals": try JSONEncoder().encode(removals)]
            if let settings = NavigationSettings.load() { context["navigationSettingsApplied"] = settings.version.uuidString }
            try session?.updateApplicationContext(context)
        } catch { self.error = "回执待重试：\(error.localizedDescription)" }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The system removes its temporary file after this callback. Persist before returning.
        do {
            let storage = MapBundleStorage(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Runners/Maps"))
            let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= MapBundleStorage.maximumBytes else { throw MapError.invalid("地图包超过大小限制。") }
            try storage.saveData(Data(contentsOf: file.fileURL))
            Task { @MainActor in self.reload(); self.acknowledge() }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor in self.error = "地图接收失败：\(message)" }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let receipts = applicationContext["activityReceipts"] as? Data
        let settings = applicationContext["navigationSettings"] as? Data
        Task { @MainActor in
            if let receipts { self.activities.receive(["activityReceipts": receipts]) }
            self.receiveNavigationSettings(settings)
        }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard fileTransfer.file.metadata?["kind"] as? String == "activity", error != nil else { return }
        Task { @MainActor in self.activities.failed() }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let message = error?.localizedDescription
        let settings = session.receivedApplicationContext["navigationSettings"] as? Data
        Task { @MainActor in
            if let message { self.error = message } else {
                self.receiveNavigationSettings(settings)
                self.reload(); self.acknowledge(); self.syncActivities()
            }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.acknowledge(); self.syncActivities() }
    }
}
