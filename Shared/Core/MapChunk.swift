import Foundation

/// Foreground simulator transport only. Production uses WCSession.transferFile.
struct MapChunk: Codable {
    let id: UUID
    let checksum: String
    let total: Int
    let offset: Int
    let data: Data
    static let size = 32 * 1_024
    static func transferID(for checksum: String) -> UUID {
        let chars = Array(checksum.prefix(32))
        // Callers supply SHA-256 digests generated locally.
        precondition(chars.count == 32 && chars.allSatisfy { $0.isHexDigit })
        return UUID(uuidString: String(chars[0..<8]) + "-" + String(chars[8..<12]) + "-" + String(chars[12..<16]) + "-" + String(chars[16..<20]) + "-" + String(chars[20..<32]))!
    }
}

final class MapChunkReceiver: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    init(directory: URL) { self.directory = directory }

    func accept(_ chunk: MapChunk) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard (1...MapBundleStorage.maximumBytes).contains(chunk.total), chunk.offset >= 0,
              !chunk.data.isEmpty, chunk.data.count <= MapChunk.size,
              chunk.offset <= chunk.total - chunk.data.count,
              chunk.checksum.count == 64, chunk.checksum.allSatisfy({ $0.isHexDigit }) else {
            throw MapError.invalid("模拟器分块数据无效。")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Bound abandoned transfers; never let test traffic fill the simulator disk.
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        let url = directory.appendingPathComponent(chunk.id.uuidString + ".part")
        let manifest = directory.appendingPathComponent(chunk.id.uuidString + ".json")
        let identity = "\(chunk.checksum):\(chunk.total)"
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard try String(contentsOf: manifest, encoding: .utf8) == identity else { throw MapError.invalid("模拟器传输版本不匹配。") }
        } else {
            guard chunk.offset == 0, files.count < 40 else { throw MapError.invalid("模拟器传输需从首块开始，或清理未完成传输。") }
            try identity.write(to: manifest, atomically: true, encoding: .utf8)
            try Data().write(to: url, options: .atomic)
        }
        let used = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard used + chunk.data.count <= MapBundleStorage.quotaBytes else { throw MapError.invalid("模拟器临时传输空间不足。") }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard UInt64(chunk.offset) <= size else { throw MapError.invalid("模拟器分块顺序错误，请重试。") }
        if size >= UInt64(chunk.offset + chunk.data.count) {
            try handle.seek(toOffset: UInt64(chunk.offset))
            guard try handle.read(upToCount: chunk.data.count) == chunk.data else { throw MapError.invalid("重复分块内容不一致。") }
        } else {
            try handle.truncate(atOffset: UInt64(chunk.offset))
            try handle.seek(toOffset: UInt64(chunk.offset))
            try handle.write(contentsOf: chunk.data)
            try handle.synchronize()
        }
        guard try handle.seekToEnd() == chunk.total else { return nil }
        let data = try Data(contentsOf: url)
        guard MapBundleStorage.digest(data) == chunk.checksum else { throw MapError.invalid("模拟器文件校验失败。") }
        return data
    }

    func finish(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".part"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
}
