import Foundation

enum DownloadPhase: String, Codable {
    case queued, downloading, paused, failed, completed
    var title: String {
        switch self {
        case .queued: return "等待下载"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .failed: return "下载失败"
        case .completed: return "手机已保存"
        }
    }
}

struct MapDownloadJob: Codable, Identifiable {
    var id = UUID()
    let route: PlannedRoute
    let bounds: MapBounds
    let zoom: Int
    var coverageRegions: [MapBounds]? = nil
    var phase: DownloadPhase = .queued
    var completedTiles = 0
    var totalTiles = 0
    var receivedBytes: Int64 = 0
    var error: String?
    let createdAt: Date

    init(route: PlannedRoute, bounds: MapBounds, zoom: Int, coverageRegions: [MapBounds]? = nil, createdAt: Date = Date()) throws {
        guard bounds.isValid, !route.segments.isEmpty, route.pointCount <= 100_000,
              route.segments.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.isValid && bounds.contains($0) } }) else {
            throw MapError.invalid("选区需要覆盖整条线路。")
        }
        self.route = route; self.bounds = bounds; self.zoom = zoom; self.createdAt = createdAt
        let regions = coverageRegions ?? [bounds]
        guard (1...64).contains(regions.count),
              regions.allSatisfy({ $0.isValid && $0.areaSquareKilometers <= 100 && bounds.contains($0) }),
              coverageRegions == nil || route.segments.allSatisfy({ MapBounds.covers($0, with: regions) }) else {
            throw MapError.invalid("地图下载区域无效。")
        }
        self.coverageRegions = coverageRegions
        totalTiles = regions.count
    }
}

struct MapJobStorage {
    let directory: URL
    var catalog: URL { directory.appendingPathComponent("downloads.json") }
    func load() throws -> [MapDownloadJob] {
        guard FileManager.default.fileExists(atPath: catalog.path) else { return [] }
        return try JSONDecoder().decode([MapDownloadJob].self, from: Data(contentsOf: catalog))
    }
    func save(_ jobs: [MapDownloadJob]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: catalog, options: .atomic)
    }
    func tileURL(_ job: UUID, _ tile: MapTileID, source: String = "") -> URL {
        let prefix = source.isEmpty ? "" : MapBundleStorage.digest(Data(source.utf8)) + "-"
        return directory.appendingPathComponent(job.uuidString).appendingPathComponent(prefix + tile.key + ".json")
    }
    func cachedTile(_ job: UUID, _ tile: MapTileID, source: String = "") throws -> Data? {
        let url = tileURL(job, tile, source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 6 * 1_024 * 1_024 else { return nil }
        guard let envelope = try? JSONDecoder().decode(MapBundleStorage.Envelope.self, from: Data(contentsOf: url)),
              envelope.payload.count <= 4 * 1_024 * 1_024,
              MapBundleStorage.digest(envelope.payload) == envelope.sha256 else { return nil }
        return envelope.payload
    }
    func saveTile(_ data: Data, job: UUID, tile: MapTileID, source: String = "") throws {
        guard data.count <= 4 * 1_024 * 1_024 else { throw MapError.invalid("地图分块过大。") }
        let envelope = MapBundleStorage.Envelope(sha256: MapBundleStorage.digest(data), payload: data)
        let encoded = try JSONEncoder().encode(envelope)
        let url = tileURL(job, tile, source: source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let used = try stagingBytes()
        let previous = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard used - Int64(previous) + Int64(encoded.count) <= 150 * 1_024 * 1_024 else {
            throw MapError.invalid("未完成下载占用已达到 150 MB，请移除其他下载任务。")
        }
        try encoded.write(to: url, options: .atomic)
    }
    func stagingBytes() throws -> Int64 {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in iterator {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if attributes.isRegularFile == true { size += Int64(attributes.fileSize ?? 0) }
        }
        return size
    }
    func removeTiles(_ job: UUID) throws {
        let url = directory.appendingPathComponent(job.uuidString)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
