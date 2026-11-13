import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct StravaConfiguration: Codable, Equatable {
    let clientID: String
    let brokerURL: URL
    let redirectURL: URL
    func validate() throws {
        guard !clientID.isEmpty, clientID.allSatisfy({ "0123456789".contains($0) }), brokerURL.scheme == "https", brokerURL.host != nil,
              brokerURL.user == nil, brokerURL.password == nil, brokerURL.query == nil, brokerURL.fragment == nil,
              redirectURL.scheme == "runners", redirectURL.host != nil, redirectURL.host != "maps",
              redirectURL.user == nil, redirectURL.password == nil, redirectURL.query == nil, redirectURL.fragment == nil else {
            throw MapError.invalid("请填写 Strava Client ID、HTTPS 令牌服务地址及 runners:// 回调地址。")
        }
    }
}

struct StravaOAuthAttempt {
    let state: String
    let startedAt: Date
    let configuration: StravaConfiguration
    init(configuration: StravaConfiguration, now: Date = Date(), state: String = UUID().uuidString + UUID().uuidString) throws {
        try configuration.validate(); self.configuration = configuration; self.startedAt = now; self.state = state
    }
    var authorizationURL: URL {
        var c = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        c.queryItems = [URLQueryItem(name: "client_id", value: configuration.clientID),
                       URLQueryItem(name: "redirect_uri", value: configuration.redirectURL.absoluteString),
                       URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "approval_prompt", value: "force"),
                       URLQueryItem(name: "scope", value: "activity:write"), URLQueryItem(name: "state", value: state)]
        return c.url!
    }
    func code(from callback: URL, now: Date = Date()) throws -> String {
        guard (0...600).contains(now.timeIntervalSince(startedAt)), callback.scheme == configuration.redirectURL.scheme,
              callback.host == configuration.redirectURL.host, callback.path == configuration.redirectURL.path,
              callback.fragment == nil, callback.user == nil, callback.password == nil, callback.port == nil,
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw MapError.invalid("授权回调无效或已过期，请重新连接。")
        }
        for name in ["state", "code", "scope", "error"] where query.filter({ $0.name == name }).count > 1 {
            throw MapError.invalid("授权回调包含重复参数。")
        }
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard value("state") == state else { throw MapError.invalid("授权状态校验失败，请重新连接。") }
        if value("error") != nil { throw MapError.invalid("Strava 授权已取消或被拒绝。") }
        let scopes = Set((value("scope") ?? "").split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
        guard scopes.contains("activity:write"), let code = value("code"), !code.isEmpty, code.count <= 2_000 else {
            throw MapError.invalid("需要 Strava 活动上传权限才能连接。")
        }
        return code
    }
}

struct StravaTokens: Codable {
    struct Athlete: Codable { let id: Int64 }
    let access_token: String
    let refresh_token: String
    let expires_at: TimeInterval
    var athlete: Athlete?
    func validated() throws -> StravaTokens {
        guard !access_token.isEmpty, !refresh_token.isEmpty, access_token.count <= 4_096,
              refresh_token.count <= 4_096, expires_at.isFinite, expires_at > 0,
              (access_token + refresh_token).unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              athlete == nil || athlete!.id > 0 else { throw MapError.invalid("令牌服务响应无效。") }
        return self
    }
}

struct StravaUploadResponse: Codable {
    let id: Int64
    let activity_id: Int64?
    let error: String?
    let status: String?
}

enum StravaFailure: Error {
    case unauthorized
    case rateLimited(TimeInterval)
    case rejected
    case uncertain
}

struct StravaAPI {
    typealias Fetch = (URLRequest) async throws -> (Data, HTTPURLResponse)
    var fetch: Fetch = Self.network
    static func network(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard data.count <= 1_024 * 1_024, let response = response as? HTTPURLResponse else { throw StravaFailure.uncertain }
        return (data, response)
    }
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: StravaNoRedirect(), delegateQueue: nil)
    }()
    func tokens(configuration: StravaConfiguration, code: String? = nil, refresh: String? = nil) async throws -> StravaTokens {
        try configuration.validate()
        let endpoint = configuration.brokerURL.appendingPathComponent(refresh == nil ? "oauth/exchange" : "oauth/refresh")
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["client_id": configuration.clientID, code == nil ? "refresh_token" : "code": code ?? refresh ?? ""])
        let (data, response) = try await fetch(request)
        try check(response)
        return try JSONDecoder().decode(StravaTokens.self, from: data).validated()
    }
    func upload(_ archive: ActivityArchive, token: String) async throws -> StravaUploadResponse {
        guard archive.simulated != true else { throw MapError.invalid("模拟器测试活动禁止上传 Strava。") }
        let id = try archive.summary.id
        let file = try ActivityTCX.data(archive), boundary = "Runners-\(UUID().uuidString)"
        var body = Data()
        func text(_ value: String) { body.append(Data(value.utf8)) }
        for (key, value) in [("data_type", "tcx"), ("external_id", "runners-\(id.uuidString).tcx"), ("name", "Runners")] {
            text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(id.uuidString).tcx\"\r\nContent-Type: application/vnd.garmin.tcx+xml\r\n\r\n")
        body.append(file); text("\r\n--\(boundary)--\r\n")
        var request = authorized("uploads", token: token)
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await fetch(request)
        try check(response)
        return try JSONDecoder().decode(StravaUploadResponse.self, from: data)
    }
    func poll(id: Int64, token: String) async throws -> StravaUploadResponse {
        guard id > 0 else { throw StravaFailure.rejected }
        let (data, response) = try await fetch(authorized("uploads/\(id)", token: token))
        try check(response)
        return try JSONDecoder().decode(StravaUploadResponse.self, from: data)
    }
    func setSport(activityID: Int64, activity: String?, token: String) async throws {
        var request = authorized("activities/\(activityID)", token: token)
        request.httpMethod = "PUT"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let sport = activity == "trailRunning" ? "TrailRun" : (activity == "hiking" ? "Hike" : "Run")
        request.httpBody = Data("sport_type=\(sport)".utf8)
        let (_, response) = try await fetch(request); try check(response)
    }
    func revoke(configuration: StravaConfiguration, token: String) async throws {
        try configuration.validate()
        var request = URLRequest(url: configuration.brokerURL.appendingPathComponent("oauth/revoke"), timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["client_id": configuration.clientID, "token": token])
        let (_, response) = try await fetch(request); try check(response)
    }
    private func authorized(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/")!.appendingPathComponent(path), timeoutInterval: 45)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299: break
        case 401: throw StravaFailure.unauthorized
        case 429:
            let raw = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 900
            throw StravaFailure.rateLimited(min(86_400, max(60, raw)))
        case 400...499: throw StravaFailure.rejected
        default: throw StravaFailure.uncertain
        }
    }
}

private final class StravaNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
