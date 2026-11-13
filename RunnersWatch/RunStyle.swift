import SwiftUI

enum RunStyle {
    static let lime = Color(red: 0.76, green: 0.98, blue: 0.30)
    static let coral = Color(red: 1, green: 0.37, blue: 0.39)
    static var rule: some View { Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5) }
}

@MainActor enum RunReadout {
    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
    static func pace(seconds: Double, meters: Double) -> String {
        guard seconds > 0, meters >= 20 else { return "--′--″" }
        let pace = seconds / (meters / 1000)
        guard pace < 3600 else { return ">59′" }
        let s = Int(pace.rounded())
        return String(format: "%d′%02d″", s / 60, s % 60)
    }
    static func heart(_ recorder: WorkoutRecorder, at now: Date) -> String {
        guard recorder.phase == .running, let date = recorder.heartDate, let value = recorder.heartRate,
              (-1...15).contains(now.timeIntervalSince(date)) else { return "--" }
        return String(format: "%.0f", value)
    }
    static func heartLabel(_ recorder: WorkoutRecorder, at now: Date) -> String {
        if recorder.phase == .paused { return "心率 · 已暂停" }
        guard recorder.phase == .running else { return "实时心率 bpm" }
        guard let date = recorder.heartDate else { return "等待心率" }
        return (-1...15).contains(now.timeIntervalSince(date)) ? "实时心率 bpm" : "心率已过期"
    }
    static func gpsFresh(_ recorder: WorkoutRecorder, at now: Date) -> Bool {
        guard recorder.phase == .running, let fix = recorder.lastFix else { return false }
        return (-1...10).contains(now.timeIntervalSince(fix.timestamp)) && (0...20).contains(fix.accuracy)
    }
    static func gps(_ recorder: WorkoutRecorder, at now: Date) -> String {
        if recorder.phase == .paused { return "已暂停 · GPS 停止采集" }
        guard let fix = recorder.lastFix else { return recorder.locationStatus }
        guard gpsFresh(recorder, at: now) else { return "GPS 信号弱或位置已过期" }
        return String(format: "GPS ±%.0f m", fix.accuracy)
    }
    static func phase(_ phase: WorkoutRecorder.Phase) -> String {
        switch phase {
        case .idle: "准备"; case .authorizing: "授权中"; case .starting: "准备中"
        case .running: "记录中"; case .paused: "已暂停"; case .saving: "保存中"; case .finished: "已结束"
        }
    }
    static func phaseColor(_ phase: WorkoutRecorder.Phase) -> Color {
        switch phase { case .running: RunStyle.lime; case .paused, .authorizing, .starting: .yellow; default: .gray }
    }
}
