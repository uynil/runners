import Foundation

/// Exports only the actual Watch archive. Planned routes cannot enter this API.
enum ActivityTCX {
    static func data(_ archive: ActivityArchive) throws -> Data {
        let summary = try archive.summary
        let samples = try archive.samples().sorted { $0.timestamp < $1.timestamp }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ d: Date) -> String { format.string(from: d) }
        func number(_ n: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), n) }
        var tracks: [[String]] = [], track: [String] = []
        var anchor: (point: RoutePoint, date: Date)?
        var lastGPS: Date?, lastTime: Date?
        var heart: (value: Double, date: Date)?
        var paused = false, distance = 0.0
        var lastRecordedDistance = 0.0
        func close() { if !track.isEmpty { tracks.append(track); track = [] }; anchor = nil; lastGPS = nil }
        for sample in samples {
            guard sample.timestamp >= summary.startedAt, sample.timestamp <= summary.endedAt! else { continue }
            if ["pause", "stop", "interrupted"].contains(sample.kind) { close(); paused = true; heart = nil; continue }
            if sample.kind == "resume" { close(); paused = false; continue }
            if sample.kind == "recoveryGap" { close(); heart = nil; continue }
            guard !paused else { continue }
            var position: RoutePoint?, altitude: Double?
            if sample.kind == "heartRate", let value = sample.heartRate, value.isFinite, (1...300).contains(value) {
                heart = (value, sample.timestamp)
            } else if sample.kind == "gps" {
                guard sample.acceptedForDistance == true, let fix = sample.fix,
                      (0...20).contains(fix.accuracy), fix.accuracy.isFinite else { close(); continue }
                let p = RoutePoint(latitude: fix.latitude, longitude: fix.longitude)
                guard p.isValid else { close(); continue }
                if let lastGPS, sample.timestamp <= lastGPS { continue }
                if let lastGPS, sample.timestamp.timeIntervalSince(lastGPS) > 15 { close() }
                if let previous = anchor {
                    let movement = previous.point.distance(to: p)
                    guard movement <= max(30, sample.timestamp.timeIntervalSince(previous.date) * 12) else { close(); continue }
                    if movement >= 3 { distance += movement; anchor = (p, sample.timestamp) }
                } else { anchor = (p, sample.timestamp) }
                if let recorded = sample.cumulativeDistanceMeters {
                    guard recorded.isFinite, recorded >= lastRecordedDistance, recorded <= summary.distanceMeters + 1 else {
                        throw MapError.invalid("采样距离与运动摘要不一致。")
                    }
                    lastRecordedDistance = recorded
                    distance = recorded
                }
                position = p; lastGPS = sample.timestamp
                if let value = sample.altitudeMeters, let accuracy = sample.verticalAccuracy,
                   value.isFinite, accuracy.isFinite, (0...10).contains(accuracy) { altitude = value }
            } else { continue }
            // Equal timestamps may contain distinct heart and position records; both are valid.
            if let lastTime, sample.timestamp < lastTime { continue }
            lastTime = sample.timestamp
            var point = "<Trackpoint><Time>\(date(sample.timestamp))</Time>"
            if let position { point += "<Position><LatitudeDegrees>\(number(position.latitude))</LatitudeDegrees><LongitudeDegrees>\(number(position.longitude))</LongitudeDegrees></Position>" }
            if let altitude { point += "<AltitudeMeters>\(number(altitude))</AltitudeMeters>" }
            point += "<DistanceMeters>\(number(distance))</DistanceMeters>"
            if let heart, (0...15).contains(sample.timestamp.timeIntervalSince(heart.date)) {
                point += "<HeartRateBpm><Value>\(Int(heart.value.rounded()))</Value></HeartRateBpm>"
            }
            point += "</Trackpoint>"; track.append(point)
        }
        close()
        guard !tracks.isEmpty else { throw MapError.invalid("没有可导出的实际运动采样。") }
        let sport = summary.activity == "hiking" ? "Other" : "Running"
        let notes = archive.simulated == true ? "Runners simulator test — synthetic data" : "Recorded by Runners"
        let energy = summary.metrics?.activeEnergyKilocalories ?? 0
        let calories = energy.isFinite ? Int(min(1_000_000, max(0, energy)).rounded()) : 0
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd"><Activities><Activity Sport="\(sport)"><Id>\(date(summary.startedAt))</Id><Lap StartTime="\(date(summary.startedAt))"><TotalTimeSeconds>\(number(summary.activeSeconds))</TotalTimeSeconds><DistanceMeters>\(number(summary.distanceMeters))</DistanceMeters><Calories>\(calories)</Calories><Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>\(tracks.map { "<Track>" + $0.joined() + "</Track>" }.joined())</Lap><Notes>\(notes)</Notes></Activity></Activities></TrainingCenterDatabase>
        """
        let data = Data(xml.utf8)
        guard data.count <= 24 * 1_024 * 1_024 else { throw MapError.invalid("TCX 文件过大，请保留本地记录后联系支持。") }
        return data
    }
}
