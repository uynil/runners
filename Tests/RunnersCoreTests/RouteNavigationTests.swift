import XCTest
@testable import RunnersCore

final class RouteNavigationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private func point(_ north: Double, _ east: Double = 0) -> RouteCoordinate {
        RouteCoordinate(latitude: 30 + north / 111_194.9266, longitude: 120 + east / 96_297.6312)
    }
    private func fix(_ p: RouteCoordinate, at seconds: Double, accuracy: Double = 5) -> GPSFix {
        GPSFix(timestamp: start.addingTimeInterval(seconds), latitude: p.latitude, longitude: p.longitude, accuracy: accuracy)
    }
    private func route(_ segments: [[RouteCoordinate]]) throws -> NavigationRoute {
        try NavigationRoute(name: "测试", segments: segments)
    }

    func testProgressAndRemainingDistanceOnRoute() throws {
        let r = try route([[point(0), point(1000)]])
        var nav = RouteNavigator(route: r)
        _ = nav.consume(fix(point(0), at: 0), receivedAt: start)
        let result = nav.consume(fix(point(90), at: 30), receivedAt: start.addingTimeInterval(30))
        XCTAssertEqual(result.status, .onRoute)
        XCTAssertEqual(result.progressMeters!, 90, accuracy: 0.1)
        XCTAssertEqual(result.remainingMeters!, 910, accuracy: 0.1)
    }

    func testClosedLoopStartsAtBeginningAndDoesNotJumpToCrossingBranch() throws {
        let r = try route([[point(0), point(100), point(100, 100), point(0, 100), point(0)]])
        var nav = RouteNavigator(route: r)
        let result = nav.consume(fix(point(0), at: 0), receivedAt: start)
        XCTAssertEqual(result.progressMeters!, 0, accuracy: 0.01)
        let next = nav.consume(fix(point(10), at: 4), receivedAt: start.addingTimeInterval(4))
        XCTAssertLessThan(next.progressMeters!, 20)
    }

    func testSegmentGapIsNotRenderedOrMeasuredAsConnectingEdge() throws {
        let r = try route([[point(0), point(10)], [point(1000), point(1010)]])
        XCTAssertEqual(r.distanceMeters, 20, accuracy: 0.1)
        XCTAssertEqual(r.renderSegments.count, 2)
        var nav = RouteNavigator(route: r)
        let result = nav.consume(fix(point(500), at: 0), receivedAt: start)
        XCTAssertGreaterThan(result.distanceToRoute!, 400)
    }

    func testDeviationRequiresSustainedTrustedSamplesAndClearsOnReturn() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(1000)]]))
        _ = nav.consume(fix(point(10), at: 0), receivedAt: start)
        let first = nav.consume(fix(point(10, 70), at: 10), receivedAt: start.addingTimeInterval(10))
        XCTAssertEqual(first.status, .checkingDeviation)
        let alert = nav.consume(fix(point(10, 70), at: 15), receivedAt: start.addingTimeInterval(15))
        XCTAssertEqual(alert.status, .offRoute)
        XCTAssertTrue(alert.shouldAlert)
        let repeated = nav.consume(fix(point(10, 70), at: 16), receivedAt: start.addingTimeInterval(16))
        XCTAssertFalse(repeated.shouldAlert)
        let returned = nav.consume(fix(point(15, 10), at: 25), receivedAt: start.addingTimeInterval(25))
        XCTAssertEqual(returned.status, .onRoute)
    }

    func testPoorStaleAndOutOfOrderLocationsCannotAdvanceOrTriggerDeviation() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(1000)]]))
        _ = nav.consume(fix(point(0), at: 0), receivedAt: start)
        for (sample, now) in [(fix(point(400), at: 1, accuracy: 80), 1.0),
                              (fix(point(400), at: 2), 20.0), (fix(point(0), at: -1), 0.0)] {
            let result = nav.consume(sample, receivedAt: start.addingTimeInterval(now))
            XCTAssertEqual(result.status, .uncertain)
            XCTAssertNil(result.progressMeters)
            XCTAssertFalse(result.shouldAlert)
        }
        let recovered = nav.consume(fix(point(10), at: 21), receivedAt: start.addingTimeInterval(21))
        XCTAssertEqual(recovered.progressMeters!, 10, accuracy: 0.1)
    }

    func testRenderSimplificationKeepsSharpCornerAndRejectsBadRoute() throws {
        let r = try route([[point(0), point(10), point(20), point(30), point(30, 30)]])
        XCTAssertEqual(r.renderSegments[0].count, 3)
        XCTAssertThrowsError(try route([[point(0)]]))
        XCTAssertThrowsError(try route([[point(0), RouteCoordinate(latitude: 91, longitude: 120)]]))
        XCTAssertThrowsError(try NavigationRoute.decode(Data("{\"name\":\"bad\",\"segments\":[]}".utf8)))
    }

    func testImplausibleJumpDoesNotAdvanceProgressOrTriggerOffRoute() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(1000)]]))
        _ = nav.consume(fix(point(0), at: 0), receivedAt: start)
        let jump = nav.consume(fix(point(500), at: 1), receivedAt: start.addingTimeInterval(1))
        XCTAssertEqual(jump.status, .uncertain)
        XCTAssertNil(jump.progressMeters)
        let recovered = nav.consume(fix(point(6), at: 2), receivedAt: start.addingTimeInterval(2))
        XCTAssertEqual(recovered.progressMeters!, 6, accuracy: 0.1)
    }

    func testPhoneRouteIdentityIsPreservedForOfflineMapSelectionAndLegacyRoutesStillLoad() throws {
        let id = UUID()
        let payload: [String: Any] = ["id": id.uuidString, "name": "同名线路", "sourceName": "route.gpx",
                                      "segments": [[ ["latitude": 30.0, "longitude": 120.0],
                                                      ["latitude": 30.001, "longitude": 120.0] ]]]
        let decoded = try NavigationRoute.decode(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(decoded.id, id)
        var legacy = payload
        legacy.removeValue(forKey: "id")
        XCTAssertNil(try NavigationRoute.decode(JSONSerialization.data(withJSONObject: legacy)).id)
    }

    func testReverseTravelKeepsProgressOnSameBranch() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(1000)]]))
        _ = nav.consume(fix(point(200), at: 0), receivedAt: start)
        _ = nav.consume(fix(point(180), at: 5), receivedAt: start.addingTimeInterval(5))
        let result = nav.consume(fix(point(160), at: 10), receivedAt: start.addingTimeInterval(10))
        XCTAssertEqual(result.status, .onRoute)
        XCTAssertTrue(result.isReverse)
        XCTAssertEqual(result.progressMeters!, 160, accuracy: 0.1)
    }

    func testParallelLegWithoutHeadingIsUncertainThenResolvesByMovement() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(1000), point(1000,10), point(0,10)]]))
        XCTAssertEqual(nav.consume(fix(point(500,5), at: 0), receivedAt: start).status, .uncertain)
        let result = nav.consume(fix(point(510,5), at: 2), receivedAt: start.addingTimeInterval(2))
        XCTAssertEqual(result.status, .onRoute)
        XCTAssertEqual(result.progressMeters!, 510, accuracy: 0.2)
    }

    func testLongLossRequiresMultipleConsistentLocationsBeforeGlobalReacquisition() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(3000)]]))
        _ = nav.consume(fix(point(0), at: 0), receivedAt: start)
        XCTAssertEqual(nav.consume(fix(point(1800), at: 200), receivedAt: start.addingTimeInterval(200)).status, .uncertain)
        XCTAssertEqual(nav.consume(fix(point(1806), at: 202), receivedAt: start.addingTimeInterval(202)).status, .uncertain)
        let recovered = nav.consume(fix(point(1812), at: 204), receivedAt: start.addingTimeInterval(204))
        XCTAssertEqual(recovered.status, .onRoute)
        XCTAssertEqual(recovered.progressMeters!, 1812, accuracy: 0.2)
    }

    func testLongSampleGapCannotCountAsContinuousDeviationAndBearingIsStraightLine() throws {
        var nav = RouteNavigator(route: try route([[point(0), point(1000)]]))
        _ = nav.consume(fix(point(10), at: 0), receivedAt: start)
        _ = nav.consume(fix(point(10,70), at: 10), receivedAt: start.addingTimeInterval(10))
        XCTAssertFalse(nav.consume(fix(point(10,70), at: 25), receivedAt: start.addingTimeInterval(25)).shouldAlert)
        let off = nav.consume(fix(point(10,70), at: 30), receivedAt: start.addingTimeInterval(30))
        XCTAssertTrue(off.shouldAlert)
        XCTAssertEqual(off.bearingToRoute!, 270, accuracy: 1)
    }

    func testUnconfirmedReverseAndUncertainCuesNeverAlertAndConfirmedCueAlertsOnce() {
        let cue = NavigationCue(id: "first-pass", progressMeters: 100, coordinate: point(100), turn: "left", name: "路口", confirmed: true)
        var trigger = NavigationCueTrigger()
        func result(_ progress: Double, status: NavigationStatus = .onRoute, reverse: Bool = false) -> NavigationResult {
            NavigationResult(status: status, timestamp: start, progressMeters: progress, remainingMeters: 1000-progress,
                             distanceToRoute: 0, shouldAlert: false, isReverse: reverse)
        }
        XCTAssertNil(trigger.consume(result(50, status: .uncertain), cues: [cue]))
        XCTAssertNil(trigger.consume(result(50, reverse: true), cues: [cue]))
        XCTAssertFalse(trigger.consume(result(50), cues: [cue])!.shouldAlert)
        XCTAssertTrue(trigger.consume(result(55), cues: [cue])!.shouldAlert)
        XCTAssertFalse(trigger.consume(result(60), cues: [cue])!.shouldAlert)
        XCTAssertNil(trigger.consume(result(105), cues: [cue]))
    }
}
