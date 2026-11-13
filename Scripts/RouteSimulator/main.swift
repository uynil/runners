import Foundation

// Compile with the shared importer, RunData and RouteNavigation source files.
// Outputs stay in the caller's chosen local folder; original GPX times aren't replay times.
let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fatalError("Usage: route-simulator <input.gpx> <output-directory>")
}
let source = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let imported = try RouteImporter.read(Data(contentsOf: source), sourceName: source.lastPathComponent)
guard imported.count == 1, let planned = imported.first else { fatalError("Choose one route before replay.") }
let data = try JSONEncoder().encode(planned)
let route = try NavigationRoute.decode(data)
let points = route.segments.flatMap { $0 }
let epoch = Date(timeIntervalSince1970: 1_000_000)
func sample(_ point: RouteCoordinate, _ time: Double) -> GPSFix {
    GPSFix(timestamp: epoch.addingTimeInterval(time), latitude: point.latitude, longitude: point.longitude, accuracy: 5)
}

var navigator = RouteNavigator(route: route)
var time = 0.0
var previous: RouteCoordinate?
var final: NavigationResult?
for segment in route.segments {
    previous = nil
    for point in segment {
        time += previous.map { max(1, $0.distance(to: point) / 3) } ?? 1
        let fix = sample(point, time)
        final = navigator.consume(fix, receivedAt: fix.timestamp)
        guard final?.status == .onRoute else { fatalError("Along-route replay lost the original route.") }
        previous = point
    }
}
guard let final, let progress = final.progressMeters, progress > route.distanceMeters * 0.95 else {
    fatalError("Replay didn't reach the route's final section.")
}

// Prepare a short, real-time path near the route start and a physical 100m excursion.
var along = [points[0]]
var alongDistance = 0.0
for point in points.dropFirst() {
    alongDistance += along.last!.distance(to: point)
    along.append(point)
    if alongDistance >= 150 { break }
}
let anchor = along.last!
let before = along[along.count - 2]
let a = route.projection.project(before), b = route.projection.project(anchor)
let dx = b.x - a.x, dy = b.y - a.y
let length = max(0.01, hypot(dx, dy))
func offset(_ meters: Double) -> RouteCoordinate {
    RouteCoordinate(latitude: anchor.latitude + dx / length * meters / 111_194.9266,
                    longitude: anchor.longitude - dy / length * meters / (111_194.9266 * cos(anchor.latitude * .pi / 180)))
}
var reference = RouteNavigator(route: route)
var clock = 0.0
for (index, point) in along.enumerated() {
    if index > 0 { clock += max(1, along[index - 1].distance(to: point) / 3) }
    let fix = sample(point, clock)
    _ = reference.consume(fix, receivedAt: fix.timestamp)
}
let excursions = [100.0, -100.0].map { meters -> (RouteCoordinate, Double) in
    let point = offset(meters)
    var copy = reference
    let fix = sample(point, clock + 40)
    return (point, copy.consume(fix, receivedAt: fix.timestamp).distanceToRoute ?? 0)
}
let excursion = excursions.max { $0.1 < $1.1 }!
guard excursion.1 > 50 else { fatalError("Choose a clearer off-route excursion.") }
let off = excursion.0
let off2 = RouteCoordinate(latitude: off.latitude + 0.00004, longitude: off.longitude)

func replay(_ values: [RouteCoordinate], navigator: inout RouteNavigator, time: inout Double) -> NavigationResult {
    var result: NavigationResult?
    for (a, b) in zip(values, values.dropFirst()) {
        let count = max(1, Int(ceil(a.distance(to: b) / 3)))
        for step in 1...count {
            time += 1
            let fraction = Double(step) / Double(count)
            let point = RouteCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                                        longitude: a.longitude + (b.longitude - a.longitude) * fraction)
            let fix = sample(point, time)
            result = navigator.consume(fix, receivedAt: fix.timestamp)
        }
    }
    return result!
}
let deviated = replay([anchor, off, off2], navigator: &reference, time: &clock)
guard deviated.status == .offRoute else { fatalError("Excursion didn't trigger a sustained deviation.") }
let returned = replay([off2, anchor], navigator: &reference, time: &clock)
guard returned.status == .onRoute else { fatalError("Returning to the original track didn't clear the deviation.") }

func waypoints(_ values: [RouteCoordinate]) -> String {
    values.map { String(format: "%.8f,%.8f", locale: Locale(identifier: "en_US_POSIX"), $0.latitude, $0.longitude) }.joined(separator: "\n") + "\n"
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try data.write(to: output.appendingPathComponent("navigation-route.json"), options: .atomic)
try waypoints(along).write(to: output.appendingPathComponent("along.txt"), atomically: true, encoding: .utf8)
try waypoints([anchor, off, off2]).write(to: output.appendingPathComponent("off.txt"), atomically: true, encoding: .utf8)
try waypoints([off2, anchor, along[along.count - 2]]).write(to: output.appendingPathComponent("return.txt"), atomically: true, encoding: .utf8)
let metadata: [String: Any] = ["source": source.lastPathComponent, "routeName": route.name,
                             "segments": route.segments.count, "points": points.count,
                             "distanceMeters": route.distanceMeters, "renderPoints": route.renderSegments.flatMap { $0 }.count,
                             "fullReplayProgress": progress, "fullReplayRemaining": final.remainingMeters ?? -1,
                             "shortReplayMeters": alongDistance, "offRouteDistance": excursion.1,
                             "excursionTriggered": deviated.status == .offRoute, "returnCleared": returned.status == .onRoute]
let report = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
try report.write(to: output.appendingPathComponent("report.json"), options: .atomic)
print(String(data: report, encoding: .utf8)!)
