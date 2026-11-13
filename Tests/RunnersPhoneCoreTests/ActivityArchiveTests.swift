import XCTest
@testable import RunnersPhoneCore

final class ActivityArchiveTests: XCTestCase {
    private func archive(ended: Bool = true) -> ActivityArchive {
        let summary = """
        {"id":"C0000000-0000-4000-8000-000000000059","startedAt":1700000000,\(ended ? "\"endedAt\":1700000060," : "")"activeSeconds":40,"distanceMeters":100,"gpsSampleCount":4,"heartSampleCount":0,"healthStatus":"测试记录：未写入 Health"}
        """
        let lines = [
            "{\"kind\":\"gps\",\"timestamp\":1700000000,\"acceptedForDistance\":true,\"fix\":{\"latitude\":30,\"longitude\":120,\"accuracy\":5}}",
            "{\"kind\":\"gps\",\"timestamp\":1700000005,\"acceptedForDistance\":true,\"fix\":{\"latitude\":30.001,\"longitude\":120,\"accuracy\":5}}",
            "{\"kind\":\"pause\",\"timestamp\":1700000010}",
            "{\"kind\":\"gps\",\"timestamp\":1700000030,\"acceptedForDistance\":true,\"fix\":{\"latitude\":30.002,\"longitude\":120,\"accuracy\":5}}",
            "{\"kind\":\"gps\",\"timestamp\":1700000035,\"acceptedForDistance\":true,\"fix\":{\"latitude\":30.003,\"longitude\":120,\"accuracy\":5}}"
        ]
        return ActivityArchive(summaryData: Data(summary.utf8), samplesData: Data(lines.joined(separator: "\n").utf8))
    }
    func testCompletedArchiveRetainsActualTrackAndPauseSegments() throws {
        let decoded = try ActivityStorage.decode(ActivityStorage.encode(archive()))
        XCTAssertEqual(try decoded.summary.distanceMeters, 100)
        XCTAssertEqual(try decoded.track().map(\.count), [2, 2])
        XCTAssertTrue(try decoded.samples().compactMap(\.heartRate).isEmpty)
        XCTAssertThrowsError(try ActivityStorage.encode(archive(ended: false)))
    }
    func testRecoveryGapBreaksEvenAQuickRestartInHistoryAndExport() throws {
        let base = archive()
        let samples = String(decoding: base.samplesData, as: UTF8.self)
            .replacingOccurrences(of: "\"pause\"", with: "\"recoveryGap\"")
            .replacingOccurrences(of: "1700000030", with: "1700000011")
            .replacingOccurrences(of: "1700000035", with: "1700000016")
            .replacingOccurrences(of: "30.001", with: "30.0001")
            .replacingOccurrences(of: "30.002", with: "30.0002")
            .replacingOccurrences(of: "30.003", with: "30.0003")
        let recovered = ActivityArchive(summaryData: base.summaryData, samplesData: Data(samples.utf8))
        XCTAssertEqual(try recovered.track().map(\.count), [2,2])
        let tcx = String(decoding: try ActivityTCX.data(recovered), as: UTF8.self)
        XCTAssertEqual(tcx.components(separatedBy: "<Track>").count - 1, 2)
        XCTAssertEqual(tcx.components(separatedBy: "<Position>").count - 1, 4)
    }
    func testDuplicateReceiptAndCorruptReplacementPreserveHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = ActivityStorage(directory: folder), data = try ActivityStorage.encode(archive())
        try storage.save(data); try storage.save(data)
        XCTAssertEqual(try storage.all().count, 1)
        XCTAssertEqual(try storage.all().first?.1.checksum, MapBundleStorage.digest(data))
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try storage.save(JSONSerialization.data(withJSONObject: envelope)))
        XCTAssertEqual(try Data(contentsOf: storage.fileURL(archive().summary.id)), data)
    }
}
