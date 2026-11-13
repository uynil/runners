import Foundation

struct GPSFix: Codable, Equatable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let accuracy: Double

    func distance(to other: GPSFix) -> Double {
        let radians = Double.pi / 180
        let deltaLatitude = (other.latitude - latitude) * radians
        let deltaLongitude = (other.longitude - longitude) * radians
        let a = pow(sin(deltaLatitude / 2), 2)
            + cos(latitude * radians) * cos(other.latitude * radians)
            * pow(sin(deltaLongitude / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(min(1, a)), sqrt(max(0, 1 - a)))
    }
}

struct TrailVertex {
    let fix: GPSFix
    let startsSegment: Bool
}

/// Diagnostic GPS distance only; raw fixes remain in the log, including rejected fixes.
struct DistanceAccumulator {
    private(set) var meters: Double = 0
    private var previous: GPSFix?

    init(meters: Double = 0) { self.meters = meters }

    mutating func breakSegment() { previous = nil }

    mutating func consume(_ fix: GPSFix, receivedAt: Date) -> Bool {
        guard fix.latitude.isFinite, fix.longitude.isFinite,
              (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude),
              fix.accuracy.isFinite, (0...20).contains(fix.accuracy),
              (-1...10).contains(receivedAt.timeIntervalSince(fix.timestamp)) else {
            previous = nil
            return false
        }
        guard let last = previous else { previous = fix; return true }
        let interval = fix.timestamp.timeIntervalSince(last.timestamp)
        guard interval > 0 else { return false }
        if interval > 15 { previous = fix; return true }
        let movement = last.distance(to: fix)
        guard movement <= max(30, interval * 12) else { return false }
        if movement >= 3 {
            meters += movement
            previous = fix
        }
        return true
    }
}

struct RunSummary: Codable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var activeSeconds: Double
    var distanceMeters: Double
    var gpsSampleCount: Int
    var heartSampleCount: Int
    var healthStatus: String
    var healthWorkoutID: UUID?
    // Optional additions preserve decoding of the original diagnostic records.
    var activity: OutdoorActivity? = nil
    var metrics: WorkoutMetrics? = nil
    var laps: [WorkoutLap]? = nil
    var healthRouteStatus: String? = nil
    var healthDistanceStatus: String? = nil
    var lastCheckpointAt: Date? = nil
    var recoveryCount: Int? = nil

    var averagePace: Double? {
        guard distanceMeters >= 10, activeSeconds > 0 else { return nil }
        return activeSeconds / distanceMeters * 1000
    }
}

struct RunSample: Codable {
    var kind: String
    var timestamp: Date
    var receivedAt: Date
    var fix: GPSFix?
    var heartRate: Double?
    var acceptedForDistance: Bool?
    var altitudeMeters: Double? = nil
    var verticalAccuracy: Double? = nil
    var activeEnergyKilocalories: Double? = nil
    var cumulativeDistanceMeters: Double? = nil
    var gapStartedAt: Date? = nil
}

enum OutdoorActivity: String, Codable, CaseIterable, Identifiable {
    case running, trailRunning, hiking
    var id: String { rawValue }
    var title: String {
        switch self {
        case .running: return "跑步"
        case .trailRunning: return "越野跑"
        case .hiking: return "徒步"
        }
    }
}

struct WorkoutLap: Codable, Equatable {
    let number: Int
    let endedAt: Date
    let activeSeconds: Double
    let distanceMeters: Double
    let isPartial: Bool

    var pace: Double? {
        guard distanceMeters >= 10, activeSeconds > 0 else { return nil }
        return activeSeconds / distanceMeters * 1000
    }
}

struct WorkoutMetrics: Codable {
    var elevationSampleCount: Int = 0
    var ascentMeters: Double = 0
    var descentMeters: Double = 0
    var altitudeMeters: Double?
    var heartRateSum: Double = 0
    var heartRateCount: Int = 0
    var maximumHeartRate: Double?
    var activeEnergyKilocalories: Double?

    // Sample mean, not a time-weighted mean; gaps are never interpolated.
    var averageHeartRate: Double? {
        heartRateCount > 0 ? heartRateSum / Double(heartRateCount) : nil
    }

    mutating func recordHeartRate(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        heartRateSum += value
        heartRateCount += 1
        maximumHeartRate = max(maximumHeartRate ?? value, value)
    }
}

/// GPS altitude uses a 3m deadband; accuracy and time gaps reset the anchor.
/// This is a filtered GPS estimate, not barometric elevation or map elevation.
struct ElevationAccumulator {
    private var anchor: Double?
    private var lastDate: Date?
    private(set) var ascent: Double = 0
    private(set) var descent: Double = 0
    private(set) var current: Double?

    init(ascent: Double = 0, descent: Double = 0) {
        self.ascent = ascent; self.descent = descent
    }

    mutating func breakSegment() { anchor = nil; lastDate = nil; current = nil }

    mutating func consume(altitude: Double, accuracy: Double, timestamp: Date) {
        guard altitude.isFinite, accuracy.isFinite, (0...10).contains(accuracy) else {
            breakSegment()
            return
        }
        if let lastDate, timestamp <= lastDate { return }
        if let lastDate, timestamp.timeIntervalSince(lastDate) > 15 { anchor = nil }
        lastDate = timestamp
        guard let anchor else { self.anchor = altitude; current = altitude; return }
        let delta = altitude - anchor
        guard abs(delta) >= 3 else { current = altitude; return }
        // Reject implausible jumps without moving the altitude anchor.
        guard abs(delta) <= 30 else { current = nil; return }
        current = altitude
        if delta > 0 { ascent += delta } else { descent -= delta }
        self.anchor = altitude
    }
}

/// Recent pace uses the same accepted cumulative GPS distance as the summary.
struct RecentPace {
    private var points: [(date: Date, meters: Double)] = []
    mutating func breakSegment() { points = [] }
    mutating func consume(timestamp: Date, meters: Double) {
        if let last = points.last {
            guard timestamp > last.date else { return }
            if timestamp.timeIntervalSince(last.date) > 15 { points = [] }
        }
        points.append((timestamp, meters))
        points.removeAll { timestamp.timeIntervalSince($0.date) > 30 }
    }
    func secondsPerKilometer(at now: Date) -> Double? {
        guard let first = points.first, let last = points.last,
              (-1...10).contains(now.timeIntervalSince(last.date)),
              last.date.timeIntervalSince(first.date) >= 5,
              last.meters - first.meters >= 3 else { return nil }
        return last.date.timeIntervalSince(first.date) / (last.meters - first.meters) * 1000
    }
}
