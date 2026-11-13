import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MapDownloader {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    static func request(route: PlannedRoute, endpoint: URL) throws -> (URLRequest, MapBounds) {
        try request(bounds: MapBounds.around(route), endpoint: endpoint)
    }

    static func request(bounds: MapBounds, endpoint: URL) throws -> (URLRequest, MapBounds) {
        guard bounds.isValid, bounds.areaSquareKilometers <= 100 else { throw MapError.invalid("地图范围无效或超过 100 平方公里。") }
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw MapError.invalid("地图服务地址必须是有效的 HTTPS 地址。")
        }
        let box = bounds.queryCoordinates
        let query = "[out:json][timeout:25][maxsize:33554432];(way[highway](\(box));way[waterway](\(box));way[natural=water](\(box));way[natural=wood](\(box));way[landuse=forest](\(box));way[building](\(box)););out geom;"
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Runners/0.1 (+https://github.com/uynil/runners)", forHTTPHeaderField: "User-Agent")
        request.httpBody = ("data=" + (query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).data(using: .utf8)
        return (request, bounds)
    }

    func download(route: PlannedRoute, endpoint: URL) async throws -> RouteMapBundle {
        let (request, bounds) = try Self.request(route: route, endpoint: endpoint)
        let (url, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: url) }
        try Task.checkCancellation()
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= MapBundleStorage.maximumBytes else {
            throw MapError.invalid("地图响应超过 24 MB，请缩小区域。")
        }
        return try Self.bundle(data: Data(contentsOf: url), response: response, route: route, bounds: bounds, endpoint: endpoint)
    }

    static func bundle(data: Data, response: URLResponse, route: PlannedRoute, bounds: MapBounds, endpoint: URL) throws -> RouteMapBundle {
        guard let http = response as? HTTPURLResponse else { throw MapError.invalid("地图服务响应无效。") }
        guard http.statusCode == 200 else {
            throw MapError.invalid(http.statusCode == 429 ? "地图服务繁忙，请稍后手动重试。" : "地图服务返回错误（\(http.statusCode)），请稍后重试。")
        }
        let map = try OfflineMap.parse(data, bounds: bounds, sourceURL: endpoint.absoluteString)
        let bundle = RouteMapBundle(route: route, map: map)
        guard bundle.isValid else { throw MapError.invalid("下载的地图包无效。") }
        return bundle
    }
}
