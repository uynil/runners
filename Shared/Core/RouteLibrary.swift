import Foundation

struct RoutePoint: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var elevationMeters: Double? = nil

    func isSamePosition(as other: RoutePoint) -> Bool {
        latitude == other.latitude && longitude == other.longitude
    }

    static func validElevation(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-12_000...12_000).contains(value) else { return nil }
        return value
    }

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
    var isReversed: Bool? = nil

    mutating func reverseDirection() {
        let length = distanceMeters
        segments = segments.reversed().map { Array($0.reversed()) }
        cues = cues?.reversed().map { cue in
            let turn: String
            switch cue.turn {
            case "left": turn = "right"
            case "right": turn = "left"
            default: turn = cue.turn
            }
            return RouteCue(id: cue.id, progressMeters: max(0, length - cue.progressMeters),
                            coordinate: cue.coordinate, turn: turn, name: cue.name, confirmed: cue.confirmed)
        }.sorted { $0.progressMeters < $1.progressMeters }
        isReversed = !(isReversed ?? false)
        cuesUpdatedAt = Date()
    }

    var distanceMeters: Double {
        segments.reduce(0) { total, segment in
            total + zip(segment, segment.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }
    }
    var pointCount: Int { segments.reduce(0) { $0 + $1.count } }

    /// Enrich an existing route without replacing its identity, cues or map association.
    mutating func addElevation(from candidates: [PlannedRoute]) -> Bool {
        for candidate in candidates {
            let source = isReversed == true ? candidate.segments.reversed().map { Array($0.reversed()) } : candidate.segments
            guard source.count == segments.count,
                  zip(segments, source).allSatisfy({ saved, incoming in
                      saved.count == incoming.count && zip(saved, incoming).allSatisfy { $0.isSamePosition(as: $1) }
                  }), source.contains(where: { $0.contains(where: { $0.elevationMeters != nil }) }) else { continue }
            for i in segments.indices {
                for j in segments[i].indices {
                    if let elevation = source[i][j].elevationMeters { segments[i][j].elevationMeters = elevation }
                }
            }
            cuesUpdatedAt = Date() // Also serves as the route revision for map packets.
            return true
        }
        return false
    }
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
