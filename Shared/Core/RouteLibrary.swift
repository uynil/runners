import Foundation

struct RoutePoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double

    func distance(to other: RoutePoint) -> Double {
        let r = Double.pi / 180
        let a = pow(sin((other.latitude - latitude) * r / 2), 2)
            + cos(latitude * r) * cos(other.latitude * r)
            * pow(sin((other.longitude - longitude) * r / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
    }
}

struct PlannedRoute: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var sourceName: String
    var segments: [[RoutePoint]]
    var importedAt = Date()
    var isFavorite = false
    var cues: [RouteCue]? = nil
    var cuesUpdatedAt: Date? = nil

    var distanceMeters: Double {
        segments.reduce(0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }
    }
    var pointCount: Int { segments.reduce(0) { $0 + $1.count } }
}

/// Saves a complete snapshot atomically. Callers publish changes only after a successful write.
struct RouteLibrary {
    struct Snapshot: Codable {
        var schemaVersion = 1
        var routes: [PlannedRoute]
    }
    let url: URL

    func load() throws -> [PlannedRoute] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        guard snapshot.schemaVersion == 1 else { throw LibraryError.unsupportedVersion }
        return snapshot.routes
    }

    func save(_ routes: [PlannedRoute]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Snapshot(routes: routes)).write(to: url, options: .atomic)
    }

    enum LibraryError: LocalizedError {
        case unsupportedVersion
        var errorDescription: String? { "线路库版本不受支持，原文件已保留。" }
    }
}
