import XCTest
@testable import RunnersCore

final class RunDataTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func fix(_ latitude: Double = 30, seconds: Double = 0, accuracy: Double = 5) -> GPSFix {
        GPSFix(timestamp: start.addingTimeInterval(seconds), latitude: latitude, longitude: 120, accuracy: accuracy)
    }

    func testFreshMovementMeasuresKnownDistance() {
        var meter = DistanceAccumulator()
        XCTAssertTrue(meter.consume(fix(), receivedAt: start))
        XCTAssertTrue(meter.consume(fix(30.0001, seconds: 5), receivedAt: start.addingTimeInterval(5)))
        XCTAssertEqual(meter.meters, 11.1195, accuracy: 0.02)
    }

    func testStaleAndPoorAccuracyFixesDoNotBridgeTheGap() {
        var meter = DistanceAccumulator()
        _ = meter.consume(fix(), receivedAt: start)
        XCTAssertFalse(meter.consume(fix(30.001, seconds: 1), receivedAt: start.addingTimeInterval(20)))
        _ = meter.consume(fix(30.002, seconds: 21), receivedAt: start.addingTimeInterval(21))
        XCTAssertFalse(meter.consume(fix(30.003, seconds: 22, accuracy: 80), receivedAt: start.addingTimeInterval(22)))
        _ = meter.consume(fix(30.004, seconds: 23), receivedAt: start.addingTimeInterval(23))
        XCTAssertEqual(meter.meters, 0)
    }

    func testOutOfOrderSampleCannotMoveDistanceAnchorBackwards() {
        var meter = DistanceAccumulator()
        _ = meter.consume(fix(seconds: 5), receivedAt: start.addingTimeInterval(5))
        XCTAssertFalse(meter.consume(fix(30.0001, seconds: 4), receivedAt: start.addingTimeInterval(5)))
        _ = meter.consume(fix(30.0001, seconds: 10), receivedAt: start.addingTimeInterval(10))
        XCTAssertEqual(meter.meters, 11.1195, accuracy: 0.02)
    }

    func testLargeJumpDoesNotPoisonTheNextValidSegment() {
        var meter = DistanceAccumulator()
        _ = meter.consume(fix(), receivedAt: start)
        XCTAssertFalse(meter.consume(fix(31, seconds: 1), receivedAt: start.addingTimeInterval(1)))
        _ = meter.consume(fix(30.0001, seconds: 5), receivedAt: start.addingTimeInterval(5))
        XCTAssertEqual(meter.meters, 11.1195, accuracy: 0.02)
    }

    func testPauseAndLongLossOfFixDoNotCreateStraightLineDistance() {
        var meter = DistanceAccumulator()
        _ = meter.consume(fix(), receivedAt: start)
        meter.breakSegment()
        _ = meter.consume(fix(30.005, seconds: 2), receivedAt: start.addingTimeInterval(2))
        _ = meter.consume(fix(30.01, seconds: 30), receivedAt: start.addingTimeInterval(30))
        XCTAssertEqual(meter.meters, 0)
    }

    func testInvalidAndFutureFixesAreRejected() {
        var meter = DistanceAccumulator()
        XCTAssertFalse(meter.consume(fix(.nan), receivedAt: start))
        XCTAssertFalse(meter.consume(fix(95), receivedAt: start))
        XCTAssertFalse(meter.consume(fix(accuracy: -1), receivedAt: start))
        XCTAssertFalse(meter.consume(fix(seconds: 5), receivedAt: start))
        XCTAssertEqual(meter.meters, 0)
    }

    func testCheckpointFlushesAllBatchesAndPreservesTimestampPrecision() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RunStorage(baseURL: directory)
        var summary = RunSummary(id: UUID(), startedAt: start, endedAt: nil, activeSeconds: 0,
                                 distanceMeters: 0, gpsSampleCount: 0, heartSampleCount: 0,
                                 healthStatus: "采集中", healthWorkoutID: nil)
        try storage.begin(summary)
        for index in 0..<25 {
            let timestamp = start.addingTimeInterval(Double(index) + 0.125)
            try storage.append(RunSample(kind: "gps", timestamp: timestamp, receivedAt: timestamp,
                                         fix: fix(seconds: Double(index) + 0.125), heartRate: nil,
                                         acceptedForDistance: true))
        }
        summary.gpsSampleCount = 25
        summary.endedAt = start.addingTimeInterval(25)
        try storage.checkpoint(summary)
        let path = directory.appendingPathComponent(summary.id.uuidString).appendingPathComponent("samples.ndjson")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 25)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let first = try decoder.decode(RunSample.self, from: Data(lines[0].utf8))
        XCTAssertEqual(first.timestamp.timeIntervalSince(start), 0.125, accuracy: 0.0001)
        XCTAssertEqual(storage.latestSummary()?.gpsSampleCount, 25)
        XCTAssertEqual(storage.latestSummary()?.endedAt, summary.endedAt)
    }
    func testLegacySummaryAndSampleDecodeWithMissingNewFields() throws {
        let id = UUID().uuidString
        let data = Data("""
        {"id":"\(id)","startedAt":0,"activeSeconds":60,"distanceMeters":200,"gpsSampleCount":2,"heartSampleCount":0,"healthStatus":"saved"}
        """.utf8)
        let summary = try JSONDecoder().decode(RunSummary.self, from: data)
        XCTAssertNil(summary.activity)
        XCTAssertNil(summary.metrics)
        XCTAssertEqual(summary.averagePace!, 300, accuracy: 0.001)
        let sample = try JSONDecoder().decode(RunSample.self, from: Data("""
        {"kind":"pause","timestamp":0,"receivedAt":0}
        """.utf8))
        XCTAssertNil(sample.altitudeMeters)
    }

    func testElevationDeadbandAndDescent() {
        var elevation = ElevationAccumulator()
        for (index, altitude) in [100.0, 101, 99, 102, 104, 105, 100].enumerated() {
            elevation.consume(altitude: altitude, accuracy: 5, timestamp: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(elevation.ascent, 4)
        XCTAssertEqual(elevation.descent, 4)
    }

    func testElevationDoesNotBridgePausePoorAccuracyOrGPSGap() {
        var elevation = ElevationAccumulator()
        elevation.consume(altitude: 100, accuracy: 5, timestamp: start)
        elevation.breakSegment()
        elevation.consume(altitude: 200, accuracy: 5, timestamp: start.addingTimeInterval(1))
        elevation.consume(altitude: 220, accuracy: 50, timestamp: start.addingTimeInterval(2))
        XCTAssertNil(elevation.current)
        elevation.consume(altitude: 300, accuracy: 5, timestamp: start.addingTimeInterval(3))
        elevation.consume(altitude: 400, accuracy: 5, timestamp: start.addingTimeInterval(30))
        XCTAssertEqual(elevation.ascent, 0)
        XCTAssertEqual(elevation.descent, 0)
    }

    func testElevationRejectsSpikeAndOutOfOrderSamples() {
        var elevation = ElevationAccumulator()
        elevation.consume(altitude: 100, accuracy: 5, timestamp: start)
        elevation.consume(altitude: 1000, accuracy: 5, timestamp: start.addingTimeInterval(1))
        XCTAssertNil(elevation.current)
        elevation.consume(altitude: 104, accuracy: 5, timestamp: start.addingTimeInterval(2))
        elevation.consume(altitude: 115, accuracy: 5, timestamp: start.addingTimeInterval(1))
        XCTAssertEqual(elevation.ascent, 4)
    }

    func testRecentPaceUsesWindowAndExpires() {
        var pace = RecentPace()
        pace.consume(timestamp: start, meters: 0)
        pace.consume(timestamp: start.addingTimeInterval(5), meters: 20)
        XCTAssertEqual(pace.secondsPerKilometer(at: start.addingTimeInterval(5))!, 250, accuracy: 0.001)
        XCTAssertNil(pace.secondsPerKilometer(at: start.addingTimeInterval(16)))
        pace.breakSegment()
        pace.consume(timestamp: start.addingTimeInterval(20), meters: 500)
        XCTAssertNil(pace.secondsPerKilometer(at: start.addingTimeInterval(20)))
    }

    func testRecentPaceDoesNotBridgeGapOrInventStationaryPace() {
        var pace = RecentPace()
        pace.consume(timestamp: start, meters: 0)
        pace.consume(timestamp: start.addingTimeInterval(5), meters: 0)
        XCTAssertNil(pace.secondsPerKilometer(at: start.addingTimeInterval(5)))
        pace.consume(timestamp: start.addingTimeInterval(30), meters: 100)
        XCTAssertNil(pace.secondsPerKilometer(at: start.addingTimeInterval(30)))
    }

    func testHeartRateMeanIgnoresInvalidValuesAndMissingPaceStaysMissing() {
        var metrics = WorkoutMetrics()
        for value in [120.0, .nan, -1, 160] { metrics.recordHeartRate(value) }
        XCTAssertEqual(metrics.averageHeartRate, 140)
        XCTAssertEqual(metrics.maximumHeartRate, 160)
        let lap = WorkoutLap(number: 1, endedAt: start, activeSeconds: 60, distanceMeters: 0, isPartial: false)
        XCTAssertNil(lap.pace)
    }

    func testNewWorkoutMetadataAndRawElevationSurviveCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = RunStorage(baseURL: directory)
        var summary = RunSummary(id: UUID(), startedAt: start, endedAt: nil, activeSeconds: 60,
                                 distanceMeters: 200, gpsSampleCount: 1, heartSampleCount: 1,
                                 healthStatus: "采集中", healthWorkoutID: nil)
        summary.activity = .trailRunning
        var metrics = WorkoutMetrics()
        metrics.recordHeartRate(140)
        metrics.activeEnergyKilocalories = 50
        summary.metrics = metrics
        summary.laps = [WorkoutLap(number: 1, endedAt: start, activeSeconds: 60,
                                  distanceMeters: 200, isPartial: true)]
        try storage.begin(summary)
        try storage.append(RunSample(kind: "gps", timestamp: start, receivedAt: start, fix: fix(),
                                     heartRate: nil, acceptedForDistance: true, altitudeMeters: 123,
                                     verticalAccuracy: 5))
        try storage.append(RunSample(kind: "pause", timestamp: start, receivedAt: start, fix: nil,
                                     heartRate: nil, acceptedForDistance: nil))
        try storage.checkpoint(summary)
        let saved = try XCTUnwrap(storage.latestSummary())
        XCTAssertEqual(saved.activity, .trailRunning)
        XCTAssertEqual(saved.metrics?.averageHeartRate, 140)
        XCTAssertEqual(saved.metrics?.activeEnergyKilocalories, 50)
        XCTAssertEqual(saved.laps, summary.laps)
        let path = directory.appendingPathComponent(summary.id.uuidString).appendingPathComponent("samples.ndjson")
        let lines = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let sample = try decoder.decode(RunSample.self, from: Data(lines[0].utf8))
        XCTAssertEqual(sample.altitudeMeters, 123)
        XCTAssertEqual(sample.verticalAccuracy, 5)
        XCTAssertEqual(try decoder.decode(RunSample.self, from: Data(lines[1].utf8)).kind, "pause")
    }

}
