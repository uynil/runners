import XCTest
@testable import RunnersPhoneCore

final class RouteLibraryTests: XCTestCase {
    func testReverseDirectionPreservesGapsAndReversesConfirmedTurns() throws {
        var route = try XCTUnwrap(parse("""
        <gpx><trk><trkseg><trkpt lat="30" lon="120"/><trkpt lat="30.001" lon="120"/></trkseg>
        <trkseg><trkpt lat="31" lon="120"/><trkpt lat="31.001" lon="120"/></trkseg></trk></gpx>
        """).first)
        let original = route
        route.cues = [RouteCue(id: "turn", progressMeters: 50, coordinate: route.segments[0][0],
                              turn: "left", name: "junction", confirmed: true)]
        route.reverseDirection()
        XCTAssertEqual(route.id, original.id)
        XCTAssertEqual(route.segments, original.segments.reversed().map { Array($0.reversed()) })
        XCTAssertEqual(route.distanceMeters, original.distanceMeters, accuracy: 0.001)
        let cue = try XCTUnwrap(route.cues?.first)
        XCTAssertEqual(cue.progressMeters, original.distanceMeters - 50, accuracy: 0.001)
        XCTAssertEqual(cue.turn, "right")
        XCTAssertTrue(cue.confirmed)
        XCTAssertNotNil(route.cuesUpdatedAt)
        route.reverseDirection()
        XCTAssertEqual(route.segments, original.segments)
        XCTAssertEqual(route.isReversed, false)
    }

    private func parse(_ xml: String) throws -> [PlannedRoute] {
        try RouteImporter.read(Data(xml.utf8), sourceName: "example.gpx")
    }

    func testGPXSegmentsAndMultipleRoutesRemainIndependent() throws {
        let routes = try parse("""
        <gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><name>环线</name>
        <trkseg><trkpt lat="30" lon="120"/><trkpt lat="30.0001" lon="120"/></trkseg>
        <trkseg><trkpt lat="31" lon="120"/><trkpt lat="31.0001" lon="120"/></trkseg></trk>
        <rte><name>另一条</name><rtept lat="32" lon="120"/><rtept lat="32.0001" lon="120"/></rte></gpx>
        """)
        XCTAssertEqual(routes.map(\.name), ["环线", "另一条"])
        XCTAssertEqual(routes[0].segments.count, 2)
        XCTAssertEqual(routes[0].distanceMeters, 22.239, accuracy: 0.02)
        XCTAssertEqual(routes[1].distanceMeters, 11.1195, accuracy: 0.02)
    }

    func testNamespacedKMLMultigeometryRetainsGaps() throws {
        let routes = try parse("""
        <kml:kml xmlns:kml="http://www.opengis.net/kml/2.2"><kml:Document><kml:Placemark><kml:name>山路</kml:name>
        <kml:MultiGeometry><kml:LineString><kml:coordinates><![CDATA[120,30,8 120,30.0001,9]]></kml:coordinates></kml:LineString>
        <kml:LineString><kml:coordinates>120,31 120,31.0001</kml:coordinates></kml:LineString></kml:MultiGeometry>
        </kml:Placemark></kml:Document></kml:kml>
        """)
        XCTAssertEqual(routes[0].name, "山路")
        XCTAssertEqual(routes[0].segments.count, 2)
        XCTAssertEqual(routes[0].distanceMeters, 22.239, accuracy: 0.02)
    }

    func testInvalidCoordinatesMalformedXMLAndEmptyDataFailWithoutPartialImport() {
        for xml in ["<gpx/>", "<gpx><trk>",
                    "<gpx><rte><rtept lat='nan' lon='120'/><rtept lat='30' lon='120'/></rte></gpx>",
                    "<gpx><rte><rtept lat='91' lon='120'/><rtept lat='30' lon='120'/></rte></gpx>",
                    "<gpx><rte><rtept lat='30' lon='120'/></rte></gpx>",
                    "<kml><Placemark><LineString><coordinates>120,30 broken</coordinates></LineString></Placemark></kml>"] {
            XCTAssertThrowsError(try parse(xml), xml)
        }
    }

    func testDuplicatePointsRemovedButSegmentWithNoMovementRejected() throws {
        let routes = try parse("<gpx><rte><rtept lat='30' lon='120'/><rtept lat='30' lon='120'/><rtept lat='30.001' lon='120'/></rte></gpx>")
        XCTAssertEqual(routes[0].pointCount, 2)
        XCTAssertThrowsError(try parse("<gpx><rte><rtept lat='30' lon='120'/><rtept lat='30' lon='120'/></rte></gpx>"))
    }

    func testEntityDeclarationsRejected() {
        XCTAssertThrowsError(try parse("<!DOCTYPE gpx [<!ENTITY x 'expanded'>]><gpx><rte><name>&x;</name><rtept lat='30' lon='120'/><rtept lat='30.1' lon='120'/></rte></gpx>"))
        XCTAssertThrowsError(try parse("<!DOCTYPE gpx [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><gpx><rte><name>&x;</name><rtept lat='30' lon='120'/><rtept lat='30.1' lon='120'/></rte></gpx>"))
        let utf16 = "<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE gpx SYSTEM 'file:///etc/passwd'><gpx/>".data(using: .utf16)!
        XCTAssertThrowsError(try RouteImporter.read(utf16, sourceName: "encoded.gpx"))
    }

    func testByteAndPointLimitsIncludingOneHundredThousandPointInput() throws {
        XCTAssertThrowsError(try RouteImporter.read(Data(repeating: 0x20, count: RouteImporter.maximumBytes + 1), sourceName: "large.gpx"))
        let point = "<rtept lat='30' lon='120'/>"
        let end = "<rtept lat='30.001' lon='120'/></rte></gpx>"
        let withinLimit = "<gpx><rte>" + String(repeating: point, count: 99_999) + end
        XCTAssertEqual(try parse(withinLimit)[0].pointCount, 2)
        XCTAssertThrowsError(try parse("<gpx><rte>" + String(repeating: point, count: 100_000) + end))
    }

    func testLibraryRoundTripAndCorruptFileDoesNotSilentlyReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = RouteLibrary(url: directory.appendingPathComponent("routes.json"))
        XCTAssertTrue(try library.load().isEmpty)
        var route = try parse("<gpx><rte><rtept lat='30' lon='120'/><rtept lat='30.001' lon='120'/></rte></gpx>")[0]
        route.name = "收藏的线路"; route.isFavorite = true
        try library.save([route])
        XCTAssertEqual(try library.load(), [route])
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: library.url)
        XCTAssertThrowsError(try library.load())
        XCTAssertEqual(try Data(contentsOf: library.url), corrupt)
    }
}
