import XCTest
import zlib
@testable import RunnersPhoneCore

final class VectorMapTests: XCTestCase {
    private let tile = MapTileID(z: 13, x: 6826, y: 3380)
    private func uint(_ n: UInt64) -> Data {
        var n = n, bytes = Data()
        repeat { let byte = UInt8(n & 127); n >>= 7; bytes.append(n == 0 ? byte : byte | 128) } while n > 0
        return bytes
    }
    private func number(_ field: Int, _ n: UInt64) -> Data { uint(UInt64(field << 3)) + uint(n) }
    private func bytes(_ field: Int, _ data: Data) -> Data { uint(UInt64(field << 3 | 2)) + uint(UInt64(data.count)) + data }
    private func string(_ field: Int, _ text: String) -> Data { bytes(field, Data(text.utf8)) }
    private func packed(_ numbers: [UInt64]) -> Data { numbers.reduce(Data()) { $0 + uint($1) } }
    private func fixture(layer: String = "path", polygon: Bool = false) -> Data {
        let line: [UInt64] = [9, 2000, 2000, 18, 2000, 0, 0, 2000]
        // Clockwise outer ring, followed by a counter-clockwise hole in screen coordinates.
        let rings: [UInt64] = [9, 0, 0, 26, 2000, 0, 0, 2000, 1999, 0, 15,
                               9, 400, 1599, 26, 0, 1200, 1200, 0, 0, 1199, 15]
        let feature = bytes(2, packed([0, 0, 1, 1])) + number(3, polygon ? 3 : 2) + bytes(4, packed(polygon ? rings : line))
        let data = string(1, layer) + bytes(2, feature) + string(3, "highway") + string(3, "name")
            + bytes(4, string(1, "path")) + bytes(4, string(1, "测试步道")) + number(5, 4096) + number(15, 2)
        return bytes(3, data)
    }

    func testMVTLineCoordinatesAndAttributes() throws {
        let features = try VectorTileDecoder.decode(fixture(), tile: tile)
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].kind, "path")
        XCTAssertEqual(features[0].name, "测试步道")
        XCTAssertEqual(features[0].points.count, 3)
        XCTAssertEqual(features[0].points[0], tile.coordinate(x: 1000, y: 1000, extent: 4096))
        XCTAssertGreaterThan(features[0].points[1].longitude, features[0].points[0].longitude)
        XCTAssertLessThan(features[0].points[2].latitude, features[0].points[1].latitude)
    }

    func testPolygonHoleIsRetainedInsteadOfFilledAsSeparateLake() throws {
        let features = try VectorTileDecoder.decode(fixture(layer: "water", polygon: true), tile: tile)
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].points.count, 5)
        XCTAssertEqual(features[0].holes?.first?.count, 5)
    }

    func testMalformedProtobufAndGzipRejected() {
        for data in [Data([0]), Data([26, 255]), Data([0xff, 0xff, 0xff]), Data([0x1f, 0x8b, 0])] {
            XCTAssertThrowsError(try VectorTileDecoder.decode(data, tile: tile))
        }
        XCTAssertThrowsError(try VectorTileDecoder.decode(Data(repeating: 0, count: 4 * 1024 * 1024 + 1), tile: tile))
    }

    func testGzipWrappedMVTMatchesUncompressedFeatures() throws {
        let input = fixture()
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                    ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 4096)
        let status = input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            return output.withUnsafeMutableBytes { buffer in
                stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress!; stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        let compressed = Data(output.prefix(output.count - Int(stream.avail_out)))
        XCTAssertEqual(try VectorTileDecoder.decode(compressed, tile: tile).first?.points,
                       try VectorTileDecoder.decode(input, tile: tile).first?.points)
    }

    func testOSMRequestUsesExactSelectionAndRejectsUnsafeEndpoint() throws {
        let route = PlannedRoute(name: "本地测试", sourceName: "test", segments: [[
            tile.coordinate(x: 1800, y: 1800, extent: 4096), tile.coordinate(x: 2200, y: 2200, extent: 4096)
        ]])
        let bounds = try MapBounds.around(route)
        let tiles = try MapTileID.covering(bounds, zoom: 13)
        XCTAssertTrue(tiles.contains(tile))
        XCTAssertEqual(tiles.count, Set(tiles).count)
        XCTAssertThrowsError(try MapTileID.covering(bounds, zoom: 22))
        XCTAssertThrowsError(try MapDownloader.request(bounds: bounds, endpoint: URL(string: "http://example.invalid/api")!))
        XCTAssertThrowsError(try MapDownloader.request(bounds: bounds, endpoint: URL(string: "https://example.invalid/api?apikey=secret")!))
        let (request, requestedBounds) = try MapDownloader.request(bounds: bounds, endpoint: URL(string: "https://example.invalid/api")!)
        XCTAssertEqual(requestedBounds, bounds)
        XCTAssertEqual(request.httpMethod, "POST")
        let query = String(data: request.httpBody!, encoding: .utf8)!.removingPercentEncoding!
        XCTAssertTrue(query.contains(bounds.queryCoordinates))
        XCTAssertTrue(query.contains("way[highway]"))

    }

    func testJobCatalogAndCorruptTileCachePreserveRestartState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MapJobStorage(directory: directory)
        let route = PlannedRoute(name: "测试", sourceName: "test", segments: [[
            tile.coordinate(x: 1800, y: 1800, extent: 4096), tile.coordinate(x: 2200, y: 2200, extent: 4096)
        ]])
        var job = try MapDownloadJob(route: route, bounds: MapBounds.around(route), zoom: 13)
        job.phase = .paused; job.completedTiles = 1
        try storage.save([job])
        XCTAssertEqual(try storage.load().first?.phase, .paused)
        let raw = fixture()
        try storage.saveTile(raw, job: job.id, tile: tile)
        XCTAssertEqual(try storage.cachedTile(job.id, tile), raw)
        try Data("corrupt".utf8).write(to: storage.tileURL(job.id, tile))
        XCTAssertNil(try storage.cachedTile(job.id, tile))
        try storage.removeTiles(job.id)
        XCTAssertEqual(try storage.load().first?.id, job.id)
    }

    func testInvalidSelectionRejectedBeforeCoordinateRangeChecks() {
        let route = PlannedRoute(name: "test", sourceName: "test", segments: [[
            RoutePoint(latitude: 30, longitude: 120), RoutePoint(latitude: 30.001, longitude: 120)
        ]])
        let invalid = MapBounds(south: 40, west: 120, north: 30, east: 121)
        XCTAssertThrowsError(try MapDownloadJob(route: route, bounds: invalid, zoom: 13))
        let empty = PlannedRoute(name: "empty", sourceName: "test", segments: [])
        XCTAssertThrowsError(try MapDownloadJob(route: empty, bounds: MapBounds(south: 30, west: 120, north: 30.01, east: 120.01), zoom: 13))
    }

    func testPausedOSMDownloadReusesValidatedRegionWithoutCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MapJobStorage(directory: directory)
        let route = PlannedRoute(name: "真实下载协议的本地替身", sourceName: "fixture", segments: [[
            tile.coordinate(x: 100, y: 1800, extent: 4096), tile.coordinate(x: 4000, y: 2200, extent: 4096)
        ]])
        let job = try MapDownloadJob(route: route, bounds: MapBounds.around(route), zoom: 13)
        let raw = Data("""
        {"elements":[{"type":"way","id":1,"tags":{"highway":"path"},"geometry":[{"lat":30,"lon":120},{"lat":30.001,"lon":120.001}]}]}
        """.utf8)
        let endpoint = URL(string: "https://example.invalid/osm")!
        var fetched = 0
        let downloader = OSMRegionDownloader(fetch: { request, _ in
            fetched += 1
            XCTAssertEqual(request.url, endpoint)
            return raw
        })
        do {
            _ = try await downloader.download(job: job, endpoint: endpoint, storage: storage) { _, _, _ in throw CancellationError() }
            XCTFail("Expected pause")
        } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        let bundle = try await downloader.download(job: job, endpoint: endpoint, storage: storage) { _, _, _ in }
        XCTAssertTrue(bundle.isValid)
        XCTAssertEqual(fetched, 1)
        XCTAssertEqual(bundle.map.provider, "osm")
        XCTAssertEqual(bundle.map.bounds, job.bounds)
        XCTAssertEqual(bundle.schemaVersion, 1)
        var oldSchema = bundle; oldSchema.schemaVersion = 2
        XCTAssertFalse(oldSchema.isValid)

    }

    func testIncompleteOSMResponseIsNotCachedOrPublished() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = MapJobStorage(directory: folder)
        let route = PlannedRoute(name: "测试", sourceName: "test", segments: [[
            RoutePoint(latitude: 30, longitude: 120), RoutePoint(latitude: 30.001, longitude: 120.001)
        ]])
        let job = try MapDownloadJob(route: route, bounds: MapBounds.around(route), zoom: 13)
        let endpoint = URL(string: "https://example.invalid/api")!
        let downloader = OSMRegionDownloader(fetch: { _, _ in
            Data("{\"elements\":[],\"remark\":\"runtime timeout\"}".utf8)
        })
        do {
            _ = try await downloader.download(job: job, endpoint: endpoint, storage: storage) { _, _, _ in
                XCTFail("Incomplete response must not advance progress")
            }
            XCTFail("Incomplete response accepted")
        } catch { }
        XCTAssertNil(try storage.cachedTile(job.id, OSMRegionDownloader.regionKey, source: endpoint.absoluteString))
    }

    func testLongCorridorResumesAndRejectsGapsBetweenRegions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MapJobStorage(directory: directory)
        let segment = [RoutePoint(latitude: 30, longitude: 120), RoutePoint(latitude: 30.18, longitude: 120.18)]
        let route = PlannedRoute(name: "Long route", sourceName: "fixture", segments: [segment])
        XCTAssertThrowsError(try MapBounds.around(route))
        let regions = try MapBounds.corridor(for: route, bufferMeters: 500)
        let first = try XCTUnwrap(regions.first)
        let last = try XCTUnwrap(regions.last)
        let bounds = regions.dropFirst().reduce(first) { $0.union($1) }
        XCTAssertTrue(MapBounds.covers(segment, with: regions))
        XCTAssertFalse(MapBounds.covers(segment, with: [first, last]))
        let job = try MapDownloadJob(route: route, bounds: bounds, zoom: 13, coverageRegions: regions)
        let endpoint = URL(string: "https://example.invalid/osm")!
        var fetched = 0
        let downloader = OSMRegionDownloader(fetch: { _, _ in
            fetched += 1
            return Data("""
            {"elements":[{"type":"way","id":1,"tags":{"highway":"path"},"geometry":[{"lat":30,"lon":120},{"lat":30.001,"lon":120.001}]}]}
            """.utf8)
        })
        do {
            _ = try await downloader.download(job: job, endpoint: endpoint, storage: storage) { _, _, _ in
                throw CancellationError()
            }
            XCTFail("Expected pause")
        } catch is CancellationError {}
        let bundle = try await downloader.download(job: job, endpoint: endpoint, storage: storage) { _, _, _ in }
        let decoded = try MapBundleStorage.decode(MapBundleStorage.encode(bundle))
        XCTAssertEqual(fetched, regions.count)
        XCTAssertEqual(decoded.schemaVersion, 3)
        XCTAssertEqual(decoded.map.features.count, 1)
        XCTAssertFalse(decoded.map.covers(RoutePoint(latitude: 30.001, longitude: 120.175)))
    }

    func testRemovalQueueSurvivesRestartWithoutLosingCommandIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("queue.json")
        let command = MapRemovalCommand(mapID: UUID(), expectedChecksum: "expected-version")
        let queue = MapRemovalQueue(pending: [command], results: [])
        try queue.save(to: url)
        let restored = try MapRemovalQueue.load(from: url)
        XCTAssertEqual(restored.pending.first?.id, command.id)
        XCTAssertEqual(restored.pending.first?.expectedChecksum, "expected-version")
    }
}
