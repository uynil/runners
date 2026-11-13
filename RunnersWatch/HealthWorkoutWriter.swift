import HealthKit
import CoreLocation

/// Serializes batched HealthKit writes before finishing the live workout.
/// The live workout builder owns and finalizes its route series; never finish it twice.
@MainActor
final class HealthWorkoutWriter {
    let builder: HKLiveWorkoutBuilder
    private let route: HKWorkoutRouteBuilder?
    private let writesDistance: Bool
    private var locations: [CLLocation] = []
    private var quantities: [HKSample] = []
    private var pending: Task<Void, Never>?
    private(set) var routeCount = 0
    private(set) var routeError = false
    private(set) var distanceError = false

    init(builder: HKLiveWorkoutBuilder, store: HKHealthStore) {
        self.builder = builder
        let routeType = HKSeriesType.workoutRoute()
        route = store.authorizationStatus(for: routeType) == .sharingAuthorized
            ? builder.seriesBuilder(for: routeType) as? HKWorkoutRouteBuilder : nil
        writesDistance = store.authorizationStatus(for: HKQuantityType(.distanceWalkingRunning)) == .sharingAuthorized
    }

    func append(_ location: CLLocation, distance: Double, since date: Date) {
        if route != nil { locations.append(location) }
        if writesDistance, distance > 0, date < location.timestamp {
            quantities.append(HKQuantitySample(type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: distance), start: date, end: location.timestamp))
        }
        if locations.count >= 30 || quantities.count >= 12 { flush() }
    }

    func flush() {
        guard !locations.isEmpty || !quantities.isEmpty else { return }
        let points = locations, samples = quantities, previous = pending
        locations = []; quantities = []
        pending = Task {
            await previous?.value
            if !samples.isEmpty {
                do { try await builder.addSamples(samples) }
                catch { distanceError = true }
            }
            if let route, !points.isEmpty, !routeError {
                do { try await route.insertRouteData(points); routeCount += points.count }
                catch { routeError = true }
            }
        }
    }

    func drain() async { flush(); await pending?.value }

    var routeStatus: String {
        if route == nil { return "未授权健康轨迹写入；轨迹仍保存在本机" }
        if routeError { return "健康轨迹提交失败；本机原始轨迹已保留" }
        return routeCount > 0 ? "实际 GPS 已提交至健康（\(routeCount) 点）" : "无有效 GPS，未提交健康轨迹"
    }
    var distanceStatus: String {
        !writesDistance ? "未授权健康距离写入" : (distanceError ? "健康距离提交失败" : "GPS 距离已提交至健康")
    }
}
