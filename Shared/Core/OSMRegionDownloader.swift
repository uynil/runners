import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetch bounded OSM geometry regions and keep verified responses for retries.
struct OSMRegionDownloader {
    typealias Fetch = (URLRequest, Int) async throws -> Data
    var fetch: Fetch = Self.fetchData
    static let regionKey = MapTileID(z: 0, x: 0, y: 0)
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    static func fetchData(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        let (url, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: url) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw MapError.invalid(status == 429 ? "OSM 数据服务繁忙，请稍后手动重试。" : "OSM 数据服务返回错误（\(status)）。")
        }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= maximumBytes else {
            throw MapError.invalid("区域数据超过 4 MB，请缩小范围。")
        }
        return try Data(contentsOf: url)
    }

    func download(job: MapDownloadJob, endpoint: URL, storage: MapJobStorage,
                  progress: (Int, Int, Int64) async throws -> Void) async throws -> RouteMapBundle {
        let regions = job.coverageRegions ?? [job.bounds]
        let source = endpoint.absoluteString
        var features: [MapFeature] = []
        var seen = Set<Int64>()
        var points = 0
        var bytes: Int64 = 0
        for (index, region) in regions.enumerated() {
            try Task.checkCancellation()
            let (request, _) = try MapDownloader.request(bounds: region, endpoint: endpoint)
            let key = MapTileID(z: Self.regionKey.z, x: index, y: Self.regionKey.y)
            let cached = try storage.cachedTile(job.id, key, source: source)
            let data: Data
            if let cached { data = cached }
            else { data = try await fetch(request, Self.maximumResponseBytes) }
            try Task.checkCancellation()
            guard data.count <= Self.maximumResponseBytes else { throw MapError.invalid("区域数据超过 4 MB，请缩小范围。") }
            let parsed = try OfflineMap.parse(data, bounds: region, sourceURL: source, allowsEmpty: regions.count > 1)
            for feature in parsed.features where seen.insert(feature.id).inserted {
                features.append(feature)
                points += feature.points.count
            }
            guard features.count <= 20_000, points <= 200_000 else {
                throw MapError.invalid("合并后的地图要素超过上限，请缩小缓冲范围或拆分线路。")
            }
            if cached == nil { try storage.saveTile(data, job: job.id, tile: key, source: source) }
            bytes += Int64(data.count)
            try await progress(index + 1, regions.count, bytes)
        }
        let map = OfflineMap(bounds: job.bounds, features: features, sourceURL: source,
                             downloadedAt: job.createdAt, provider: "osm", coverageRegions: job.coverageRegions)
        let bundle = RouteMapBundle(route: job.route, map: map)
        _ = try MapBundleStorage.encode(bundle)
        try Task.checkCancellation()
        return bundle
    }
}
