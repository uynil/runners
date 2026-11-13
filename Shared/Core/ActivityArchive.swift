import Foundation

struct ActivitySummary: Decodable, Identifiable {
    struct Metrics: Decodable { let activeEnergyKilocalories: Double? }
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let activeSeconds: Double
    let distanceMeters: Double
    let gpsSampleCount: Int
    let heartSampleCount: Int
    let healthStatus: String
    let activity: String?
    let healthRouteStatus: String?
    let healthDistanceStatus: String?
    let metrics: Metrics?
}

struct ActivitySample: Decodable {
    struct Fix: Decodable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double
    }
    let kind: String
    let timestamp: Date
    let fix: Fix?
    let heartRate: Double?
    let acceptedForDistance: Bool?
    let altitudeMeters: Double?
    let verticalAccuracy: Double?
    let cumulativeDistanceMeters: Double?
}

/// Preserves the Watch's original summary and append-only samples, including future fields.
struct ActivityArchive: Codable {
    var schemaVersion = 1
    var simulated: Bool? = nil
    let summaryData: Data
    let samplesData: Data
    var summary: ActivitySummary {
        get throws {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
            let result = try decoder.decode(ActivitySummary.self, from: summaryData)
            guard schemaVersion == 1, let end = result.endedAt, end >= result.startedAt,
                  result.startedAt.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  (0...4_102_444_800).contains(result.startedAt.timeIntervalSince1970),
                  end.timeIntervalSince1970 <= 4_102_444_800,
                  result.activeSeconds.isFinite, result.activeSeconds >= 0,
                  result.activeSeconds <= end.timeIntervalSince(result.startedAt) + 2,
                  result.distanceMeters.isFinite, result.distanceMeters >= 0,
                  result.gpsSampleCount >= 0, result.heartSampleCount >= 0 else {
                throw MapError.invalid("运动记录尚未结束或摘要无效。")
            }
            return result
        }
    }
    func samples() throws -> [ActivitySample] {
        guard samplesData.count <= 16 * 1_024 * 1_024 else { throw MapError.invalid("运动采样记录过大。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let lines = samplesData.split(separator: 10)
        guard lines.count <= 200_000 else { throw MapError.invalid("运动采样数量过多。") }
        return try lines.map { try decoder.decode(ActivitySample.self, from: Data($0)) }
    }
    func track() throws -> [[RoutePoint]] {
        var segments: [[RoutePoint]] = [], current: [RoutePoint] = []
        func close() { if current.count >= 2 { segments.append(current) }; current = [] }
        var previousDate: Date?
        for sample in try samples() {
            if ["pause", "resume", "interrupted", "stop"].contains(sample.kind) { close(); previousDate = nil }
            guard sample.kind == "gps" else { continue }
            guard sample.acceptedForDistance == true, let fix = sample.fix,
                  fix.accuracy.isFinite, (0...20).contains(fix.accuracy) else { close(); previousDate = nil; continue }
            let point = RoutePoint(latitude: fix.latitude, longitude: fix.longitude)
            guard point.isValid else { close(); previousDate = nil; continue }
            if let date = previousDate, sample.timestamp.timeIntervalSince(date) > 15 { close() }
            current.append(point); previousDate = sample.timestamp
        }
        close()
        return segments
    }
}

struct ActivityReceipt: Codable {
    let id: UUID
    let checksum: String
    let receivedAt: Date
}

struct ActivityStorage {
    let directory: URL
    func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".runnersactivity") }
    static func encode(_ archive: ActivityArchive) throws -> Data {
        _ = try archive.summary; _ = try archive.samples()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(archive)
        let data = try encoder.encode(MapBundleStorage.Envelope(sha256: MapBundleStorage.digest(payload), payload: payload))
        guard data.count <= MapBundleStorage.maximumBytes else { throw MapError.invalid("运动归档超过 24 MB。") }
        return data
    }
    static func decode(_ data: Data) throws -> ActivityArchive {
        guard data.count <= MapBundleStorage.maximumBytes else { throw MapError.invalid("运动归档过大。") }
        let envelope = try JSONDecoder().decode(MapBundleStorage.Envelope.self, from: data)
        guard MapBundleStorage.digest(envelope.payload) == envelope.sha256 else { throw MapError.invalid("运动归档校验失败。") }
        let archive = try JSONDecoder().decode(ActivityArchive.self, from: envelope.payload)
        _ = try archive.summary; _ = try archive.samples()
        return archive
    }
    @discardableResult func save(_ data: Data) throws -> ActivityArchive {
        let archive = try Self.decode(data), id = try archive.summary.id
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let used = try files.filter { $0.lastPathComponent != fileURL(id).lastPathComponent }
            .reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard used + data.count <= MapBundleStorage.quotaBytes else { throw MapError.invalid("手机运动记录占用已达到 150 MB，请先导出或清理。") }
        try data.write(to: fileURL(id), options: .atomic)
        return archive
    }
    func all() throws -> [(ActivityArchive, ActivityReceipt)] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "runnersactivity" }
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      (values.fileSize ?? 0) <= MapBundleStorage.maximumBytes,
                      let data = try? Data(contentsOf: url), let archive = try? Self.decode(data), let summary = try? archive.summary,
                      url.lastPathComponent == fileURL(summary.id).lastPathComponent else { return nil }
                return (archive, ActivityReceipt(id: summary.id, checksum: MapBundleStorage.digest(data), receivedAt: values.contentModificationDate ?? Date()))
            }
    }
}
