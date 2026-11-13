import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OSM geometry is fetched as one bounded region, never as scraped image tiles.
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
        let (request, _) = try MapDownloader.request(bounds: job.bounds, endpoint: endpoint)
        try Task.checkCancellation()
        let cached = try storage.cachedTile(job.id, Self.regionKey)
        let data: Data
        if let cached { data = cached }
        else { data = try await fetch(request, Self.maximumResponseBytes) }
        guard data.count <= Self.maximumResponseBytes else { throw MapError.invalid("区域数据超过 4 MB，请缩小范围。") }
        let parsed = try OfflineMap.parse(data, bounds: job.bounds, sourceURL: endpoint.absoluteString)
        let map = OfflineMap(bounds: job.bounds, features: parsed.features, sourceURL: endpoint.absoluteString,
                             downloadedAt: job.createdAt, provider: "osm")
        let bundle = RouteMapBundle(route: job.route, map: map)
        _ = try MapBundleStorage.encode(bundle)
        try Task.checkCancellation()
        if cached == nil { try storage.saveTile(data, job: job.id, tile: Self.regionKey) }
        try await progress(1, 1, Int64(data.count))
        return bundle
    }
}
