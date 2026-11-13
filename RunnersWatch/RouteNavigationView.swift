import SwiftUI

struct RouteNavigationView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var maps: WatchMapReceiver
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.scenePhase) private var scenePhase
    var isPage = false
    var isVisible = true
    @State private var overview = true
    @State private var zoom = 2.0
    @State private var pan = CGSize.zero
    @State private var cameraAnchor: RouteXY?
    @GestureState private var drag = CGSize.zero
    @State private var geometry: NavigationMapGeometry?
    @FocusState private var crownFocused: Bool

    private var bundle: RouteMapBundle? {
        guard let id = recorder.navigationRoute?.id else { return nil }
        return maps.bundles.first { $0.id == id }
    }
    private var mapKey: String {
        [recorder.navigationRoute?.id?.uuidString ?? recorder.navigationRoute?.name ?? "",
         String(recorder.navigationRoute?.distanceMeters ?? 0),
         String(bundle?.map.downloadedAt.timeIntervalSince1970 ?? 0)].joined(separator: ":")
    }
    private var awake: Bool { isVisible && scenePhase == .active && !dimmed }

    var body: some View {
        Group {
            if !awake {
                VStack(spacing: 6) {
                    Image(systemName: "map").font(.title2)
                    Text("抬腕查看地图").font(.caption)
                    Text(recorder.phase == .running ? "运动记录继续运行" : "地图已降低刷新").font(.system(size: 10))
                }.foregroundStyle(.gray)
            } else if let route = recorder.navigationRoute, let geometry {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    mapPage(route: route, geometry: geometry, at: timeline.date)
                }
            } else if recorder.navigationRoute != nil {
                ProgressView("正在准备地图")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "map").font(.system(size: 30)).foregroundStyle(RunStyle.lime)
                    Text("选择一条跑步线路").font(.system(size: 15, weight: .bold))
                    Text(recorder.navigationError ?? "在 iPhone 导入 GPX / KML，\n下载离线地图后发送到手表。")
                        .font(.system(size: 11)).foregroundStyle(.gray).multilineTextAlignment(.center)
                    NavigationLink { WatchMapsView().toolbar(.visible, for: .navigationBar) } label: {
                        Text("线路与地图").font(.system(size: 12, weight: .semibold))
                    }.tint(RunStyle.lime)
                    Button("刷新路线") { recorder.reloadNavigationRoute() }.font(.system(size: 10))
                }.padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .focusable(awake && recorder.navigationRoute != nil)
        .focused($crownFocused)
        .digitalCrownRotation($zoom, from: 0, through: 8, by: 0.1, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { _, _ in overview = false; pan = .zero; cameraAnchor = nil }
        .onChange(of: awake, initial: true) { _, awake in crownFocused = awake }
        .task(id: mapKey) {
            if let route = recorder.navigationRoute {
                geometry = NavigationMapGeometry(route: route, map: bundle?.map)
                overview = recorder.phase != .running; pan = .zero; cameraAnchor = nil
            }
        }
        .onChange(of: recorder.phase) { old, phase in
            if phase == .running && old != .paused {
                overview = false; pan = .zero; cameraAnchor = nil
            }
        }
        .navigationTitle(isPage ? "" : "跑步导航")
        .toolbar(isPage ? .hidden : .visible, for: .navigationBar)
    }

    private func mapPage(route: NavigationRoute, geometry: NavigationMapGeometry, at now: Date) -> some View {
        let mapFix = recorder.trail.vertices.last?.fix
        return ZStack {
            NavigationMapCanvas(geometry: geometry, trail: recorder.trail.vertices, fix: mapFix,
                                fresh: recorder.phase == .running && mapFix.map { (-1...10).contains(now.timeIntervalSince($0.timestamp)) } == true, overview: overview,
                                metersAcross: 3_200 / pow(2, zoom), cameraAnchor: cameraAnchor,
                                pan: CGSize(width: pan.width + drag.width, height: pan.height + drag.height))
                .contentShape(Rectangle())
                .onTapGesture { crownFocused = true }
                .gesture(DragGesture(minimumDistance: 6)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onChanged { _ in
                        guard cameraAnchor == nil else { return }
                        if overview {
                            cameraAnchor = RouteXY(x: (geometry.minimum.x + geometry.maximum.x) / 2,
                                                   y: (geometry.minimum.y + geometry.maximum.y) / 2)
                        } else if let fix = mapFix {
                            cameraAnchor = geometry.projection.project(RouteCoordinate(latitude: fix.latitude, longitude: fix.longitude))
                        } else { cameraAnchor = geometry.route.first?.first }
                    }
                    .onEnded { value in
                        pan.width += value.translation.width; pan.height += value.translation.height
                    })
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        Text(route.name).lineLimit(1)
                        #if targetEnvironment(simulator)
                        Text("模拟").font(.system(size: 7)).foregroundStyle(.yellow)
                        #endif
                    }.font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 12).foregroundStyle(.white.opacity(0.85))
                    HStack(spacing: 4) {
                        Image(systemName: statusIcon(at: now))
                        Text(status(at: now))
                    }.font(.system(size: 11, weight: .bold)).foregroundStyle(statusColor(at: now))
                }
                .frame(maxWidth: .infinity).padding(.top, isPage ? 30 : 3).padding(.bottom, 6)
                .background(LinearGradient(colors: [.black.opacity(0.95), .black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
                Spacer(minLength: 0)
                HStack {
                    mapButton("arrow.up.left.and.arrow.down.right", label: "查看全程", selected: overview) {
                        overview = true; pan = .zero; cameraAnchor = nil
                    }
                    Spacer()
                    mapButton("location.fill", label: "跟随当前位置", selected: !overview && pan == .zero && cameraAnchor == nil) {
                        overview = false; pan = .zero; cameraAnchor = nil
                    }
                }.padding(.horizontal, 6)
                HStack {
                    Text("计划").foregroundStyle(RunStyle.lime)
                    if !recorder.trail.vertices.isEmpty { Text("已跑").foregroundStyle(.cyan) }
                    Text(geometry.hasMap ? "离线" : "轨迹")
                    Spacer()
                    Text(pan != .zero || cameraAnchor != nil ? "浏览中" : (overview ? "全程" : "跟随"))
                    Text("N ↑").foregroundStyle(.white)
                }.font(.system(size: 8, weight: .medium)).foregroundStyle(.gray).padding(.horizontal, 10).padding(.top, 2)
                    .background(.black.opacity(0.8))
                if let map = bundle?.map {
                    HStack(spacing: 4) {
                        if map.provider == "thunderforest" { Link("© Thunderforest", destination: URL(string: "https://www.thunderforest.com/")!) }
                        Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    }.buttonStyle(.plain).font(.system(size: 7)).foregroundStyle(.gray)
                        .frame(maxWidth: .infinity).frame(height: 9).background(.black.opacity(0.8))
                }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(remainingTitle(at: now)).font(.system(size: 8)).foregroundStyle(.gray)
                        Text(remainingValue(route: route, at: now)).font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusColor(at: now)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("心率 bpm").font(.system(size: 8)).foregroundStyle(.gray)
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill").font(.system(size: 9))
                            Text(RunReadout.heart(recorder, at: now)).font(.system(size: 21, weight: .medium, design: .rounded))
                        }.foregroundStyle(RunStyle.coral)
                    }
                }.monospacedDigit().padding(.horizontal, 12).padding(.vertical, 4).background(.black.opacity(0.95))
            }
            if let fix = recorder.lastFix, let map = bundle?.map,
               RunReadout.gpsFresh(recorder, at: now), !map.covers(RoutePoint(latitude: fix.latitude, longitude: fix.longitude)) {
                Text("已超出离线地图范围").font(.system(size: 10, weight: .bold)).padding(5)
                    .foregroundStyle(.yellow).background(.black.opacity(0.85), in: Capsule())
            }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("跑步地图，黄绿色为规划线路，青色为已跑轨迹，蓝点为当前位置，始终北向上。旋转表冠缩放，拖动浏览。")
    }

    private func mapButton(_ icon: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? RunStyle.lime : .white).frame(width: 32, height: 32)
                .background(.black.opacity(0.85), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
    private func freshResult(at now: Date) -> NavigationResult? {
        guard recorder.phase == .running, let result = recorder.navigationResult,
              (-1...10).contains(now.timeIntervalSince(result.timestamp)) else { return nil }
        return result
    }
    private func status(at now: Date) -> String {
        if recorder.phase == .paused { return "运动已暂停" }
        if recorder.phase != .running { return "路线预览" }
        if let result = freshResult(at: now), result.status == .onRoute {
            if result.isReverse { return "正在逆向沿线" }
            if let cue = recorder.navigationCue, cue.meters <= 100 {
                return "\(Int(cue.meters))m · \(cue.cue.title)"
            }
        }
        if let result = freshResult(at: now), result.status == .offRoute, let bearing = result.bearingToRoute {
            return String(format: "偏航 · 回线直线方位 %.0f°", bearing)
        }
        return freshResult(at: now)?.status.title ?? "等待可靠 GPS"
    }
    private func statusColor(at now: Date) -> Color {
        guard recorder.phase != .paused else { return .yellow }
        guard recorder.phase == .running else { return RunStyle.lime }
        switch freshResult(at: now)?.status {
        case .onRoute: return freshResult(at: now)?.isReverse == true ? .yellow : RunStyle.lime
        case .offRoute: return RunStyle.coral
        default: return .yellow
        }
    }
    private func statusIcon(at now: Date) -> String {
        if freshResult(at: now)?.isReverse == true { return "arrow.uturn.down" }
        if freshResult(at: now)?.status == .onRoute, let cue = recorder.navigationCue, cue.meters <= 100 {
            return cue.cue.turn == "left" ? "arrow.turn.up.left" : (cue.cue.turn == "right" ? "arrow.turn.up.right" : "arrow.up")
        }
        switch freshResult(at: now)?.status {
        case .onRoute: return "location.north.line.fill"
        case .offRoute, .checkingDeviation: return "exclamationmark.triangle.fill"
        default: return "location.circle"
        }
    }
    private func remainingTitle(at now: Date) -> String {
        if freshResult(at: now)?.status == .offRoute { return "偏离匹配路段" }
        return recorder.phase == .running || recorder.phase == .paused ? "路线剩余" : "路线全长"
    }
    private func remainingValue(route: NavigationRoute, at now: Date) -> String {
        if recorder.canStart { return String(format: "%.2f km", route.distanceMeters / 1000) }
        guard let result = freshResult(at: now) else { return "-- km" }
        if result.status == .offRoute, let distance = result.distanceToRoute { return String(format: "%.0f m", distance) }
        guard result.status == .onRoute, let remaining = result.remainingMeters else { return "-- km" }
        return String(format: "%.2f km", remaining / 1000)
    }
}

private struct NavigationMapGeometry {
    struct Feature {
        let kind: String
        let name: String?
        let points: [RouteXY]
        let holes: [[RouteXY]]
        let minimum: RouteXY
        let maximum: RouteXY
    }
    let route: [[RouteXY]]
    let projection: RouteProjection
    let minimum: RouteXY
    let maximum: RouteXY
    let features: [Feature]
    var hasMap: Bool { !features.isEmpty }

    init(route: NavigationRoute, map: OfflineMap?) {
        self.route = route.renderSegments
        projection = route.projection
        let all = route.renderSegments.flatMap { $0 }
        minimum = RouteXY(x: all.map(\.x).min() ?? 0, y: all.map(\.y).min() ?? 0)
        maximum = RouteXY(x: all.map(\.x).max() ?? 100, y: all.map(\.y).max() ?? 100)
        features = (map?.features ?? []).sorted { Self.rank($0.kind) < Self.rank($1.kind) }.map { feature in
            func project(_ point: RoutePoint) -> RouteXY {
                route.projection.project(RouteCoordinate(latitude: point.latitude, longitude: point.longitude))
            }
            let points = feature.points.map(project)
            return Feature(kind: feature.kind, name: feature.name, points: points, holes: (feature.holes ?? []).map { $0.map(project) },
                           minimum: RouteXY(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0),
                           maximum: RouteXY(x: points.map(\.x).max() ?? 0, y: points.map(\.y).max() ?? 0))
        }
    }
    static func rank(_ kind: String) -> Int {
        switch kind { case "landcover": 0; case "water": 1; case "building": 2; case "contour": 3; default: 4 }
    }
}

private struct NavigationMapCanvas: View {
    let geometry: NavigationMapGeometry
    let trail: [TrailVertex]
    let fix: GPSFix?
    let fresh: Bool
    let overview: Bool
    let metersAcross: Double
    let cameraAnchor: RouteXY?
    let pan: CGSize

    var body: some View {
        Canvas { context, size in
            context.clip(to: Path(CGRect(origin: .zero, size: size)))
            let position = fix.flatMap { fix -> RouteXY? in
                let point = RouteCoordinate(latitude: fix.latitude, longitude: fix.longitude)
                return point.isValid ? geometry.projection.project(point) : nil
            }
            let routeCenter = RouteXY(x: (geometry.minimum.x + geometry.maximum.x) / 2,
                                      y: (geometry.minimum.y + geometry.maximum.y) / 2)
            let center = cameraAnchor ?? (overview ? routeCenter : (position ?? geometry.route.first?.first ?? routeCenter))
            let factor = overview ? min((size.width - 40) / max(100, geometry.maximum.x - geometry.minimum.x),
                                        max(30, size.height - 80) / max(100, geometry.maximum.y - geometry.minimum.y)) : size.width / metersAcross
            let viewport = NavigationViewport(center: center, scale: factor, width: size.width, height: size.height,
                                              panX: pan.width, panY: pan.height)
            func screen(_ point: RouteXY) -> CGPoint {
                let p = viewport.screen(point)
                return CGPoint(x: p.x, y: p.y)
            }
            func path(_ points: [RouteXY]) -> Path {
                var path = Path()
                for (index, point) in points.enumerated() {
                    if index == 0 { path.move(to: screen(point)) } else { path.addLine(to: screen(point)) }
                }
                return path
            }
            var labels: [CGPoint] = []
            var names = Set<String>()
            for feature in geometry.features {
                let a = screen(feature.minimum), b = screen(feature.maximum)
                guard max(a.x, b.x) >= 0, min(a.x, b.x) <= size.width,
                      max(a.y, b.y) >= 0, min(a.y, b.y) <= size.height else { continue }
                var line = path(feature.points)
                let closed = feature.points.first == feature.points.last
                if closed {
                    line.closeSubpath()
                    for hole in feature.holes { var holePath = path(hole); holePath.closeSubpath(); line.addPath(holePath) }
                    let fill: Color? = switch feature.kind {
                    case "landcover": Color(red: 0.14, green: 0.22, blue: 0.15)
                    case "water": Color(red: 0.12, green: 0.29, blue: 0.40)
                    case "building": Color.white.opacity(0.13)
                    default: nil
                    }
                    if let fill { context.fill(line, with: .color(fill), style: FillStyle(eoFill: true)) }
                }
                let trail = ["path", "footway", "track", "steps", "bridleway"].contains(feature.kind)
                let major = ["motorway", "trunk", "primary", "secondary", "tertiary"].contains(feature.kind)
                let color: Color = switch feature.kind {
                case "water", "waterway": .cyan.opacity(0.5)
                case "landcover": .green.opacity(0.1)
                case "contour": Color(red: 0.56, green: 0.45, blue: 0.28).opacity(0.45)
                default: major ? Color(red: 0.78, green: 0.66, blue: 0.45) : .white.opacity(0.35)
                }
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: major ? 2 : 0.7, dash: trail ? [3, 2] : []))
                if labels.count < 10, !overview, let name = feature.name, !name.isEmpty, !names.contains(name),
                   let middle = feature.points.dropFirst(feature.points.count / 2).first {
                    let p = screen(middle)
                    if p.x > 25 && p.x < size.width - 25 && p.y > 50 && p.y < size.height - 70,
                       labels.allSatisfy({ abs($0.x - p.x) > 65 || abs($0.y - p.y) > 18 }) {
                        context.draw(Text(String(name.prefix(12))).font(.system(size: 9)).foregroundColor(.white.opacity(0.7)), at: p)
                        labels.append(p); names.insert(name)
                    }
                }
            }
            for segment in geometry.route {
                let line = path(segment)
                context.stroke(line, with: .color(.black.opacity(0.85)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                context.stroke(line, with: .color(RunStyle.lime), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            var travelled = Path()
            for (index, vertex) in trail.enumerated() {
                let point = screen(geometry.projection.project(RouteCoordinate(latitude: vertex.fix.latitude,
                                                                               longitude: vertex.fix.longitude)))
                if index == 0 || vertex.startsSegment { travelled.move(to: point) }
                else { travelled.addLine(to: point) }
            }
            context.stroke(travelled, with: .color(.black.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            context.stroke(travelled, with: .color(.cyan),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            func dot(_ point: RouteXY, color: Color, radius: Double) {
                let p = screen(point)
                let rect = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(.black))
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
            if let start = geometry.route.first?.first { dot(start, color: .white, radius: 3) }
            if let end = geometry.route.last?.last { dot(end, color: RunStyle.coral, radius: 3) }
            if let position {
                let p = screen(position)
                if fresh { context.fill(Path(ellipseIn: CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)), with: .color(.cyan.opacity(0.18))) }
                dot(position, color: .white, radius: 7)
                dot(position, color: fresh ? .cyan : .gray, radius: 4)
            }
            let scaleMeters = [5.0, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000].last { $0 * factor <= 40 } ?? 5
            let length = scaleMeters * factor
            var scale = Path()
            scale.move(to: CGPoint(x: 12, y: 58)); scale.addLine(to: CGPoint(x: 12 + length, y: 58))
            context.stroke(scale, with: .color(.white.opacity(0.8)), lineWidth: 2)
            let text = scaleMeters >= 1000 ? String(format: "%.0f km", scaleMeters / 1000) : String(format: "%.0f m", scaleMeters)
            context.draw(Text(text).font(.system(size: 8, weight: .medium)).foregroundColor(.white), at: CGPoint(x: 12, y: 65), anchor: .topLeading)
        }
        .background(Color(red: 0.045, green: 0.065, blue: 0.055))
        .accessibilityHidden(true)
    }
}
