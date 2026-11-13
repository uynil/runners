import XCTest
@testable import RunnersPhoneCore

final class RoutePreparationTests: XCTestCase {
    func p(_ north: Double, _ east: Double = 0) -> RoutePoint {
        RoutePoint(latitude: 30 + north/111195, longitude: 120 + east/96297.6312)
    }
    func testRealSharedOSMNodeProducesUnconfirmedCueButGradeSeparatedCrossingDoesNot() throws {
        let route = PlannedRoute(name: "路线", sourceName: "test", segments: [[p(0),p(100),p(200)]])
        let bounds = try MapBounds.around(route)
        let main = MapFeature(id: 1, kind: "path", name: "主路", points: [p(0),p(100),p(200)], nodeIDs: [1,2,3])
        var branch = MapFeature(id: 2, kind: "path", name: "支路", points: [p(100),p(100,100)], nodeIDs: [2,4])
        var map = OfflineMap(bounds: bounds, features: [main,branch], sourceURL: "local://test", downloadedAt: Date())
        let result = RoutePreparation.analyze(route: route, map: map)
        XCTAssertEqual(result.roadCoverage,1,accuracy:0.01)
        XCTAssertEqual(result.candidates.count,1)
        XCTAssertFalse(result.candidates[0].confirmed)
        XCTAssertEqual(result.candidates[0].progressMeters,100,accuracy:1)
        branch.nodeIDs = [5,4]
        map = OfflineMap(bounds: bounds, features: [main,branch], sourceURL: "local://test", downloadedAt: Date())
        XCTAssertTrue(RoutePreparation.analyze(route: route, map: map).candidates.isEmpty)
    }
    func testMissingRoadsAreReportedAndGPXBendsAreNotInventedJunctions() throws {
        let route = PlannedRoute(name: "山路", sourceName: "test", segments: [[p(0),p(100),p(100,100)]])
        let map = OfflineMap(bounds: try MapBounds.around(route), features: [MapFeature(id: 1,kind: "waterway",name: nil,points:[p(500),p(600)])], sourceURL: "local://test", downloadedAt: Date())
        let result = RoutePreparation.analyze(route: route,map: map)
        XCTAssertEqual(result.roadCoverage,0)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(result.candidates.isEmpty)
    }
    func testMalformedNodeListsAndOutOfRouteCuesRejectMapPackage() throws {
        var route = PlannedRoute(name: "test", sourceName: "test", segments: [[p(0),p(200)]])
        let map = OfflineMap(bounds: try MapBounds.around(route), features:[MapFeature(id:1,kind:"path",name:nil,points:route.segments[0])],sourceURL:"local://test",downloadedAt:Date())
        route.cues = [RouteCue(id:"bad",progressMeters:10000,coordinate:p(100),turn:"left",name:"")]
        XCTAssertThrowsError(try MapBundleStorage.encode(RouteMapBundle(route:route,map:map)))
        let cue = RouteCue(id:"same",progressMeters:100,coordinate:p(100),turn:"left",name:"")
        route.cues = [cue,cue]
        XCTAssertThrowsError(try MapBundleStorage.encode(RouteMapBundle(route:route,map:map)))
        route.cues = nil
        let malformedMap = OfflineMap(bounds:map.bounds,
            features:[MapFeature(id:1,kind:"path",name:nil,points:route.segments[0],nodeIDs:[1])],
            sourceURL:map.sourceURL,downloadedAt:map.downloadedAt)
        XCTAssertThrowsError(try MapBundleStorage.encode(RouteMapBundle(route:route,map:malformedMap)))
    }
    func testManualCueUsesAlongRouteDistanceWithoutInterpolatingGPXGap() throws {
        let route = PlannedRoute(name:"gap",sourceName:"test",segments:[[p(0),p(100)],[p(1000),p(1100)]])
        let cue = try RouteCue.manual(route:route,progress:150,turn:"right")
        XCTAssertEqual(cue.coordinate.latitude,p(1050).latitude,accuracy:0.00001)
        XCTAssertFalse(cue.confirmed)
        XCTAssertThrowsError(try RouteCue.manual(route:route,progress:201,turn:"left"))
        XCTAssertThrowsError(try RouteCue.manual(route:route,progress:50,turn:"u-turn"))
    }
    func testDelayedPackageCannotUndoReviewedJunctions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let storage = MapBundleStorage(directory:directory)
        var route = PlannedRoute(name:"reviewed",sourceName:"test",segments:[[p(0),p(200)]])
        let map = OfflineMap(bounds:try MapBounds.around(route),features:[MapFeature(id:1,kind:"path",name:nil,points:route.segments[0])],sourceURL:"local://test",downloadedAt:Date())
        let old = RouteMapBundle(route:route,map:map)
        var cue = try RouteCue.manual(route:route,progress:100,turn:"right"); cue.confirmed = true
        route.cues = [cue]; route.cuesUpdatedAt = Date()
        try storage.save(RouteMapBundle(route:route,map:map))
        try storage.save(old)
        XCTAssertEqual(try storage.load(route.id).route.cues,[cue])
    }
}
