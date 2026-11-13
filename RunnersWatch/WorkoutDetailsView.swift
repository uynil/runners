import SwiftUI

struct WorkoutDetailsView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            ScrollView {
                if let summary = recorder.summary {
                    VStack(alignment: .leading, spacing: 10) {
                        Text((summary.activity ?? .running).title).font(.headline)
                        row("总时长", time(recorder.elapsed(at: timeline.date)))
                        row("活动时间", time(recorder.activeTime(at: timeline.date)))
                        row("GPS 距离", String(format: "%.2f km", summary.distanceMeters / 1000))
                        row("平均配速", pace(summary.distanceMeters >= 10 ? recorder.activeTime(at: timeline.date) / summary.distanceMeters * 1000 : nil))
                        let current = recorder.currentPace(at: timeline.date)
                        if summary.activity == .hiking {
                            row("近期速度", current.map { String(format: "%.1f km/h", 3600 / $0) } ?? "--")
                        } else {
                            row("近期配速", pace(current))
                        }
                        let fresh = recorder.lastFix.map { (-1...10).contains(timeline.date.timeIntervalSince($0.timestamp)) } ?? false
                        row("GPS 海拔", number(recorder.phase == .running && fresh ? summary.metrics?.altitudeMeters : nil, unit: "m"))
                        let hasElevation = (summary.metrics?.elevationSampleCount ?? 0) > 0
                        row("累计爬升", number(hasElevation ? summary.metrics?.ascentMeters : nil, unit: "m"))
                        row("累计下降", number(hasElevation ? summary.metrics?.descentMeters : nil, unit: "m"))
                        row("平均心率¹", number(summary.metrics?.averageHeartRate, unit: "bpm"))
                        row("最高心率", number(summary.metrics?.maximumHeartRate, unit: "bpm"))
                        row("活动热量", number(summary.metrics?.activeEnergyKilocalories, unit: "kcal"))
                        if let status = summary.healthRouteStatus { row("Apple Health 轨迹", status) }
                        if let status = summary.healthDistanceStatus { row("Apple Health 距离", status) }
                        if recorder.phase == .running {
                            Button("计圈") { recorder.markLap() }
                        }
                        ForEach((summary.laps ?? []).indices, id: \.self) { index in
                            let lap = summary.laps![index]
                            VStack(alignment: .leading, spacing: 3) {
                                Text("第 \(lap.number) 圈\(lap.isPartial ? " · 末段" : "")")
                                Text(String(format: "%.2f km · %@", lap.distanceMeters / 1000, time(lap.activeSeconds)))
                                Text(pace(lap.pace))
                            }.font(.caption2)
                        }
                        Text("¹心率为有效样本均值；爬升下降为过滤后的 GPS 估算。缺失或过期数据不补造。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.horizontal, 6)
                } else {
                    Text("开始运动后查看指标与分圈").font(.caption)
                }
            }
        }.navigationTitle("运动指标与分圈")
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded)).monospacedDigit()
        }
    }

    private func number(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "--" }
        return String(format: "%.0f %@", value, unit)
    }

    private func pace(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0, value < 36000 else { return "--" }
        let seconds = Int(value.rounded())
        return String(format: "%d:%02d /km", seconds / 60, seconds % 60)
    }

    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
