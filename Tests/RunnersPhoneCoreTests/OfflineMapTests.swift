import XCTest
@testable import RunnersPhoneCore

final class OfflineMapTests: XCTestCase {
    func testOneCorruptMapDoesNotHideOtherValidMaps() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapBundleStorage(directory: folder)
        let valid = try bundle()
        try storage.save(valid)
        try Data("corrupt".utf8).write(to: storage.fileURL(UUID()))
        XCTAssertEqual(try storage.all().map(\.id), [valid.id])
        XCTAssertEqual(try storage.scan().invalidCount, 1)
    }
    private func route() -> PlannedRoute {
        PlannedRoute(name: "测试线路", sourceName: "fixture.gpx", segments: [[
            RoutePoint(latitude: 30, longitude: 120), RoutePoint(latitude: 30.005, longitude: 120.005)
        ]])
    }
    private let response = Data("""
    {"elements":[
      {"type":"way","id":1,"tags":{"highway":"path","name":"测试步道"},"geometry":[{"lat":30,"lon":120},{"lat":30.005,"lon":120.005}]},
      {"type":"way","id":2,"tags":{"waterway":"stream"},"geometry":[{"lat":30.001,"lon":120},{"lat":30.006,"lon":120.004}]}
    ]}
    """.utf8)

    private func bundle() throws -> RouteMapBundle {
        let route = route()
        let map = try OfflineMap.parse(response, bounds: MapBounds.around(route), sourceURL: "https://example.invalid/api")
        return RouteMapBundle(route: route, map: map)
    }

    func testBoundsContainAllRoutePointsAndBuffer() throws {
        let route = route()
        let bounds = try MapBounds.around(route)
        XCTAssertTrue(route.segments.flatMap { $0 }.allSatisfy(bounds.contains))
        XCTAssertLessThan(bounds.south, 30)
        XCTAssertGreaterThan(bounds.east, 120.005)
        XCTAssertGreaterThan(bounds.areaSquareKilometers, 0)
    }

    func testOversizedAndAntimeridianRequestsAreRejected() {
        let long = PlannedRoute(name: "long", sourceName: "x", segments: [[
            RoutePoint(latitude: 30, longitude: 120), RoutePoint(latitude: 31, longitude: 121)
        ]])
        let crossing = PlannedRoute(name: "crossing", sourceName: "x", segments: [[
            RoutePoint(latitude: 30, longitude: 179.9), RoutePoint(latitude: 30, longitude: -179.9)
        ]])
        XCTAssertThrowsError(try MapBounds.around(long))
        XCTAssertThrowsError(try MapBounds.around(crossing))
    }

    func testOverpassParsesRoadsAndWaterAndRejectsPartialResponses() throws {
        let map = try bundle().map
        XCTAssertEqual(map.features.count, 2)
        XCTAssertEqual(map.features[0].kind, "path")
        XCTAssertEqual(map.features[0].name, "测试步道")
        XCTAssertTrue(map.features[1].isWater)
        for text in ["{\"elements\":[],\"remark\":\"timeout\"}", "{\"elements\":[]}", "broken"] {
            XCTAssertThrowsError(try OfflineMap.parse(Data(text.utf8), bounds: map.bounds, sourceURL: "test"))
        }
    }

    func testChecksumAndUnsupportedVersionRejectTamperedPackages() throws {
        let bundle = try bundle()
        let data = try MapBundleStorage.encode(bundle)
        let decoded = try MapBundleStorage.decode(data)
        XCTAssertEqual(decoded.route, bundle.route)
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        envelope["sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try MapBundleStorage.decode(JSONSerialization.data(withJSONObject: envelope)))
        var future = bundle; future.schemaVersion = 2
        XCTAssertThrowsError(try MapBundleStorage.encode(future))
    }

    func testBoundsMismatchCannotBeSavedAsReady() throws {
        let original = try bundle()
        var moved = original.route
        moved.segments[0][1] = RoutePoint(latitude: 40, longitude: 130)
        XCTAssertFalse(RouteMapBundle(route: moved, map: original.map).isValid)
        XCTAssertThrowsError(try MapBundleStorage.encode(RouteMapBundle(route: moved, map: original.map)))
    }

    func testAtomicSaveCorruptReplacementPreservesOldOfflineMapAndDelete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapBundleStorage(directory: folder), bundle = try bundle()
        try storage.save(bundle)
        let before = try Data(contentsOf: storage.fileURL(bundle.id))
        XCTAssertThrowsError(try storage.saveData(Data("corrupt".utf8)))
        XCTAssertEqual(try Data(contentsOf: storage.fileURL(bundle.id)), before)
        XCTAssertEqual(try storage.load(bundle.id).route, bundle.route)
        XCTAssertEqual(try storage.all().count, 1)
        try storage.remove(bundle.id)
        XCTAssertTrue(try storage.all().isEmpty)
    }

    func testReceivingSamePackageTwiceDoesNotDuplicateRoutes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapBundleStorage(directory: folder), bundle = try bundle()
        let data = try MapBundleStorage.encode(bundle)
        try storage.saveData(data)
        try storage.saveData(data)
        XCTAssertEqual(try storage.all().count, 1)
        XCTAssertEqual(try storage.load(bundle.id).map.features.count, 2)
    }

    func testRequestSendsOnlyBoundingBoxNotFullTrackAndRequiresHTTPS() throws {
        let route = route()
        let (request, bounds) = try MapDownloader.request(route: route, endpoint: URL(string: "https://example.invalid/api")!)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(String(data: XCTUnwrap(request.httpBody), encoding: .utf8)?.removingPercentEncoding)
        XCTAssertTrue(body.contains(bounds.queryCoordinates))
        XCTAssertFalse(body.contains(route.name))
        XCTAssertFalse(body.contains("segments"))
        XCTAssertFalse(body.contains(route.id.uuidString))
        XCTAssertThrowsError(try MapDownloader.request(route: route, endpoint: URL(string: "http://example.invalid/api")!))
    }

    func testHTTPFailureCannotBecomeSavedMap() throws {
        let endpoint = URL(string: "https://example.invalid/api")!, route = route()
        let bounds = try MapBounds.around(route)
        for status in [429, 500, 504] {
            let http = HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            XCTAssertThrowsError(try MapDownloader.bundle(data: response, response: http, route: route, bounds: bounds, endpoint: endpoint))
        }
        let http = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        XCTAssertTrue(try MapDownloader.bundle(data: response, response: http, route: route, bounds: bounds, endpoint: endpoint).isValid)
    }

    func testPackageCountLimitAllowsReplacingExistingMap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapBundleStorage(directory: folder), first = try bundle()
        try storage.save(first)
        for _ in 0..<19 {
            var nextRoute = first.route; nextRoute.id = UUID()
            try storage.save(RouteMapBundle(route: nextRoute, map: first.map))
        }
        try storage.save(first)
        XCTAssertEqual(try storage.all().count, 20)
        var extra = first.route; extra.id = UUID()
        XCTAssertThrowsError(try storage.save(RouteMapBundle(route: extra, map: first.map)))
        XCTAssertEqual(try storage.load(first.id).route, first.route)
    }

    func testDelayedOlderTransferDoesNotReplaceNewerMap() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapBundleStorage(directory: folder), first = try bundle()
        let olderMap = OfflineMap(bounds: first.map.bounds, features: first.map.features,
                                  sourceURL: first.map.sourceURL, downloadedAt: first.map.downloadedAt.addingTimeInterval(-60))
        try storage.save(first)
        try storage.save(RouteMapBundle(route: first.route, map: olderMap))
        XCTAssertEqual(try storage.load(first.id).map.downloadedAt, first.map.downloadedAt)
    }

    func testRemoteRemovalWaitsDuringWorkoutAndRejectsDifferentVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapBundleStorage(directory: folder), bundle = try bundle()
        try storage.save(bundle)
        let data = try Data(contentsOf: storage.fileURL(bundle.id))
        let command = MapRemovalCommand(mapID: bundle.id, expectedChecksum: MapBundleStorage.digest(data))
        var queue = MapRemovalQueue(pending: [command], results: [])
        try queue.apply(to: storage, activityProtected: true)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertEqual(try storage.all().count, 1)
        var conflict = MapRemovalQueue(pending: [MapRemovalCommand(mapID: bundle.id, expectedChecksum: "older-version")], results: [])
        try conflict.apply(to: storage, activityProtected: false)
        XCTAssertEqual(conflict.results.first?.removed, false)
        XCTAssertEqual(try storage.all().count, 1)
        try queue.apply(to: storage, activityProtected: false)
        XCTAssertTrue(try storage.all().isEmpty)
        XCTAssertEqual(queue.results.first?.commandID, command.id)
        XCTAssertEqual(queue.results.first?.removed, true)
    }
}
