import SwiftUI

struct RouteCueReviewView: View {
    let routeID: UUID
    let map: OfflineMap
    @EnvironmentObject private var store: PhoneStore
    @State private var assessment: RoutePreparation?
    @State private var cues: [RouteCue] = []
    @State private var selected: RouteCue?
    @State private var generated = false
    @State private var manualProgress = 100.0
    @State private var manualTurn = "straight"
    private var route: PlannedRoute? { store.routes.first { $0.id == routeID } }

    var body: some View {
        List {
            if let route {
                Section {
                    RouteShapeView(route: route, map: map, currentPosition: selected?.coordinate).frame(height: 230)
                    Text("点路口可在地图上定位。请按实际道路核验方向，再勾选启用；未核验候选不会触发手表指引。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let assessment {
                    Section("路网检查") {
                        LabeledContent("沿线采样点邻近道路", value: String(format: "%.0f%%", assessment.roadCoverage * 100))
                        Text(assessment.warning ?? "轨迹附近有 OSM 路网；这不代表所有当地步道都完整。")
                            .font(.caption).foregroundStyle(assessment.warning == nil ? Color.secondary : .orange)
                        Text("当前未接入地形等高线数据；纯轨迹弯道不会冒充主路口。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("从当前路网重新生成候选") { cues = assessment.candidates; generated = true; save() }
                    }
                }
                Section("路口 \(cues.filter(\.confirmed).count) / \(cues.count) 已核验") {
                    if cues.isEmpty { Text("没有可可靠识别的路口节点。可继续轨迹导航；此线路尚无路口提醒。") }
                    ForEach($cues) { $cue in
                        VStack(alignment: .leading, spacing: 7) {
                            Button { selected = cue } label: {
                                Text(String(format: "%.2f km · %@", cue.progressMeters / 1000, cue.title))
                            }.buttonStyle(.plain)
                            Picker("方向", selection: $cue.turn) {
                                Text("左转").tag("left"); Text("右转").tag("right"); Text("直行").tag("straight")
                            }.pickerStyle(.segmented)
                            Toggle("实际道路已核验", isOn: $cue.confirmed)
                        }.padding(.vertical, 4)
                    }
                }
                Section("补充路口") {
                    Text(String(format: "沿线 %.2f km", manualProgress / 1000)).monospacedDigit()
                    Slider(value: $manualProgress, in: 0...max(1, route.distanceMeters))
                    Picker("方向", selection: $manualTurn) {
                        Text("左转").tag("left"); Text("右转").tag("right"); Text("直行").tag("straight")
                    }.pickerStyle(.segmented)
                    Button("在此沿线位置添加候选路口") {
                        if let cue = try? RouteCue.manual(route: route, progress: manualProgress, turn: manualTurn) {
                            cues.append(cue); cues.sort { $0.progressMeters < $1.progressMeters }; selected = cue
                        }
                    }.disabled(cues.count >= 2_000)
                    Text("缺少 OSM 路口时，可按沿线距离手工补充；仍需在地图和实际道路上核验后启用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("修改后需重新发送线路和地图到 Watch。提示按导入线路顺序触发，偏航不自动重算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("路口核验").navigationBarTitleDisplayMode(.inline)
        .task {
            guard let route else { return }
            manualProgress = min(100, route.distanceMeters)
            assessment = await Task.detached { RoutePreparation.analyze(route: route, map: map) }.value
            cues = route.cues ?? assessment?.candidates ?? []
            generated = true
            if route.cues == nil { save() }
        }
        .onChange(of: cues) { _, _ in if generated { save() } }
    }
    private func save() {
        guard var route else { return }
        route.cues = cues; route.cuesUpdatedAt = Date(); store.update(route)
    }
}
