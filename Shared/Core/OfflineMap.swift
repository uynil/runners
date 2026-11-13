import Foundation
import CryptoKit

struct MapBounds: Codable, Equatable {
    let south: Double
    let west: Double
    let north: Double
    let east: Double

    static func around(_ route: PlannedRoute, bufferMeters: Double = 500, maximumArea: Double = 100) throws -> MapBounds {
        try enclosing(route.segments.flatMap { $0 }, bufferMeters: bufferMeters, maximumArea: maximumArea)
    }

    private static func enclosing(_ points: [RoutePoint], bufferMeters: Double, maximumArea: Double) throws -> MapBounds {
        guard !points.isEmpty, points.allSatisfy({ $0.isValid }),
              let s = points.map(\.latitude).min(), let n = points.map(\.latitude).max(),
              let w = points.map(\.longitude).min(), let e = points.map(\.longitude).max(),
              abs(s) < 80, abs(n) < 80, e - w < 180 else {
            throw MapError.invalid("暂不支持空线路、极区或跨日期变更线的地图下载。")
        }
        guard (100...5_000).contains(bufferMeters) else { throw MapError.invalid("地图缓冲范围无效。") }
        let latBuffer = bufferMeters / 111_000
        let lonBuffer = latBuffer / max(0.17, cos(max(abs(s), abs(n)) * .pi / 180))
        let bounds = MapBounds(south: s - latBuffer, west: w - lonBuffer,
                               north: n + latBuffer, east: e + lonBuffer)
        guard bounds.isValid, bounds.areaSquareKilometers <= maximumArea else {
            throw MapError.invalid("地图范围超过 100 平方公里，请拆分线路后下载。")
        }
        return bounds
    }

    static func corridor(for route: PlannedRoute, bufferMeters: Double) throws -> [MapBounds] {
        var regions: [MapBounds] = []
        for segment in route.segments {
            var points = Array(segment.prefix(1))
            var length = 0.0
            for (start, end) in zip(segment, segment.dropFirst()) {
                let distance = start.distance(to: end)
                guard distance.isFinite, distance <= 160_000 else {
                    throw MapError.invalid("线路存在过长的连续路段，请检查原始线路。")
                }
                let count = max(1, Int(ceil(distance / 1_000)))
                for step in 1...count {
                    let fraction = Double(step) / Double(count)
                    let point = RoutePoint(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                                           longitude: start.longitude + (end.longitude - start.longitude) * fraction)
                    length += distance / Double(count)
                    points.append(point)
                    if length >= 3_000 {
                        try appendRegion(points, bufferMeters: bufferMeters, to: &regions)
                        points = [point]
                        length = 0
                    }
                }
            }
            if points.count > 1 { try appendRegion(points, bufferMeters: bufferMeters, to: &regions) }
        }
        return regions
    }

    private static func appendRegion(_ points: [RoutePoint], bufferMeters: Double, to regions: inout [MapBounds]) throws {
        let bounds = try enclosing(points, bufferMeters: bufferMeters, maximumArea: 100)
        if !regions.contains(bounds) { regions.append(bounds) }
        guard regions.count <= 64 else {
            throw MapError.invalid("线路覆盖超过 64 个区域，请拆分线路或缩小缓冲范围。")
        }
    }

    func contains(_ bounds: MapBounds) -> Bool {
        south <= bounds.south && west <= bounds.west && north >= bounds.north && east >= bounds.east
    }
    static func covers(_ segment: [RoutePoint], with regions: [MapBounds]) -> Bool {
        for (start, end) in zip(segment, segment.dropFirst()) {
            if regions.contains(where: { $0.contains(start) && $0.contains(end) }) { continue }
            let lat = end.latitude - start.latitude
            let lon = end.longitude - start.longitude
            let intervals = regions.compactMap { region -> ClosedRange<Double>? in
                var lower = 0.0, upper = 1.0
                for (origin, delta, minimum, maximum) in [
                    (start.latitude, lat, region.south, region.north),
                    (start.longitude, lon, region.west, region.east)
                ] {
                    if delta == 0 {
                        guard (minimum...maximum).contains(origin) else { return nil }
                    } else {
                        let a = (minimum - origin) / delta, b = (maximum - origin) / delta
                        lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
                    }
                }
                return lower <= upper ? lower...upper : nil
            }.sorted { $0.lowerBound < $1.lowerBound }
            var covered = 0.0
            for interval in intervals {
                guard interval.lowerBound <= covered else { break }
                covered = max(covered, interval.upperBound)
                if covered >= 1 { break }
            }
            guard covered >= 1 else { return false }
        }
        return true
    }
    func union(_ other: MapBounds) -> MapBounds {
        MapBounds(south: min(south, other.south), west: min(west, other.west),
                  north: max(north, other.north), east: max(east, other.east))
    }
    var areaSquareKilometers: Double {
        (north - south) * 111 * (east - west) * 111 * cos((north + south) / 2 * .pi / 180)
    }
    var isValid: Bool {
        [south, west, north, east].allSatisfy(\.isFinite) && south < north && west < east
            && south >= -90 && north <= 90 && west >= -180 && east <= 180
    }
    func contains(_ point: RoutePoint) -> Bool {
        (south...north).contains(point.latitude) && (west...east).contains(point.longitude)
    }
    var queryCoordinates: String {
        [south, west, north, east].map { String(format: "%.7f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
    }
}

extension RoutePoint {
    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

enum MapError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

struct MapFeature: Codable, Identifiable {
    let id: Int64
    let kind: String
    let name: String?
    let points: [RoutePoint]
    var holes: [[RoutePoint]]? = nil
    var nodeIDs: [Int64]? = nil
    var isWater: Bool { kind == "water" || kind == "waterway" }
}

struct OfflineMap: Codable {
    let bounds: MapBounds
    let features: [MapFeature]
    let sourceURL: String
    let downloadedAt: Date
    var provider: String? = nil
    var detailZoom: Int? = nil
    var coverageRegions: [MapBounds]? = nil
    var coverageDescription: String {
        if let coverageRegions { return "\(coverageRegions.count) 个沿线区域" }
        return String(format: "%.1f km²", bounds.areaSquareKilometers)
    }
    func covers(_ point: RoutePoint) -> Bool {
        coverageRegions?.contains { $0.contains(point) } ?? bounds.contains(point)
    }
    static let attribution = "© OpenStreetMap contributors · ODbL"

    static func parse(_ data: Data, bounds: MapBounds, sourceURL: String, allowsEmpty: Bool = false) throws -> OfflineMap {
        struct Response: Decodable {
            struct Element: Decodable {
                struct Coordinate: Decodable { let lat: Double; let lon: Double }
                let type: String
                let id: Int64
                let tags: [String: String]?
                let geometry: [Coordinate]?
                let nodes: [Int64]?
            }
            let elements: [Element]
            let remark: String?
        }
        guard data.count <= MapBundleStorage.maximumBytes else { throw MapError.invalid("地图数据超过大小限制。") }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.remark == nil else { throw MapError.invalid("地图服务未完整返回数据，请稍后重试。") }
        guard response.elements.count <= 20_000 else { throw MapError.invalid("地图要素过多，请缩小区域。") }
        var count = 0
        let features = try response.elements.compactMap { element -> MapFeature? in
            guard element.type == "way", let geometry = element.geometry, geometry.count >= 2 else { return nil }
            let tags = element.tags ?? [:]
            let kind: String
            if let highway = tags["highway"] { kind = highway }
            else if tags["waterway"] != nil { kind = "waterway" }
            else if tags["natural"] == "water" { kind = "water" }
            else if tags["natural"] == "wood" || tags["landuse"] == "forest" { kind = "landcover" }
            else if tags["building"] != nil { kind = "building" }
            else { return nil }
            count += geometry.count
            let points = geometry.map { RoutePoint(latitude: $0.lat, longitude: $0.lon) }
            guard count <= 200_000, points.allSatisfy(\.isValid) else { throw MapError.invalid("地图坐标无效或数据量过大。") }
            return MapFeature(id: element.id, kind: kind, name: tags["name"], points: points,
                              nodeIDs: element.nodes?.count == points.count ? element.nodes : nil)
        }
        guard allowsEmpty || !features.isEmpty else { throw MapError.invalid("该区域没有可用道路或水系数据，地图未保存。") }
        return OfflineMap(bounds: bounds, features: features, sourceURL: sourceURL, downloadedAt: Date())
    }
}

struct RouteMapBundle: Codable, Identifiable {
    var id: UUID { route.id }
    var schemaVersion = 1
    let route: PlannedRoute
    let map: OfflineMap
    init(route: PlannedRoute, map: OfflineMap) {
        self.route = route; self.map = map
        schemaVersion = map.coverageRegions != nil ? 3 : (map.provider == "thunderforest" ? 2 : 1)
    }
    var isValid: Bool {
        validCoverage
            && !route.segments.isEmpty && route.pointCount <= 100_000
            && route.segments.allSatisfy { segment in
                segment.count >= 2 && segment.allSatisfy { $0.isValid && map.bounds.contains($0) }
                    && (map.coverageRegions.map { MapBounds.covers(segment, with: $0) } ?? true)
            }
            && !map.features.isEmpty && map.features.count <= 20_000
            && map.features.reduce(0, { $0 + $1.points.count + ($1.holes ?? []).reduce(0, { $0 + $1.count }) }) <= 200_000
            && map.features.allSatisfy {
                $0.points.count >= 2 && $0.points.allSatisfy(\.isValid)
                    && ($0.nodeIDs == nil || $0.nodeIDs?.count == $0.points.count)
                    && ($0.holes ?? []).allSatisfy { $0.count >= 4 && $0.allSatisfy(\.isValid) }
            }
            && (route.cues ?? []).count <= 2_000
            && (route.cuesUpdatedAt == nil || route.cuesUpdatedAt!.timeIntervalSince1970.isFinite)
            && Set((route.cues ?? []).map(\.id)).count == (route.cues ?? []).count
            && (route.cues ?? []).allSatisfy {
                !$0.id.isEmpty && $0.id.count <= 200
                    && $0.progressMeters.isFinite && (0...route.distanceMeters).contains($0.progressMeters)
                    && $0.coordinate.isValid && map.covers($0.coordinate)
                    && ["left", "right", "straight"].contains($0.turn) && $0.name.count <= 100
            }
    }

    private var validCoverage: Bool {
        guard map.bounds.isValid else { return false }
        if let regions = map.coverageRegions {
            return schemaVersion == 3 && map.provider == "osm" && (1...64).contains(regions.count)
                && regions.allSatisfy { $0.isValid && $0.areaSquareKilometers <= 100 && map.bounds.contains($0) }
        }
        return map.bounds.areaSquareKilometers <= 101
            && ((schemaVersion == 1 && map.provider != "thunderforest") || (schemaVersion == 2 && map.provider == "thunderforest"))
    }
}

struct MapBundleStorage {
    static let maximumBytes = 24 * 1_024 * 1_024
    static let quotaBytes = 150 * 1_024 * 1_024
    let directory: URL

    struct Envelope: Codable { let sha256: String; let payload: Data }

    static func encode(_ bundle: RouteMapBundle) throws -> Data {
        guard bundle.isValid else { throw MapError.invalid("路线与地图覆盖或内容不匹配。") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(bundle)
        let envelope = Envelope(sha256: digest(payload), payload: payload)
        let data = try encoder.encode(envelope)
        guard data.count <= maximumBytes else { throw MapError.invalid("地图包超过 24 MB，请缩小区域。") }
        return data
    }
    static func decode(_ data: Data) throws -> RouteMapBundle {
        guard data.count <= maximumBytes else { throw MapError.invalid("地图包超过大小限制。") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard digest(envelope.payload) == envelope.sha256 else { throw MapError.invalid("地图包校验失败，原有地图已保留。") }
        let bundle = try JSONDecoder().decode(RouteMapBundle.self, from: envelope.payload)
        guard bundle.isValid else { throw MapError.invalid("地图包版本或覆盖无效。") }
        return bundle
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".runnersmap") }
    @discardableResult func save(_ bundle: RouteMapBundle) throws -> RouteMapBundle {
        try saveData(Self.encode(bundle))
    }
    @discardableResult func saveData(_ data: Data) throws -> RouteMapBundle {
        let bundle = try Self.decode(data)
        if let current = try? load(bundle.id),
           current.map.downloadedAt > bundle.map.downloadedAt
            || (current.route.cuesUpdatedAt ?? .distantPast) > (bundle.route.cuesUpdatedAt ?? .distantPast) {
            return current // Delayed transfers must not roll back maps or reviewed junctions.
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let destinationName = fileURL(bundle.id).lastPathComponent
        let used = try urls.filter { $0.lastPathComponent != destinationName }.reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        guard urls.filter({ $0.pathExtension == "runnersmap" && $0.lastPathComponent != destinationName }).count < 20 else {
            throw MapError.invalid("最多保存 20 个地图包，请先清理其他线路地图。")
        }
        guard used + data.count <= Self.quotaBytes else { throw MapError.invalid("离线地图已达到 150 MB 上限，请清理其他地图。") }
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
           let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < Int64(data.count) {
            throw MapError.invalid("设备可用空间不足，原有地图已保留。")
        }
        try data.write(to: fileURL(bundle.id), options: .atomic)
        return bundle
    }
    func load(_ id: UUID) throws -> RouteMapBundle {
        let url = fileURL(id)
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= Self.maximumBytes else {
            throw MapError.invalid("地图包超过大小限制。")
        }
        let bundle = try Self.decode(Data(contentsOf: url))
        guard bundle.id == id else { throw MapError.invalid("地图包线路 ID 不匹配。") }
        return bundle
    }
    func all() throws -> [RouteMapBundle] {
        try scan().bundles
    }
    func scan() throws -> (bundles: [RouteMapBundle], invalidCount: Int) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return ([], 0) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "runnersmap" }
        var bundles: [RouteMapBundle] = [], invalid = 0
        for url in files {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), let bundle = try? load(id) {
                bundles.append(bundle)
            } else { invalid += 1 }
        }
        return (bundles, invalid)
    }
    func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: fileURL(id)) }
}
