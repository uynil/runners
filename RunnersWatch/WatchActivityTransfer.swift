import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchActivityTransfer: ObservableObject {
    @Published private(set) var status = "运动记录保留在手表，连接手机后同步。"
    private var task: Task<Void, Never>?
    private var confirmed: [UUID: String] = [:]
    private var receiptsLoaded = false
    private var outbox: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Runners/ActivityOutbox")
    }
    func receive(_ context: [String: Any]) {
        if !receiptsLoaded {
            receiptsLoaded = true
            if let raw = UserDefaults.standard.data(forKey: "confirmedActivities"),
               let saved = try? JSONDecoder().decode([UUID: String].self, from: raw) { confirmed = saved }
        }
        guard let raw = context["activityReceipts"] as? Data,
              let receipts = try? JSONDecoder().decode([ActivityReceipt].self, from: raw) else { return }
        for receipt in receipts {
            let url = outbox.appendingPathComponent(receipt.id.uuidString + ".runnersactivity")
            if let data = try? Data(contentsOf: url), MapBundleStorage.digest(data) == receipt.checksum {
                confirmed[receipt.id] = receipt.checksum
                try? FileManager.default.removeItem(at: url)
                status = "手机已校验保存运动记录；手表原始记录保留。"
            }
        }
        if let data = try? JSONEncoder().encode(confirmed) { UserDefaults.standard.set(data, forKey: "confirmedActivities") }
    }

    func sync(session: WCSession?) {
        guard task == nil, let session, session.activationState == .activated else { return }
        receive(session.receivedApplicationContext)
        #if targetEnvironment(simulator)
        guard session.isReachable else { status = "模拟器请同时打开两端 App，再重试同步。"; return }
        #endif
        task = Task {
            defer { task = nil }
            do {
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Runs")
                guard FileManager.default.fileExists(atPath: root.path) else { return }
                let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                for folder in folders {
                    let summaryURL = folder.appendingPathComponent("summary.json"), samplesURL = folder.appendingPathComponent("samples.ndjson")
                    guard (try? summaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= 256 * 1_024,
                          (try? samplesURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max <= 16 * 1_024 * 1_024,
                          let summary = try? Data(contentsOf: summaryURL), let samples = try? Data(contentsOf: samplesURL) else { continue }
                    var archive = ActivityArchive(summaryData: summary, samplesData: samples)
                    #if targetEnvironment(simulator)
                    archive.simulated = true
                    #endif
                    guard let id = try? archive.summary.id else { continue } // Never send an active or incomplete run.
                    let data = try ActivityStorage.encode(archive), checksum = MapBundleStorage.digest(data)
                    guard confirmed[id] != checksum else { continue }
                    try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
                    let url = outbox.appendingPathComponent(id.uuidString + ".runnersactivity")
                    let files = try FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: [.fileSizeKey])
                    let used = try files.filter { $0.lastPathComponent != url.lastPathComponent }
                        .reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
                    guard used + data.count <= MapBundleStorage.quotaBytes else { throw MapError.invalid("运动传输队列已满，原始记录仍在手表。") }
                    #if targetEnvironment(simulator)
                    try data.write(to: url, options: .atomic)
                    status = "模拟器正在回传运动记录"
                    let transferID = MapChunk.transferID(for: checksum)
                    // One archive per run is sent serially; completed duplicate delivery is idempotent on the phone.
                    for offset in stride(from: 0, to: data.count, by: MapChunk.size) {
                        try Task.checkCancellation()
                        let end = min(data.count, offset + MapChunk.size)
                        let chunk = MapChunk(id: transferID, checksum: checksum, total: data.count, offset: offset, data: data.subdata(in: offset..<end))
                        try await SimulatorConnectivity.send(["simulatorActivityChunk": JSONEncoder().encode(chunk)], session: session)
                    }
                    status = "运动已送达，等待手机持久保存回执"
                    #else
                    if session.outstandingFileTransfers.contains(where: { $0.file.metadata?["activityID"] as? String == id.uuidString }) { continue }
                    try data.write(to: url, options: .atomic)
                    session.transferFile(url, metadata: ["kind": "activity", "activityID": id.uuidString, "checksum": checksum])
                    status = "运动已排队，等待手机接收"
                    #endif
                }
                receive(session.receivedApplicationContext)
            } catch { status = "运动同步失败，可重试；原始记录保留。" }
        }
    }

    func failed() { status = "运动传输未完成，可重试；原始记录保留。" }
}
