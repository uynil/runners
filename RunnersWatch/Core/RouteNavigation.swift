import Foundation

struct RouteCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    func distance(to other: RouteCoordinate) -> Double {
        GPSFix(timestamp: .distantPast, latitude: latitude, longitude: longitude, accuracy: 0)
            .distance(to: GPSFix(timestamp: .distantPast, latitude: other.latitude, longitude: other.longitude, accuracy: 0))
    }
}

/// Reads the same route JSON produced by the phone importer. File transfer is separate.
struct NavigationRoute {
    let id: UUID?
    let name: String
    let sourceName: String
    let segments: [[RouteCoordinate]]
    let distanceMeters: Double
    fileprivate let edges: [RouteEdge]
    let projection: RouteProjection
    let renderSegments: [[RouteXY]]
    let cues: [NavigationCue]
    fileprivate let grid: RouteGrid

    init(id: UUID? = nil, name: String, sourceName: String = "", segments: [[RouteCoordinate]], cues: [NavigationCue] = []) throws {
        guard !segments.isEmpty, segments.reduce(0, { $0 + $1.count }) <= 100_000,
              segments.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isValid) }) else {
            throw RouteError.invalid
        }
        self.id = id
        self.name = String(name.prefix(200))
        self.sourceName = sourceName
        self.segments = segments
        let projection = RouteProjection(origin: segments[0][0])
        self.projection = projection
        var edges: [RouteEdge] = []
        var offset = 0.0
        for segment in segments {
            for (a, b) in zip(segment, segment.dropFirst()) {
                let length = a.distance(to: b)
                guard length > 0.01 else { continue }
                edges.append(RouteEdge(start: a, end: b, a: projection.project(a), b: projection.project(b),
                                       offset: offset, length: length))
                offset += length
            }
        }
        guard offset > 0 else { throw RouteError.invalid }
        self.edges = edges
        grid = RouteGrid(edges: edges)
        distanceMeters = offset
        guard cues.count <= 2_000, Set(cues.map(\.id)).count == cues.count,
              cues.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 200
            && $0.progressMeters.isFinite && (0...offset).contains($0.progressMeters)
            && $0.coordinate.isValid && ["left", "right", "straight"].contains($0.turn) }) else { throw RouteError.invalid }
        self.cues = cues.filter(\.confirmed).sorted { $0.progressMeters < $1.progressMeters }
        renderSegments = segments.map { simplify($0.map(projection.project), tolerance: 3) }
    }

    static func decode(_ data: Data) throws -> NavigationRoute {
        guard data.count <= 10 * 1_024 * 1_024 else { throw RouteError.invalid }
        struct Payload: Decodable {
            let id: UUID?
            let name: String
            let sourceName: String?
            let segments: [[RouteCoordinate]]
            let cues: [NavigationCue]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return try NavigationRoute(id: payload.id, name: payload.name, sourceName: payload.sourceName ?? "", segments: payload.segments, cues: payload.cues ?? [])
    }

    enum RouteError: LocalizedError {
        case invalid
        var errorDescription: String? { "路线数据无效，无法开始导航。" }
    }
}

struct RouteXY: Equatable {
    let x: Double
    let y: Double

    func distance(to other: RouteXY) -> Double { hypot(x - other.x, y - other.y) }
}

struct RouteProjection {
    let origin: RouteCoordinate

    func project(_ point: RouteCoordinate) -> RouteXY {
        var longitude = point.longitude - origin.longitude
        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }
        return RouteXY(x: longitude * .pi / 180 * 6_371_000 * cos(origin.latitude * .pi / 180),
                       y: (point.latitude - origin.latitude) * .pi / 180 * 6_371_000)
    }
}

private struct RouteEdge {
    let start: RouteCoordinate
    let end: RouteCoordinate
    let a: RouteXY
    let b: RouteXY
    let offset: Double
    let length: Double

    func match(_ point: RouteXY, within range: ClosedRange<Double>? = nil) -> (distance: Double, progress: Double) {
        let dx = b.x - a.x, dy = b.y - a.y
        let low = range.map { max(0, min(1, ($0.lowerBound - offset) / length)) } ?? 0
        let high = range.map { max(low, min(1, ($0.upperBound - offset) / length)) } ?? 1
        let t = max(low, min(high, ((point.x - a.x) * dx + (point.y - a.y) * dy) / max(0.0001, dx * dx + dy * dy)))
        let projected = RouteXY(x: a.x + t * dx, y: a.y + t * dy)
        return (point.distance(to: projected), offset + t * length)
    }
}

enum NavigationStatus: String {
    case onRoute, checkingDeviation, offRoute, uncertain

    var title: String {
        switch self {
        case .onRoute: return "沿路线行进"
        case .checkingDeviation: return "正在确认偏离"
        case .offRoute: return "已偏离路线"
        case .uncertain: return "GPS 不可靠"
        }
    }
}

struct NavigationResult {
    let status: NavigationStatus
    let timestamp: Date
    let progressMeters: Double?
    let remainingMeters: Double?
    let distanceToRoute: Double?
    let shouldAlert: Bool
    var isReverse = false
    var bearingToRoute: Double? = nil
}

/// Navigation state is independent of rendering and never modifies recorded GPS.
struct RouteNavigator {
    let route: NavigationRoute
    private var progress: Double?
    private var lastTrustedDate: Date?
    private var lastTrustedCoordinate: RouteCoordinate?
    private var headingAnchor: RouteCoordinate?
    private var heading: RouteXY?
    private var headingDate: Date?
    private var reverseMeters = 0.0
    private var deviationSince: Date?
    private var isOffRoute = false
    private var lastAlert: Date?
    private var reacquiring = false
    private var recovery: (progress: Double, count: Int, since: Date)?

    mutating func breakObservation() { deviationSince = nil; heading = nil; headingAnchor = nil }

    mutating func consume(_ fix: GPSFix, receivedAt now: Date) -> NavigationResult {
        func uncertain() -> NavigationResult {
            NavigationResult(status: .uncertain, timestamp: fix.timestamp, progressMeters: nil,
                             remainingMeters: nil, distanceToRoute: nil, shouldAlert: false)
        }
        let coordinate = RouteCoordinate(latitude: fix.latitude, longitude: fix.longitude)
        guard coordinate.isValid, fix.accuracy.isFinite, (0...20).contains(fix.accuracy),
              (-1...10).contains(now.timeIntervalSince(fix.timestamp)),
              lastTrustedDate == nil || fix.timestamp > lastTrustedDate! else {
            deviationSince = nil; recovery = nil
            return uncertain()
        }
        let elapsed = lastTrustedDate.map { max(0, fix.timestamp.timeIntervalSince($0)) } ?? 0
        if let previous = lastTrustedCoordinate, previous.distance(to: coordinate) > max(30, elapsed * 12) {
            deviationSince = nil; recovery = nil
            return uncertain()
        }
        if elapsed > 10 { deviationSince = nil; heading = nil; headingAnchor = nil }
        let point = route.projection.project(coordinate)
        if let anchor = headingAnchor, anchor.distance(to: coordinate) >= max(5, fix.accuracy) {
            let a = route.projection.project(anchor), dx = point.x - a.x, dy = point.y - a.y
            let length = hypot(dx, dy)
            heading = RouteXY(x: dx / length, y: dy / length)
            headingDate = fix.timestamp; headingAnchor = coordinate
        } else if headingAnchor == nil { headingAnchor = coordinate }
        if let date = headingDate, fix.timestamp.timeIntervalSince(date) > 20 { heading = nil }
        lastTrustedDate = fix.timestamp; lastTrustedCoordinate = coordinate
        let window = min(500, max(150, elapsed * 12 + 30))
        let range = progress.map { max(0, $0 - window)...min(route.distanceMeters, $0 + window) }
        struct Candidate { let distance: Double; let progress: Double; let score: Double; let edge: RouteEdge }
        func candidates(_ indices: [Int], range: ClosedRange<Double>?) -> [Candidate] {
            indices.compactMap { index in
                let edge = route.edges[index]
                if let range, edge.offset + edge.length < range.lowerBound || edge.offset > range.upperBound { return nil }
                let match = edge.match(point, within: range)
                let dx = edge.b.x - edge.a.x, dy = edge.b.y - edge.a.y, length = hypot(dx, dy)
                let direction = reverseMeters > 12 ? -1.0 : 1.0
                let headingCost: Double
                if let heading {
                    let dot = heading.x * dx + heading.y * dy
                    headingCost = 8.0 * (1.0 - direction * dot / max(0.01, length))
                } else { headingCost = 0 }
                let continuity = progress.map { min(30, abs(match.progress - $0) * 0.08) } ?? 0
                return Candidate(distance: match.distance, progress: match.progress,
                                 score: match.distance + continuity + headingCost, edge: edge)
            }
        }
        var indices = route.grid.near(point)
        if let range {
            // Binary search offsets; do not scan the complete route every GPS update.
            var low = 0, high = route.edges.count
            while low < high {
                let mid = (low + high) / 2
                if route.edges[mid].offset + route.edges[mid].length < range.lowerBound { low = mid + 1 } else { high = mid }
            }
            indices = []
            while low < route.edges.count, route.edges[low].offset <= range.upperBound { indices.append(low); low += 1 }
        } else if indices.isEmpty { indices = Array(route.edges.indices) }
        var local = candidates(indices, range: range)
        if progress == nil, let start = route.segments.first?.first, start.distance(to: coordinate) <= max(15, fix.accuracy) {
            local = local.filter { $0.progress <= 50 }
        }
        guard var nearest = local.min(by: { $0.score < $1.score }) else { return uncertain() }
        if elapsed > 25, progress != nil, nearest.distance > max(40, fix.accuracy * 2) { reacquiring = true }
        if reacquiring {
            let global = candidates(route.grid.near(point), range: nil).sorted { $0.score < $1.score }
            if let first = global.first, first.distance <= max(15, fix.accuracy),
               !global.contains(where: { abs($0.progress - first.progress) > 80 && $0.score <= first.score + max(3, fix.accuracy / 2) }) {
                if let old = recovery, abs(old.progress - first.progress) <= max(30, elapsed * 12) {
                    recovery = (first.progress, old.count + 1, old.since)
                } else { recovery = (first.progress, 1, fix.timestamp) }
                guard let recovery, recovery.count >= 3, fix.timestamp.timeIntervalSince(recovery.since) >= 3 else { return uncertain() }
                nearest = first; reacquiring = false; self.recovery = nil
            } else if global.allSatisfy({ $0.distance > max(40, fix.accuracy * 2) }) {
                // Reliable fixes far from every route branch are off-route, not an endless GPS-wait state.
                reacquiring = false; recovery = nil
            } else { recovery = nil; return uncertain() }
        }
        if progress == nil, heading == nil,
           local.contains(where: { abs($0.progress - nearest.progress) > 80 && $0.distance <= nearest.distance + max(3, fix.accuracy / 2) }) {
            return uncertain() // A parallel/crossing branch cannot yet be distinguished.
        }
        let threshold = max(30, fix.accuracy * 2)
        if nearest.distance > threshold {
            if deviationSince == nil { deviationSince = fix.timestamp }
            if fix.timestamp.timeIntervalSince(deviationSince!) >= 5 { isOffRoute = true }
        } else if nearest.distance <= 20 {
            deviationSince = nil; isOffRoute = false
            if let old = progress {
                let change = nearest.progress - old
                if change < -1 { reverseMeters += -change } else if change > 1 { reverseMeters = max(0, reverseMeters - change) }
            }
            progress = nearest.progress
        } else { deviationSince = nil }
        let status: NavigationStatus = isOffRoute ? .offRoute : (deviationSince == nil ? .onRoute : .checkingDeviation)
        let shouldAlert = isOffRoute && (lastAlert == nil || fix.timestamp.timeIntervalSince(lastAlert!) >= 60)
        if shouldAlert { lastAlert = fix.timestamp }
        let matchT = max(0, min(1, (nearest.progress - nearest.edge.offset) / nearest.edge.length))
        let target = RouteXY(x: nearest.edge.a.x + (nearest.edge.b.x - nearest.edge.a.x) * matchT,
                             y: nearest.edge.a.y + (nearest.edge.b.y - nearest.edge.a.y) * matchT)
        var bearing = atan2(target.x - point.x, target.y - point.y) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return NavigationResult(status: status, timestamp: fix.timestamp, progressMeters: progress,
                                remainingMeters: progress.map { max(0, route.distanceMeters - $0) },
                                distanceToRoute: nearest.distance, shouldAlert: shouldAlert,
                                isReverse: reverseMeters > max(20, fix.accuracy * 3), bearingToRoute: nearest.distance > 20 ? bearing : nil)
    }
}

private struct RouteGrid {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var cells: [Cell: [Int]] = [:]
    private var longEdges: [Int] = []
    init(edges: [RouteEdge]) {
        for (i, edge) in edges.enumerated() {
            let x0 = Int(floor(min(edge.a.x, edge.b.x) / 100)), x1 = Int(floor(max(edge.a.x, edge.b.x) / 100))
            let y0 = Int(floor(min(edge.a.y, edge.b.y) / 100)), y1 = Int(floor(max(edge.a.y, edge.b.y) / 100))
            if (x1 - x0 + 1) * (y1 - y0 + 1) > 64 { longEdges.append(i); continue }
            for x in x0...x1 { for y in y0...y1 { cells[Cell(x: x, y: y), default: []].append(i) } }
        }
    }
    func near(_ point: RouteXY) -> [Int] {
        let x = Int(floor(point.x / 100)), y = Int(floor(point.y / 100))
        var result = Set(longEdges)
        for dx in -1...1 { for dy in -1...1 { result.formUnion(cells[Cell(x: x + dx, y: y + dy)] ?? []) } }
        return result.sorted()
    }
}

/// Iterative Douglas–Peucker keeps sharp turns while reducing rendering work.
private func simplify(_ points: [RouteXY], tolerance: Double) -> [RouteXY] {
    guard points.count > 2 else { return points }
    var keep = Set([0, points.count - 1])
    var pending = [(0, points.count - 1)]
    while let (first, last) = pending.popLast() {
        guard last > first + 1 else { continue }
        let a = points[first], b = points[last]
        let dx = b.x - a.x, dy = b.y - a.y
        var furthest = tolerance, index: Int?
        for i in (first + 1)..<last {
            let t = max(0, min(1, ((points[i].x - a.x) * dx + (points[i].y - a.y) * dy) / max(0.0001, dx * dx + dy * dy)))
            let distance = points[i].distance(to: RouteXY(x: a.x + t * dx, y: a.y + t * dy))
            if distance > furthest { furthest = distance; index = i }
        }
        if let index { keep.insert(index); pending.append((first, index)); pending.append((index, last)) }
    }
    return keep.sorted().map { points[$0] }
}
