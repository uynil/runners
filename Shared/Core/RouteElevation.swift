import Foundation

/// Elevation from the source file, with no interpolation across missing data or segment boundaries.
struct RouteElevationProfile {
    struct Sample {
        let distanceMeters: Double
        let elevationMeters: Double
    }

    let segments: [[Sample]]
    let distanceMeters: Double
    let coveredMeters: Double
    let ascentMeters: Double
    let descentMeters: Double
    let minimumMeters: Double
    let maximumMeters: Double

    var coverage: Double { min(1, coveredMeters / distanceMeters) }

    init?(route: PlannedRoute) {
        var distance = 0.0, covered = 0.0, ascent = 0.0, descent = 0.0
        var low = Double.infinity, high = -Double.infinity
        var profiles: [[Sample]] = []
        for segment in route.segments {
            var previous: RoutePoint?, previousElevation: Double?
            var profile: [Sample] = []
            func closeProfile() {
                if profile.count >= 2 { profiles.append(profile) }
                profile = []
            }
            for point in segment {
                let leg = previous.map { $0.distance(to: point) } ?? 0
                distance += leg
                let elevation = RoutePoint.validElevation(point.elevationMeters)
                if let elevation, let previousElevation, leg > 0 {
                    if profile.isEmpty {
                        profile.append(Sample(distanceMeters: distance - leg, elevationMeters: previousElevation))
                    }
                    profile.append(Sample(distanceMeters: distance, elevationMeters: elevation))
                    covered += leg
                    ascent += max(0, elevation - previousElevation)
                    descent += max(0, previousElevation - elevation)
                    low = min(low, elevation, previousElevation)
                    high = max(high, elevation, previousElevation)
                } else { closeProfile() }
                previous = point
                previousElevation = elevation
            }
            closeProfile()
        }
        guard covered > 0, distance.isFinite, !profiles.isEmpty else { return nil }
        segments = profiles; distanceMeters = distance; coveredMeters = covered
        ascentMeters = ascent; descentMeters = descent; minimumMeters = low; maximumMeters = high
    }
}
