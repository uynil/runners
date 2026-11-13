import Foundation
import Combine
import AuthenticationServices
import Security
import UIKit

private enum StravaKeychain {
    static let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.uynil.Runners.strava", kSecAttrAccount as String: "tokens"]
    static func read() throws -> StravaTokens? {
        var query = base; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MapError.invalid("Strava 安全凭据暂不可读取。") }
        return try JSONDecoder().decode(StravaTokens.self, from: data).validated()
    }
    static func save(_ tokens: StravaTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var query = base; query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw MapError.invalid("Strava 凭据无法安全保存。") }
        } else if update != errSecSuccess { throw MapError.invalid("Strava 凭据更新失败，请重新连接。") }
    }
    static func remove() throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MapError.invalid("无法移除 Strava 凭据。") }
    }
}

@MainActor
final class StravaStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var jobs: [StravaUploadJob] = []
    @Published private(set) var accountID: Int64?
    @Published private(set) var busy = false
    @Published private(set) var authenticating = false
    @Published var message: String?
    private var available = true
    private var tokens: StravaTokens?
    private var auth: ASWebAuthenticationSession?
    private var attempt: StravaOAuthAttempt?
    private var worker: Task<Void, Never>?
    private let api = StravaAPI()
    private let storage = StravaQueueStorage(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Runners/strava-queue.json"))
    var configuration: StravaConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: "stravaConfiguration") else { return nil }
        return try? JSONDecoder().decode(StravaConfiguration.self, from: data)
    }
    override init() {
        super.init()
        do { tokens = try StravaKeychain.read(); accountID = tokens?.athlete?.id }
        catch { message = "Strava 凭据暂不可用，请解锁手机或重新连接。" }
        do { jobs = try storage.load() }
        catch { available = false; message = "上传队列读取失败，原文件已保留，已停止自动上传。" }
    }
    func configure(_ value: StravaConfiguration) {
        guard accountID == nil, !busy, !authenticating else { message = "请先断开 Strava 再更改配置。"; return }
        do { try value.validate(); UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "stravaConfiguration"); objectWillChange.send(); message = "配置已保存，可连接 Strava。" }
        catch { message = error.localizedDescription }
    }
    func connect() {
        guard let configuration, !authenticating, !busy else { message = "请先完成 Strava 公开配置。"; return }
        do {
            let attempt = try StravaOAuthAttempt(configuration: configuration)
            self.attempt = attempt; authenticating = true; message = nil
            let session = ASWebAuthenticationSession(url: attempt.authorizationURL, callbackURLScheme: "runners") { [weak self] url, error in
                Task { @MainActor in
                    guard let self else { return }
                    defer { self.authenticating = false; self.auth = nil; self.attempt = nil }
                    guard error == nil, let url, let current = self.attempt else { self.message = "已取消连接。"; return }
                    do {
                        let code = try current.code(from: url)
                        let tokens = try await self.api.tokens(configuration: current.configuration, code: code)
                        guard let id = tokens.athlete?.id, id > 0 else { throw MapError.invalid("未返回有效 Strava 账号。") }
                        try StravaKeychain.save(tokens); self.tokens = tokens; self.accountID = id; self.message = "Strava 已连接。"
                    } catch { self.message = (error as? MapError)?.localizedDescription ?? "连接失败，请检查令牌服务后重试。" }
                }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = true
            auth = session
            if !session.start() { authenticating = false; self.attempt = nil; auth = nil; message = "无法打开 Strava 授权。" }
        } catch { message = error.localizedDescription }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func disconnect(revoke: Bool) async {
        guard !busy, !authenticating else { message = "请等待当前操作完成后断开。"; return }
        busy = true
        defer { busy = false }
        do {
            if revoke {
                guard let tokens, let configuration else {
                    message = "缺少撤权配置；可移除本机连接，并在 Strava 网站撤销授权。"
                    return
                }
                try await api.revoke(configuration: configuration, token: tokens.refresh_token)
            }
            try StravaKeychain.remove(); tokens = nil; accountID = nil
            message = revoke ? "已撤销 Strava 授权。" : "已移除本机连接；可在 Strava 网站撤销授权。"
        } catch { message = "断开未完成，连接信息已保留，请检查网络后重试。" }
    }
    func job(for id: UUID) -> StravaUploadJob? { jobs.first { $0.workoutID == id && $0.accountID == accountID } }
    private func save(_ job: StravaUploadJob) throws {
        var next = jobs.filter { $0.id != job.id }; next.append(job)
        try storage.save(next); jobs = next
    }
    func enqueue(_ archive: ActivityArchive) {
        guard available, let accountID else { message = "请先连接 Strava。"; return }
        do {
            guard archive.simulated != true else { throw MapError.invalid("模拟器测试活动禁止上传 Strava，可导出测试文件。") }
            let summary = try archive.summary
            if job(for: summary.id) == nil { try save(StravaUploadJob(workoutID: summary.id, accountID: accountID)) }
            resume()
        } catch { message = error.localizedDescription }
    }
    func retry(_ original: StravaUploadJob, confirmedUnknown: Bool = false) {
        guard !busy, original.accountID == accountID, original.phase != .uploaded else { return }
        if original.phase == .unknown && !confirmedUnknown { message = "请先在 Strava 核对是否已生成活动。"; return }
        do {
            var job = original
            job.phase = job.uploadID == nil ? .queued : .processing
            job.message = nil
            job.nextAttempt = original.phase == .waiting ? max(Date(), original.nextAttempt) : Date()
            try save(job); resume()
        } catch { message = "无法保存重试状态，请检查手机存储。" }
    }
    func resume() {
        guard !busy, !authenticating, available, accountID != nil else { return }
        busy = true
        worker = Task {
            defer { busy = false; worker = nil }
            while !Task.isCancelled {
                let candidates = jobs.filter { $0.accountID == accountID && $0.resumesAutomatically }
                guard let job = candidates.min(by: { $0.nextAttempt < $1.nextAttempt }) else { return }
                let wait = job.nextAttempt.timeIntervalSinceNow
                if wait > 0 {
                    if wait > 60 { return } // No background timer held for long rate limits.
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                await run(job)
            }
        }
    }
    func suspend() { worker?.cancel() }
    private func accessToken() async throws -> String {
        guard var current = tokens, let configuration, current.athlete?.id == accountID else { throw StravaFailure.unauthorized }
        if current.expires_at <= Date().timeIntervalSince1970 + 60 {
            var refreshed = try await api.tokens(configuration: configuration, refresh: current.refresh_token)
            refreshed.athlete = current.athlete
            try StravaKeychain.save(refreshed); tokens = refreshed; current = refreshed
        }
        return current.access_token
    }
    private func run(_ original: StravaUploadJob) async {
        var job = original
        do {
            let token = try await accessToken()
            try Task.checkCancellation()
            guard job.accountID == accountID else { return }
            let data = try Data(contentsOf: PhoneActivityStore.storage.fileURL(job.workoutID))
            let archive = try ActivityStorage.decode(data)
            let summary = try archive.summary
            guard summary.id == job.workoutID else { throw MapError.invalid("运动记录标识不一致。") }
            if let activityID = job.activityID {
                try await api.setSport(activityID: activityID, activity: summary.activity, token: token)
                job.phase = .uploaded; job.message = nil; try save(job); return
            }
            let response: StravaUploadResponse
            if let id = job.uploadID { response = try await api.poll(id: id, token: token) }
            else {
                guard job.maySubmitNewFile else { return }
                _ = try ActivityTCX.data(archive)
                guard archive.simulated != true else { throw MapError.invalid("模拟活动禁止上传。") }
                job.phase = .submitting; try save(job) // Persist BEFORE the non-idempotent request.
                response = try await api.upload(archive, token: token)
            }
            guard response.id > 0 else { throw StravaFailure.uncertain }
            job.uploadID = response.id; job.activityID = response.activity_id
            if response.error?.isEmpty == false { job.phase = .failed; job.message = "Strava 处理失败或活动重复，请先在 Strava 核对。" }
            else { job.phase = .processing; job.nextAttempt = Date().addingTimeInterval(min(60, pow(2, Double(min(5, job.attempts + 1))))); job.attempts += 1 }
            try save(job)
        } catch {
            if !available { return }
            switch error {
            case StravaFailure.unauthorized:
                job.phase = .failed; job.message = "Strava 授权失效，请重新连接后重试。"
            case StravaFailure.rateLimited(let seconds):
                job.phase = .waiting; job.nextAttempt = Date().addingTimeInterval(seconds); job.message = "Strava 限流，稍后自动或手动继续。"
            case StravaFailure.rejected:
                job.phase = .failed; job.message = "Strava 拒绝请求，请核对活动或重新连接。"
            default:
                if job.phase == .submitting && job.uploadID == nil {
                    job.phase = .unknown; job.message = "提交结果未知，请先在 Strava 核对；不会自动重复提交。"
                } else if error is MapError || error is CocoaError {
                    job.phase = .failed; job.message = "本地记录或配置不可用，请检查后重试。"
                } else {
                    job.phase = .waiting; job.attempts += 1
                    job.nextAttempt = Date().addingTimeInterval(min(900, pow(2, Double(min(9, job.attempts))) * 5))
                    job.message = "网络暂不可用，已保留处理进度。"
                }
            }
            do { try save(job) } catch { available = false; message = "上传进度无法落盘，已停止自动上传以防重复。" }
        }
    }
}
