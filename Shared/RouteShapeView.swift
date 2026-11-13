import SwiftUI

struct RouteShapeView: View {
    let route: PlannedRoute
    var map: OfflineMap? = nil
    var currentPosition: RoutePoint? = nil
    var viewportBounds: MapBounds? = nil
    var selectionBounds: MapBounds? = nil
    var body: some View {
        Canvas { context, size in
            let points = route.segments.flatMap { $0 }
            guard let first = points.first else { return }
            let cosLatitude = max(0.01, cos(first.latitude * .pi / 180))
            func project(_ point: RoutePoint) -> CGPoint {
                var delta = point.longitude - first.longitude
                if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
                return CGPoint(x: delta * cosLatitude, y: -point.latitude)
            }
            let projected = route.segments.map { segment in
                segment.map { point -> CGPoint in
                    // Wrap relative longitude to keep antimeridian crossings local.
                    var delta = point.longitude - first.longitude
                    if delta > 180 { delta -= 360 }; if delta < -180 { delta += 360 }
                    return CGPoint(x: delta * cosLatitude, y: -point.latitude)
                }
            }
            let all: [CGPoint]
            if let bounds = viewportBounds ?? map?.bounds {
                all = [project(RoutePoint(latitude: bounds.south, longitude: bounds.west)),
                       project(RoutePoint(latitude: bounds.north, longitude: bounds.east))]
            } else { all = projected.flatMap { $0 } }
            let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 0
            let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 0
            let scale = min((size.width - 32) / max(maxX - minX, 0.00001), (size.height - 32) / max(maxY - minY, 0.00001))
            func screen(_ point: CGPoint) -> CGPoint {
                CGPoint(x: (point.x - (minX + maxX) / 2) * scale + size.width / 2,
                        y: (point.y - (minY + maxY) / 2) * scale + size.height / 2)
            }
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            if let map {
                let ordered = map.features.sorted { featureRank($0.kind) < featureRank($1.kind) }
                for feature in ordered {
                    var path = Path()
                    for (index, point) in feature.points.enumerated() {
                        if index == 0 { path.move(to: screen(project(point))) }
                        else { path.addLine(to: screen(project(point))) }
                    }
                    if feature.points.first == feature.points.last {
                        path.closeSubpath()
                        for hole in feature.holes ?? [] {
                            for (index, point) in hole.enumerated() {
                                if index == 0 { path.move(to: screen(project(point))) }
                                else { path.addLine(to: screen(project(point))) }
                            }
                            path.closeSubpath()
                        }
                        let fill: Color?
                        switch feature.kind {
                        case "water": fill = .blue.opacity(0.18)
                        case "landcover": fill = .green.opacity(0.1)
                        case "building": fill = .secondary.opacity(0.15)
                        default: fill = nil
                        }
                        if let fill { context.fill(path, with: .color(fill), style: FillStyle(eoFill: true)) }
                    }
                    let major = ["motorway", "trunk", "primary", "secondary", "tertiary"].contains(feature.kind)
                    let trail = ["path", "footway", "track", "steps", "bridleway"].contains(feature.kind)
                    let color: Color = feature.kind == "contour" ? .brown.opacity(0.3) : (feature.isWater ? .blue.opacity(0.6) : (major ? .orange.opacity(0.6) : .secondary.opacity(0.5)))
                    context.stroke(path, with: .color(color),
                        style: StrokeStyle(lineWidth: feature.kind == "contour" ? 0.5 : (major ? 2 : 1), dash: trail ? [3, 2] : []))
                }
                var names = Set<String>()
                var labelPositions: [CGPoint] = []
                for feature in map.features {
                    guard names.count < 16, let name = feature.name, !name.isEmpty, !names.contains(name),
                          let point = feature.points.dropFirst(feature.points.count / 2).first,
                          map.bounds.contains(point) else { continue }
                    let location = screen(project(point))
                    guard labelPositions.allSatisfy({ abs($0.x - location.x) > 70 || abs($0.y - location.y) > 20 }) else { continue }
                    context.draw(Text(String(name.prefix(16))).font(.system(size: 9)).foregroundColor(.secondary),
                                 at: CGPoint(x: location.x, y: location.y - 7))
                    names.insert(name)
                    labelPositions.append(location)
                }
            }
            for segment in projected {
                var path = Path()
                for (index, point) in segment.enumerated() {
                    if index == 0 { path.move(to: screen(point)) } else { path.addLine(to: screen(point)) }
                }
                context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let start = projected.first?.first {
                let p = screen(start)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.blue))
            }
            if let currentPosition, map?.bounds.contains(currentPosition) ?? true {
                let p = screen(project(currentPosition))
                context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.red))
            }
            if let selectionBounds {
                let a = screen(project(RoutePoint(latitude: selectionBounds.north, longitude: selectionBounds.west)))
                let b = screen(project(RoutePoint(latitude: selectionBounds.south, longitude: selectionBounds.east)))
                let rect = Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
                context.fill(rect, with: .color(.blue.opacity(0.06)))
                context.stroke(rect, with: .color(.blue), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel(map == nil ? "线路形状预览，蓝点为起点，分段间不连线，无地图底图" : "离线地图，绿色为线路，蓝点为起点，红点为有效当前位置")
    }

    private func featureRank(_ kind: String) -> Int {
        switch kind { case "landcover": return 0; case "water": return 1; case "building": return 2; case "contour": return 3; default: return 4 }
    }
}
