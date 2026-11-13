import SwiftUI

struct ActivityHistoryView: View {
    @EnvironmentObject private var activities: PhoneActivityStore
    @EnvironmentObject private var watch: WatchConnection
    var body: some View {
        List {
            if let error = activities.error { Text(error).foregroundStyle(.red) }
            if let message = activities.syncMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if activities.entries.isEmpty {
                Text("Watch 结束运动后，记录会同步到这里。离线记录保留在 Watch，连接恢复后可重试。")
            }
            ForEach(activities.entries) { entry in
                NavigationLink {
                    ActivityDetailView(entry: entry)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        if entry.archive.simulated == true { Text("模拟器测试记录").font(.caption).foregroundStyle(.orange) }
                        Text(entry.summary.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text(String(format: "%.2f km · %.0f 分钟", entry.summary.distanceMeters / 1000, entry.summary.activeSeconds / 60))
                        Text("手机已保存 · \(entry.summary.healthStatus)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("运动").refreshable { activities.reload(); watch.requestActivitySync() }
        .toolbar { Button("同步记录") { watch.requestActivitySync() } }
    }
}

private struct ActivityDetailView: View {
    let entry: PhoneActivityStore.Entry
    @EnvironmentObject private var activities: PhoneActivityStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    private var route: PlannedRoute? {
        guard let segments = try? entry.archive.track(), !segments.isEmpty else { return nil }
        return PlannedRoute(name: "实际运动轨迹", sourceName: "Watch", segments: segments)
    }
    var body: some View {
        List {
            if entry.archive.simulated == true { Text("模拟器测试记录 · 合成数据").foregroundStyle(.orange) }
            Section("实际轨迹") {
                if let route { RouteShapeView(route: route).frame(height: 260) }
                else { Text("没有足够的有效 GPS 点，不生成轨迹。") }
                Text("实际记录示意 · 无底图").font(.caption).foregroundStyle(.secondary)
            }
            Section("活动摘要") {
                if let count = entry.summary.recoveryCount, count > 0 {
                    Label("记录中断后接续 \(count) 次；缺测区间未补写。", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("开始", value: entry.summary.startedAt.formatted())
                LabeledContent("距离", value: String(format: "%.2f km", entry.summary.distanceMeters / 1000))
                LabeledContent("活动时间", value: duration(entry.summary.activeSeconds))
                if let end = entry.summary.endedAt { LabeledContent("总经过时间", value: duration(end.timeIntervalSince(entry.summary.startedAt))) }
                if entry.summary.distanceMeters >= 10 {
                    LabeledContent("平均配速", value: pace(entry.summary.activeSeconds / entry.summary.distanceMeters * 1000))
                }
                let rates = ((try? entry.archive.samples()) ?? []).compactMap(\.heartRate).filter { $0.isFinite && (1...300).contains($0) }
                LabeledContent("采样平均心率", value: rates.isEmpty ? "无心率数据" : String(format: "%.0f bpm", rates.reduce(0, +) / Double(rates.count)))
            }
            Section("保存与同步") {
                LabeledContent("iPhone", value: "已校验保存")
                LabeledContent("Apple Health", value: entry.summary.healthStatus)
                if let status = entry.summary.healthRouteStatus { LabeledContent("健康轨迹", value: status) }
                if let status = entry.summary.healthDistanceStatus { LabeledContent("健康距离", value: status) }
                Text("删除手机记录不会删除 Watch、Apple Health 或 Strava 中的记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("删除手机记录", role: .destructive) { deleting = true }
            }
            ActivityStravaView(archive: entry.archive, summary: entry.summary)
        }.navigationTitle("运动详情").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("仅删除此 iPhone 的运动记录？", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除手机记录", role: .destructive) {
                activities.remove(entry.id)
                if !activities.entries.contains(where: { $0.id == entry.id }) { dismiss() }
            }
        }
    }
    private func pace(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds, 31_536_000)))
        return String(format: "%d′%02d″ / km", value / 60, value % 60)
    }
    private func duration(_ seconds: Double) -> String {
        let value = Int(max(0, min(seconds, 31_536_000)))
        return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
