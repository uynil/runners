import Foundation

// Local-only integration fixture and export. Does not make network requests.
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
func point(_ north: Double, _ east: Double = 0) -> RoutePoint {
    RoutePoint(latitude: 30 + north / 111195, longitude: 120 + east / 96297.6312)
}
let route = PlannedRoute(id: UUID(uuidString: "A0000000-0000-4000-8000-000000000060")!, name: "路口核验 · 合成测试", sourceName: "local://integration-fixture", segments: [[point(0), point(100), point(200)]])
let map = OfflineMap(bounds: try MapBounds.around(route), features: [
    MapFeature(id: 1, kind: "path", name: "示意主路", points: [point(0),point(100),point(200)],nodeIDs:[1,2,3]),
    MapFeature(id: 2, kind: "path", name: "示意支路", points: [point(100),point(100,100)],nodeIDs:[2,4])
], sourceURL: "local://synthetic-osm-nodes", downloadedAt: Date(), provider: "synthetic")
let report = RoutePreparation.analyze(route: route, map: map)
try MapBundleStorage.encode(RouteMapBundle(route: route, map: map)).write(to: out.appendingPathComponent("cue-fixture.runnersmap"))
try JSONEncoder().encode(route).write(to: out.appendingPathComponent("cue-fixture-route.json"))
print("Synthetic route: \(report.candidates.count) unconfirmed junction; road proximity \(report.roadCoverage)")
if args.count > 2 {
    let folder = URL(fileURLWithPath: args[2], isDirectory: true)
    let archive = ActivityArchive(simulated: true, summaryData: try Data(contentsOf: folder.appendingPathComponent("summary.json")),
                                   samplesData: try Data(contentsOf: folder.appendingPathComponent("samples.ndjson")))
    let summary = try archive.summary
    try ActivityTCX.data(archive).write(to: out.appendingPathComponent("health-run.tcx"))
    try ActivityStorage.encode(archive).write(to: out.appendingPathComponent("\(summary.id.uuidString).runnersactivity"))
    print("Exported real simulator archive as TCX, including actual timestamps, GPS and heart samples; upload stays blocked.")
}
