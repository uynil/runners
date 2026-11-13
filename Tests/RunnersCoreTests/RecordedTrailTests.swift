import XCTest
@testable import RunnersCore

final class RecordedTrailTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func fix(_ index: Int, latitude: Double? = nil, accuracy: Double = 5) -> GPSFix {
        GPSFix(timestamp: start.addingTimeInterval(Double(index)),
               latitude: latitude ?? (30 + Double(index) * 0.00004), longitude: 120, accuracy: accuracy)
    }

    func testLongWorkoutKeepsBeginningAndLatestPositionBeyondOld300PointLimit() {
        var trail = RecordedTrail()
        for index in 0..<6_000 { trail.append(fix(index)) }
        XCTAssertEqual(trail.vertices.count, 6_000)
        XCTAssertEqual(trail.vertices.first?.fix, fix(0))
        XCTAssertEqual(trail.vertices.last?.fix, fix(5_999))
        XCTAssertEqual(trail.vertices.filter(\.startsSegment).count, 1)
    }

    func testStationaryFixesKeepStartAndLiveEndpointWithoutGrowingForever() {
        var trail = RecordedTrail()
        for index in 0..<3_600 { trail.append(fix(index, latitude: 30)) }
        XCTAssertEqual(trail.vertices.count, 2)
        XCTAssertEqual(trail.vertices.first?.fix, fix(0, latitude: 30))
        XCTAssertEqual(trail.vertices.last?.fix, fix(3_599, latitude: 30))
    }

    func testPausePoorFixAndLongGapStartSeparateSegments() {
        var trail = RecordedTrail()
        trail.append(fix(0)); trail.append(fix(1))
        trail.breakSegment()
        trail.append(fix(2)); trail.append(fix(3))
        trail.append(fix(4, accuracy: 100))
        trail.append(fix(5)); trail.append(fix(6))
        trail.append(fix(30)); trail.append(fix(31))
        XCTAssertEqual(trail.vertices.map(\.fix.timestamp), [0, 1, 2, 3, 5, 6, 30, 31].map { start.addingTimeInterval(Double($0)) })
        XCTAssertEqual(trail.vertices.map(\.startsSegment), [true, false, true, false, true, false, true, false])
    }

    func testOutOfOrderFixDoesNotMoveLiveEndpointBackwards() {
        var trail = RecordedTrail()
        trail.append(fix(2)); trail.append(fix(3)); trail.append(fix(1))
        trail.breakSegment()
        trail.append(fix(2))
        XCTAssertEqual(trail.vertices.count, 2)
        XCTAssertEqual(trail.vertices.last?.fix, fix(3))
    }

    func testFollowingSuccessivePositionsCentersAtEveryZoom() {
        for scale in [0.05, 0.2, 1, 16.0] {
            for position in [RouteXY(x: 0, y: 0), RouteXY(x: 1200, y: -450), RouteXY(x: -300, y: 220)] {
                let viewport = NavigationViewport(center: position, scale: scale, width: 198, height: 242, panX: 0, panY: 0)
                XCTAssertEqual(viewport.screen(position), RouteXY(x: 99, y: 121))
                XCTAssertEqual(viewport.screen(RouteXY(x: position.x + 10, y: position.y + 10)).x, 99 + 10 * scale, accuracy: 0.0001)
            }
        }
    }

    func testManualPanOffsetsAllLayersTogetherAndClearingPanRestoresCenter() {
        let position = RouteXY(x: 100, y: 200)
        let browsing = NavigationViewport(center: position, scale: 2, width: 198, height: 242, panX: 30, panY: -20)
        XCTAssertEqual(browsing.screen(position), RouteXY(x: 129, y: 101))
        let following = NavigationViewport(center: position, scale: 2, width: 198, height: 242, panX: 0, panY: 0)
        XCTAssertEqual(following.screen(position), RouteXY(x: 99, y: 121))
    }
}
