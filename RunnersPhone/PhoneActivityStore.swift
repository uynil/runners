import Foundation
import Combine

@MainActor
final class PhoneActivityStore: ObservableObject {
    struct Entry: Identifiable {
        let archive: ActivityArchive
        let summary: ActivitySummary
        let receipt: ActivityReceipt
        var id: UUID { summary.id }
    }
    @Published private(set) var entries: [Entry] = []
    @Published var error: String?
    @Published var syncMessage: String?
    nonisolated static var storage: ActivityStorage {
        ActivityStorage(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runners/Activities"))
    }
    init() { reload() }
    func reload() {
        do {
            entries = try Self.storage.all().map { Entry(archive: $0.0, summary: try $0.0.summary, receipt: $0.1) }
                .sorted { $0.summary.startedAt > $1.summary.startedAt }
            error = nil
        } catch { self.error = "运动记录读取失败，原文件已保留。" }
    }
    func remove(_ id: UUID) {
        do { try FileManager.default.removeItem(at: Self.storage.fileURL(id)); reload() }
        catch { self.error = "运动记录删除失败。" }
    }
}
