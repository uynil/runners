import SwiftUI

struct StravaSettingsView: View {
    @EnvironmentObject private var strava: StravaStore
    @State private var clientID = ""
    @State private var broker = ""
    @State private var redirect = "runners://oauth/strava"
    @State private var revoke = false
    var body: some View {
        Form {
            Section("连接状态") {
                if let id = strava.accountID {
                    LabeledContent("Strava 账号", value: String(id))
                    Button("撤销授权并断开", role: .destructive) { revoke = true }.disabled(strava.busy)
                    Button("仅移除本机连接", role: .destructive) { Task { await strava.disconnect(revoke: false) } }.disabled(strava.busy)
                } else {
                    Text(strava.configuration == nil ? "尚未配置 Strava 开发应用" : "尚未连接 Strava")
                    Button("连接 Strava") { strava.connect() }.disabled(strava.configuration == nil || strava.authenticating)
                }
                if strava.authenticating { ProgressView("正在授权…") }
                if let message = strava.message { Text(message).font(.caption) }
            }
            Section("开发应用公开配置") {
                TextField("Client ID", text: $clientID).keyboardType(.numberPad)
                TextField("HTTPS 令牌服务地址", text: $broker).keyboardType(.URL)
                TextField("回调 URI", text: $redirect).keyboardType(.URL)
                Button("保存公开配置") {
                    guard let broker = URL(string: broker.trimmingCharacters(in: .whitespacesAndNewlines)),
                          let redirect = URL(string: redirect.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        strava.message = "服务地址或回调 URI 无效。"; return
                    }
                    strava.configure(StravaConfiguration(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines), brokerURL: broker, redirectURL: redirect))
                }
                Text("Client Secret 仅配置在令牌服务器。请在 Strava 开发应用登记与回调 URI 匹配的域名；本页不接收 Secret。")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(strava.accountID != nil || strava.busy || strava.authenticating)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Section("上传队列") {
                if strava.jobs.isEmpty { Text("在运动详情中选择上传。不会自动上传导入的计划线路。") }
                ForEach(strava.jobs.sorted { $0.nextAttempt > $1.nextAttempt }) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.workoutID.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                        Text(job.phase.title)
                        if let message = job.message { Text(message).font(.caption) }
                        if let id = job.activityID { Link("在 Strava 查看", destination: URL(string: "https://www.strava.com/activities/\(id)")!) }
                    }
                }
                Button("继续待处理上传") { strava.resume() }.disabled(strava.accountID == nil || strava.busy)
                Text("离线保留队列，回到 App 后继续。结果不明的提交会暂停，需核对 Strava 后手动重试。活动公开范围遵循 Strava 账号设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Strava").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let config = strava.configuration { clientID = config.clientID; broker = config.brokerURL.absoluteString; redirect = config.redirectURL.absoluteString }
        }
        .confirmationDialog("撤销 Runners 在 Strava 的授权？已上传活动不会删除。", isPresented: $revoke) {
            Button("撤销并断开", role: .destructive) { Task { await strava.disconnect(revoke: true) } }
        }
    }
}
