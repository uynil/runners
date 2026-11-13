import Foundation

enum StravaUploadPhase: String, Codable {
    case queued, submitting, processing, uploaded, waiting, unknown, failed
    var title: String {
        switch self {
        case .queued: "等待上传"; case .submitting: "正在提交"; case .processing: "Strava 正在处理"
        case .uploaded: "已上传 Strava"; case .waiting: "等待重试"; case .unknown: "提交结果待核对"; case .failed: "上传未完成"
        }
    }
}

struct StravaUploadJob: Codable, Identifiable {
    let workoutID: UUID
    let accountID: Int64
    var id: String { "\(accountID)-\(workoutID.uuidString)" }
    var phase: StravaUploadPhase = .queued
    var uploadID: Int64?
    var activityID: Int64?
    var attempts = 0
    var nextAttempt = Date()
    var message: String?
    var resumesAutomatically: Bool { [.queued, .waiting, .processing].contains(phase) }
    var maySubmitNewFile: Bool { resumesAutomatically && uploadID == nil && activityID == nil }
}

struct StravaQueueStorage {
    let url: URL
    func load() throws -> [StravaUploadJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= 2 * 1_024 * 1_024 else { throw MapError.invalid("Strava 队列过大，原文件已保留。") }
        var jobs = try JSONDecoder().decode([StravaUploadJob].self, from: data)
        guard jobs.count <= 1_000, Set(jobs.map(\.id)).count == jobs.count,
              jobs.allSatisfy({ $0.accountID > 0 && ($0.uploadID == nil || $0.uploadID! > 0) && ($0.activityID == nil || $0.activityID! > 0) }) else {
            throw MapError.invalid("Strava 队列无效，原文件已保留。")
        }
        for i in jobs.indices where jobs[i].phase == .submitting {
            jobs[i].phase = .unknown
            jobs[i].message = "上次提交中断，请先在 Strava 核对，避免重复活动。"
        }
        return jobs
    }
    func save(_ jobs: [StravaUploadJob]) throws {
        guard jobs.count <= 1_000 else { throw MapError.invalid("上传队列已满。") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: url, options: .atomic)
    }
}
