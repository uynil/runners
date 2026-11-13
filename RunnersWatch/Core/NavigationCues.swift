import Foundation

struct NavigationCue: Decodable {
    let id: String
    let progressMeters: Double
    let coordinate: RouteCoordinate
    let turn: String
    let name: String
    let confirmed: Bool
    var title: String {
        let action = turn == "left" ? "左转" : (turn == "right" ? "右转" : "沿轨迹直行")
        return name.isEmpty ? action : "\(action) · \(name)"
    }
}

struct NavigationCueNotice {
    let cue: NavigationCue
    let meters: Double
    let shouldAlert: Bool
}

struct NavigationCueTrigger {
    private var announced = Set<String>()
    private var previousProgress: Double?
    mutating func consume(_ result: NavigationResult, cues: [NavigationCue]) -> NavigationCueNotice? {
        guard result.status == .onRoute, !result.isReverse, let progress = result.progressMeters else {
            previousProgress = nil; return nil
        }
        let previous = previousProgress
        previousProgress = progress
        guard let next = cues.first(where: { $0.confirmed && $0.progressMeters >= progress }),
              next.progressMeters - progress <= 300 else { return nil }
        let distance = next.progressMeters - progress
        let alert = previous != nil && progress >= previous! - 3 && distance <= 60 && !announced.contains(next.id)
        if alert { announced.insert(next.id) }
        return NavigationCueNotice(cue: next, meters: distance, shouldAlert: alert)
    }
}
