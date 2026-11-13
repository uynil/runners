import Foundation

struct RouteCue: Codable, Equatable, Identifiable {
    var id: String
    let progressMeters: Double
    let coordinate: RoutePoint
    var turn: String
    var name: String
    var confirmed = false
    var title: String {
        let action = turn == "left" ? "左转" : (turn == "right" ? "右转" : "沿轨迹直行")
        return name.isEmpty ? action : "\(action) · \(name)"
    }
    static func manual(route: PlannedRoute, progress: Double, turn: String) throws -> RouteCue {
        guard progress.isFinite, progress >= 0, ["left", "right", "straight"].contains(turn) else {
            throw MapError.invalid("路口距离或方向无效。")
        }
        var offset = 0.0
        for segment in route.segments {
            for (a, b) in zip(segment, segment.dropFirst()) {
                let length = a.distance(to: b)
                if length > 0, progress <= offset + length {
                    let t = max(0, (progress - offset) / length)
                    return RouteCue(id: "manual-\(UUID().uuidString)", progressMeters: progress,
                        coordinate: RoutePoint(latitude: a.latitude + (b.latitude-a.latitude)*t,
                                               longitude: a.longitude + (b.longitude-a.longitude)*t),
                        turn: turn, name: "手工路口")
                }
                offset += length
            }
        }
        throw MapError.invalid("路口距离超过线路全长。")
    }
}

/// Reports OSM road proximity, not survey accuracy or proof of trail completeness.
struct RoutePreparation {
    let roadCoverage: Double
    let sampledPoints: Int
    let candidates: [RouteCue]
    var warning: String? {
        roadCoverage < 0.8 ? "部分轨迹附近缺少 OSM 路网；仍可看原轨迹，请核对当地步道。" : nil
    }

    static func analyze(route: PlannedRoute, map: OfflineMap) -> RoutePreparation {
        guard let origin = route.segments.first?.first else { return RoutePreparation(roadCoverage: 0, sampledPoints: 0, candidates: []) }
        let projection = LocalProjection(origin: origin)
        var edges: [PreparationEdge] = [], offset = 0.0
        for (segment, points) in route.segments.enumerated() {
            for (a, b) in zip(points, points.dropFirst()) {
                let length = a.distance(to: b)
                guard length > 0.01 else { continue }
                edges.append(PreparationEdge(a: projection.xy(a), b: projection.xy(b), offset: offset, length: length, segment: segment))
                offset += length
            }
        }
        let routeGrid = PreparationGrid(edges: edges)
        let roads = map.features.filter { !["water", "waterway", "landcover", "building", "contour"].contains($0.kind) }
        let roadEdges = roads.flatMap { feature in
            zip(feature.points, feature.points.dropFirst()).map {
                PreparationEdge(a: projection.xy($0), b: projection.xy($1), offset: 0, length: $0.distance(to: $1), segment: 0)
            }
        }
        let roadGrid = PreparationGrid(edges: roadEdges)
        var covered = 0, sampled = 0
        let spacing = max(50, offset / 4_000)
        var nextSample = 0.0
        for edge in edges {
            while nextSample <= edge.offset + edge.length {
                let point = edge.at(max(0, (nextSample - edge.offset) / edge.length))
                if roadGrid.near(point).contains(where: { roadEdges[$0].match(point).distance <= 40 }) { covered += 1 }
                sampled += 1; nextSample += spacing
            }
        }
        struct Junction { var point: RoutePoint; var neighbors: Set<Int64>; var name: String }
        var nodes: [Int64: Junction] = [:]
        for road in roads {
            guard let ids = road.nodeIDs, ids.count == road.points.count else { continue }
            for i in ids.indices {
                var node = nodes[ids[i]] ?? Junction(point: road.points[i], neighbors: [], name: road.name ?? "")
                if i > 0 { node.neighbors.insert(ids[i - 1]) }
                if i + 1 < ids.count { node.neighbors.insert(ids[i + 1]) }
                nodes[ids[i]] = node
            }
        }
        var cues: [RouteCue] = []
        for (id, node) in nodes where node.neighbors.count >= 3 {
            let point = projection.xy(node.point)
            let matches = routeGrid.near(point).compactMap { index -> (PreparationEdge, Double)? in
                let edge = edges[index], match = edge.match(point)
                return match.distance <= 20 ? (edge, match.progress) : nil
            }.sorted { $0.1 < $1.1 }
            var lastProgress = -Double.infinity
            for (edge, progress) in matches where progress - lastProgress > 40 {
                lastProgress = progress
                guard progress >= 25, offset - progress >= 25 else { continue }
                // Locate tangents on this segment only; never invent a turn across a GPX gap.
                let before = edges.last { $0.segment == edge.segment && $0.offset <= progress - 20 }
                let after = edges.first { $0.segment == edge.segment && $0.offset + $0.length >= progress + 20 }
                guard let before, let after,
                      before.offset + before.length >= progress - 20, after.offset <= progress + 20 else { continue }
                let a = before.at((progress - 20 - before.offset) / before.length)
                let b = edge.at((progress - edge.offset) / edge.length)
                let c = after.at((progress + 20 - after.offset) / after.length)
                let angle = atan2((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x), (b.x-a.x)*(c.x-b.x)+(b.y-a.y)*(c.y-b.y)) * 180 / .pi
                cues.append(RouteCue(id: "osm-\(id)-\(Int(progress / 40))", progressMeters: progress,
                                     coordinate: node.point, turn: angle > 30 ? "left" : (angle < -30 ? "right" : "straight"),
                                     name: String(node.name.prefix(60))))
            }
        }
        let sorted = cues.sorted { $0.progressMeters < $1.progressMeters }
        var filtered: [RouteCue] = []
        for cue in sorted where filtered.last.map({ cue.progressMeters - $0.progressMeters > 30 }) ?? true { filtered.append(cue) }
        return RoutePreparation(roadCoverage: sampled == 0 ? 0 : Double(covered) / Double(sampled), sampledPoints: sampled,
                                candidates: Array(filtered.prefix(2_000)))
    }
}

private struct XY { let x: Double; let y: Double }
private struct LocalProjection {
    let origin: RoutePoint
    func xy(_ point: RoutePoint) -> XY {
        XY(x: (point.longitude - origin.longitude) * 111_195 * cos(origin.latitude * .pi / 180),
           y: (point.latitude - origin.latitude) * 111_195)
    }
}
private struct PreparationEdge {
    let a: XY; let b: XY; let offset: Double; let length: Double; let segment: Int
    func at(_ t: Double) -> XY { XY(x: a.x + (b.x-a.x)*max(0,min(1,t)), y: a.y + (b.y-a.y)*max(0,min(1,t))) }
    func match(_ p: XY) -> (distance: Double, progress: Double) {
        let dx = b.x-a.x, dy = b.y-a.y
        let t = max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/max(0.0001,dx*dx+dy*dy)))
        let q = at(t)
        return (hypot(p.x-q.x,p.y-q.y),offset+t*length)
    }
}
private struct PreparationGrid {
    private struct Cell: Hashable { let x: Int; let y: Int }
    private var cells: [Cell:[Int]] = [:]
    private var long: [Int] = []
    init(edges: [PreparationEdge]) {
        for (i,e) in edges.enumerated() {
            let x0=Int(floor(min(e.a.x,e.b.x)/100)), x1=Int(floor(max(e.a.x,e.b.x)/100))
            let y0=Int(floor(min(e.a.y,e.b.y)/100)), y1=Int(floor(max(e.a.y,e.b.y)/100))
            if (x1-x0+1)*(y1-y0+1)>64 { long.append(i); continue }
            for x in x0...x1 { for y in y0...y1 { cells[Cell(x:x,y:y),default:[]].append(i) } }
        }
    }
    func near(_ p: XY) -> [Int] {
        let x=Int(floor(p.x/100)), y=Int(floor(p.y/100)); var result=Set(long)
        for dx in -1...1 { for dy in -1...1 { result.formUnion(cells[Cell(x:x+dx,y:y+dy)] ?? []) } }
        return result.sorted()
    }
}
