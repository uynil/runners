import Foundation

/// Display geometry for the entire current workout. Raw fixes remain in RunStorage.
/// Nearby fixes replace the live endpoint, keeping the historical path within 3 m
/// without dropping its beginning during long workouts.
struct RecordedTrail {
    private(set) var vertices: [TrailVertex] = []
    private var previous: GPSFix?
    private var needsSegment = true

    mutating func breakSegment() {
        previous = nil
        needsSegment = true
    }

    mutating func append(_ fix: GPSFix) {
        guard fix.latitude.isFinite, fix.longitude.isFinite,
              (-90...90).contains(fix.latitude), (-180...180).contains(fix.longitude),
              fix.accuracy.isFinite, (0...20).contains(fix.accuracy) else {
            breakSegment()
            return
        }
        if let last = vertices.last?.fix, fix.timestamp <= last.timestamp { return }
        let starts = needsSegment || previous.map { fix.timestamp.timeIntervalSince($0.timestamp) > 15 } == true
        if !starts, vertices.count >= 2, !vertices[vertices.count - 1].startsSegment,
           vertices[vertices.count - 2].fix.distance(to: fix) < 3 {
            vertices[vertices.count - 1] = TrailVertex(fix: fix, startsSegment: false)
        } else {
            vertices.append(TrailVertex(fix: fix, startsSegment: starts))
        }
        previous = fix
        needsSegment = false
    }
}

/// Shared transform for map layers: the followed fix maps to the exact view center.
struct NavigationViewport {
    let center: RouteXY
    let scale: Double
    let width: Double
    let height: Double
    let panX: Double
    let panY: Double

    func screen(_ point: RouteXY) -> RouteXY {
        RouteXY(x: (point.x - center.x) * scale + width / 2 + panX,
                y: -(point.y - center.y) * scale + height / 2 + panY)
    }
}
