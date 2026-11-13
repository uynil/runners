import SwiftUI

enum RunPage: Int, CaseIterable {
    case data, map, controls
    var title: String { switch self { case .data: "数据"; case .map: "地图"; case .controls: "控制" } }
    var icon: String { switch self { case .data: "chart.bar.xaxis"; case .map: "map"; case .controls: "slider.horizontal.3" } }
}

struct ContentView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @State private var page = RunPage.data

    var body: some View {
        GeometryReader { bounds in
          VStack(spacing: 0) {
            ZStack {
                RunDashboard(isVisible: page == .data).padding(.top, 30).padding(.bottom, 4)
                    .opacity(page == .data ? 1 : 0).allowsHitTesting(page == .data).accessibilityHidden(page != .data)
                RouteNavigationView(isPage: true, isVisible: page == .map)
                    .opacity(page == .map ? 1 : 0).allowsHitTesting(page == .map).accessibilityHidden(page != .map)
                RunControls().padding(.top, 30)
                    .opacity(page == .controls ? 1 : 0).allowsHitTesting(page == .controls).accessibilityHidden(page != .controls)
            }
            .frame(height: max(0, bounds.size.height - 33))
            .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                guard page != .map, abs(value.translation.width) > abs(value.translation.height) else { return }
                page = RunPage(rawValue: max(0, min(2, page.rawValue + (value.translation.width < 0 ? 1 : -1)))) ?? page
            })
            HStack(spacing: 0) {
                ForEach(RunPage.allCases, id: \.rawValue) { item in
                    Button { page = item } label: {
                        HStack(spacing: 4) {
                            Image(systemName: item.icon)
                            Text(item.title)
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(page == item ? RunStyle.lime : .gray)
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .background(page == item ? RunStyle.lime.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("\(item.title)页")
                        .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 3)
          }
        }
        .background(.black)
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: recorder.message) { _, message in if message != nil { page = .controls } }
        .onChange(of: recorder.storageError) { _, error in if error != nil { page = .controls } }
    }
}

private struct RunDashboard: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.scenePhase) private var scenePhase
    let isVisible: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: isVisible && !dimmed && scenePhase == .active ? 1 : 60)) { timeline in
            GeometryReader { geometry in
                let compact = geometry.size.height < 150
                let now = timeline.date
                VStack(spacing: compact ? 2 : 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "figure.run").foregroundStyle(RunStyle.lime)
                        Text("RUNNERS").tracking(1.6)
                        #if targetEnvironment(simulator)
                        Text("模拟").font(.system(size: 7)).foregroundStyle(.yellow)
                        #endif
                        Spacer(minLength: 0)
                        if recorder.canStart {
                            Button { recorder.start() } label: {
                                Label("开始", systemImage: "play.fill").foregroundStyle(RunStyle.lime)
                                    .frame(minHeight: 14)
                            }.buttonStyle(.plain).accessibilityLabel("开始运动")
                        } else {
                            Circle().fill(RunReadout.phaseColor(recorder.phase)).frame(width: 5, height: 5)
                            Text(RunReadout.phase(recorder.phase))
                        }
                    }.font(.system(size: 9, weight: .bold))

                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: "%.2f", (recorder.summary?.distanceMeters ?? 0) / 1000))
                                .font(.system(size: compact ? 32 : 44, weight: .medium, design: .rounded))
                            Text("km").font(.system(size: 14, weight: .medium)).foregroundStyle(RunStyle.lime)
                        }.foregroundStyle(RunStyle.lime).monospacedDigit()
                    }
                    RunStyle.rule
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("时间").font(.system(size: 9)).foregroundStyle(.gray)
                        Text(RunReadout.time(recorder.activeTime(at: now)))
                            .font(.system(size: compact ? 20 : 27, weight: .medium, design: .rounded)).monospacedDigit()
                            .minimumScaleFactor(0.7).lineLimit(1)
                    }
                    RunStyle.rule
                    HStack(spacing: 0) {
                        metric(RunReadout.pace(seconds: recorder.activeTime(at: now), meters: recorder.summary?.distanceMeters ?? 0),
                               title: "平均配速 /km", color: .white, compact: compact)
                        Rectangle().fill(.white.opacity(0.16)).frame(width: 1).padding(.vertical, 4)
                        metric(RunReadout.heart(recorder, at: now), title: RunReadout.heartLabel(recorder, at: now),
                               color: RunStyle.coral, compact: compact, heart: true)
                    }.frame(height: compact ? 31 : 40)
                    if recorder.canStart {
                        Text("\(recorder.selectedActivity.title) · 点右上角开始")
                            .font(.system(size: 9)).foregroundStyle(.gray)
                    } else {
                        Text(RunReadout.gps(recorder, at: now))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(RunReadout.gpsFresh(recorder, at: now) ? RunStyle.lime : .yellow)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }

    private func metric(_ value: String, title: String, color: Color, compact: Bool, heart: Bool = false) -> some View {
        VStack(spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if heart { Image(systemName: "heart.fill").font(.system(size: 10)) }
                Text(value).font(.system(size: compact ? 20 : 25, weight: .medium, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1).monospacedDigit()
            }.foregroundStyle(color)
            Text(title).font(.system(size: 9)).foregroundStyle(.gray).lineLimit(1)
        }.frame(maxWidth: .infinity)
    }
}

private struct RunControls: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 9) {
                HStack {
                    Text("运动控制").font(.system(size: 15, weight: .bold))
                    Spacer()
                    Text(RunReadout.phase(recorder.phase)).font(.system(size: 10)).foregroundStyle(RunReadout.phaseColor(recorder.phase))
                }
                if recorder.phase == .running || recorder.phase == .paused {
                    Button { recorder.togglePause() } label: {
                        Label(recorder.phase == .paused ? "继续运动" : "暂停运动", systemImage: recorder.phase == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 16, weight: .bold)).frame(maxWidth: .infinity, minHeight: 42)
                    }.buttonStyle(.plain).foregroundStyle(.black)
                        .background(recorder.phase == .paused ? RunStyle.lime : .yellow, in: RoundedRectangle(cornerRadius: 14))
                    Button { confirmEnd = true } label: {
                        Label("结束并保存", systemImage: "stop.fill")
                            .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 42)
                    }.buttonStyle(.plain).foregroundStyle(RunStyle.coral)
                        .background(RunStyle.coral.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                } else if recorder.phase == .authorizing || recorder.phase == .starting || recorder.phase == .saving || recorder.phase == .recovering {
                    ProgressView(RunReadout.phase(recorder.phase))
                    if recorder.phase == .recovering, recorder.message != nil {
                        Button("重试接续") { recorder.recoverIfNeeded() }
                    }
                } else {
                    if let summary = recorder.summary {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(summary.endedAt == nil ? "中断记录已保留" : "上次运动已保存", systemImage: "checkmark.circle")
                                .foregroundStyle(RunStyle.lime)
                            Text(String(format: "%.2f km · %@", summary.distanceMeters / 1000, RunReadout.time(summary.activeSeconds)))
                                .monospacedDigit()
                            Text(summary.healthStatus).foregroundStyle(.gray)
                        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    NavigationLink { ActivitySelectionView().toolbar(.visible, for: .navigationBar) } label: {
                        HStack {
                            Text("运动类型")
                            Spacer()
                            Text(recorder.selectedActivity.title).foregroundStyle(RunStyle.lime)
                        }.font(.system(size: 12))
                    }.disabled(!recorder.canStart)
                    Button("开始新运动", systemImage: "play.fill") { recorder.start() }
                        .tint(RunStyle.lime).disabled(!recorder.canStart)
                }
                if recorder.phase == .running {
                    Button("计圈", systemImage: "flag") { recorder.markLap() }
                }
                NavigationLink { WorkoutDetailsView().toolbar(.visible, for: .navigationBar) } label: {
                    Label("运动指标与分圈", systemImage: "chart.bar.xaxis").font(.system(size: 12))
                }
                NavigationLink { WatchMapsView().toolbar(.visible, for: .navigationBar) } label: {
                    Label("线路与离线地图", systemImage: "map").font(.system(size: 12))
                }
                if let route = recorder.navigationRoute {
                    Text(route.name).font(.system(size: 10)).lineLimit(2).foregroundStyle(.gray)
                    Text(String(format: "导航路线 %.2f km", route.distanceMeters / 1000)).font(.system(size: 10)).foregroundStyle(.gray)
                }
                if let error = recorder.storageError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                    Button("重试本地保存") { recorder.checkpoint() }
                }
                if let message = recorder.message { Text(message).font(.caption2).foregroundStyle(.yellow) }
                Text("地图保持北向上 · 滑动或点底部切换页面")
                    .font(.system(size: 9)).foregroundStyle(.gray)
            }.padding(.horizontal, 10).padding(.vertical, 5)
        }
        .confirmationDialog("结束本次运动并保存？", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) { recorder.stopAndSave() }
            Button("继续运动", role: .cancel) {}
        }
    }
}

private struct ActivitySelectionView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(OutdoorActivity.allCases) { activity in
            Button {
                guard recorder.canStart else { return }
                recorder.selectedActivity = activity
                dismiss()
            } label: {
                HStack {
                    Text(activity.title)
                    Spacer()
                    if recorder.selectedActivity == activity { Image(systemName: "checkmark").foregroundStyle(RunStyle.lime) }
                }
            }.disabled(!recorder.canStart)
        }.navigationTitle("运动类型")
    }
}
