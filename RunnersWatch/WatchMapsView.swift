import SwiftUI

struct WatchMapsView: View {
    @EnvironmentObject private var maps: WatchMapReceiver
    @EnvironmentObject private var activities: WatchActivityTransfer
    var body: some View {
        List {
            if let error = maps.error {
                Text(error.contains("WatchConnectivity") || error.contains("WCSession")
                     ? "同步连接尚未就绪，请稍后重试。手表中的离线地图仍可使用。" : error)
                    .font(.caption2).foregroundStyle(.yellow)
            }
            if maps.bundles.isEmpty { Text("在 iPhone 下载离线地图，再发送到 Watch。") }
            ForEach(maps.bundles) { bundle in
                NavigationLink(bundle.route.name) { WatchMapDetail(bundle: bundle) }
            }
            Button("刷新本地地图") { maps.reload() }
            Section("运动同步") {
                Text(activities.status).font(.caption2)
                Button("重试运动同步") { maps.syncActivities() }
            }
        }.navigationTitle("离线线路")
    }
}

private struct WatchMapDetail: View {
    @State private var bundle: RouteMapBundle
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var maps: WatchMapReceiver
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    @State private var navigationMessage: String?
    init(bundle: RouteMapBundle) { _bundle = State(initialValue: bundle) }

    private func position(at now: Date) -> RoutePoint? {
        guard let fix = recorder.lastFix, (-1...10).contains(now.timeIntervalSince(fix.timestamp)),
              (0...20).contains(fix.accuracy) else { return nil }
        return RoutePoint(latitude: fix.latitude, longitude: fix.longitude)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let position = position(at: timeline.date)
            ScrollView {
                VStack(spacing: 8) {
                    RouteShapeView(route: bundle.route, map: bundle.map, currentPosition: position).frame(height: 170)
                    Text("线路与地图已保存在手表").font(.caption2)
                    Button("使用此线路导航") {
                        do {
                            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("navigation-route.json")
                            try JSONEncoder().encode(bundle.route).write(to: url, options: .atomic)
                            recorder.reloadNavigationRoute()
                            navigationMessage = recorder.navigationError ?? "已选用此线路，可打开跑步导航。"
                        } catch { navigationMessage = error.localizedDescription }
                    }.disabled(recorder.phase != .idle && recorder.phase != .finished)
                    if let navigationMessage { Text(navigationMessage).font(.caption2) }
                    NavigationLink("打开跑步导航") { RouteNavigationView() }.font(.caption)
                    if let position, !bundle.map.covers(position) {
                        Text("当前位置在地图覆盖范围外").font(.caption2).foregroundStyle(.yellow)
                    } else if position == nil { Text("暂无新鲜定位；开始运动后可显示当前位置").font(.caption2) }
                    Text("\((bundle.route.cues ?? []).filter(\.confirmed).count) 个已核验路口；直线回线方位不代表可通行道路。")
                        .font(.caption2).foregroundStyle(.secondary)
                    MapAttributionView(map: bundle.map)
                    Button("删除手表地图", role: .destructive) { deleting = true }
                        .disabled(recorder.phase != .idle && recorder.phase != .finished)
                }
            }
        }.navigationTitle(bundle.route.name)
        .onReceive(maps.$bundles) { latest in
            guard recorder.phase == .idle || recorder.phase == .finished else { return }
            if let current = latest.first(where: { $0.id == bundle.id }) { bundle = current }
            else { dismiss() }
        }
        .confirmationDialog("移除手表上的线路和地图？手机副本不受影响。", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除手表地图", role: .destructive) {
                maps.remove(bundle.id)
                if !maps.bundles.contains(where: { $0.id == bundle.id }) { dismiss() }
            }
        }
    }
}
