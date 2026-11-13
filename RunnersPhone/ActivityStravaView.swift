import SwiftUI

struct ActivityStravaView: View {
    let archive: ActivityArchive
    let summary: ActivitySummary
    @EnvironmentObject private var strava: StravaStore
    @State private var confirmUnknown = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    var body: some View {
        Section("导出与 Strava") {
            if let exportURL { ShareLink("导出实际运动 TCX", item: exportURL) }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
            if let job = strava.job(for: summary.id) {
                Text(job.phase.title)
                if let message = job.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let id = job.activityID { Link("在 Strava 查看活动", destination: URL(string: "https://www.strava.com/activities/\(id)")!) }
                if job.phase == .unknown {
                    Link("先打开 Strava 核对", destination: URL(string: "https://www.strava.com/athlete/training")!)
                    Button("已核对，需要重新提交") { confirmUnknown = true }.disabled(strava.busy)
                } else if [.queued, .failed, .waiting, .processing].contains(job.phase) {
                    Button("继续或重试上传") { strava.retry(job) }.disabled(strava.busy)
                }
            } else if archive.simulated == true {
                Text("模拟器合成活动可导出测试文件，禁止上传到 Strava。")
                    .font(.caption).foregroundStyle(.orange)
            } else if strava.accountID != nil {
                Button("上传实际运动到 Strava") { strava.enqueue(archive) }
                Text("将发送实际 GPS、运动时间和已记录心率。公开范围遵循你的 Strava 账号设置。")
                    .font(.caption).foregroundStyle(.secondary)
            } else { NavigationLink("连接 Strava 后上传") { StravaSettingsView() } }
            if let message = strava.message { Text(message).font(.caption) }
        }
        .task(id: summary.id) {
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let prefix = archive.simulated == true ? "Runners-simulated-" : "Runners-"
                let url = directory.appendingPathComponent(prefix + summary.id.uuidString + ".tcx")
                try ActivityTCX.data(archive).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                exportURL = url
            } catch { exportError = "TCX 导出未完成；原始记录已保留。" }
        }
        .confirmationDialog("已确认 Strava 没有这条活动？重新提交可能产生重复记录。", isPresented: $confirmUnknown) {
            Button("确认重新提交") {
                if let job = strava.job(for: summary.id) { strava.retry(job, confirmedUnknown: true) }
            }
        }
    }
}
