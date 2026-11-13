#if DEBUG && targetEnvironment(simulator)
import Foundation
import HealthKit

private struct HealthVerificationReport: Encodable, Sendable {
    let simulated = true
    let workoutID: String
    let routeSeriesCount: Int
    let gpsDistanceMeters: Double
    let querySucceeded: Bool
    let healthDurationSeconds: Double
    let healthStartedAt: Double
    let healthEndedAt: Double
    let meanHeartBPM: Double
    let syncIdentifier: String
    var routePointCount: Int?
    var routeReadSucceeded: Bool?
}

/// HealthKit may deliver several batches off the main actor. Report access
/// and its final write are serialized by this lock.
private final class HealthRouteVerificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var report: HealthVerificationReport
    private var points = 0
    init(_ report: HealthVerificationReport) { self.report = report }
    func receive(count: Int, done: Bool, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        points += count
        if done || !succeeded {
            report.routePointCount = points; report.routeReadSucceeded = succeeded
            writeLocked()
        }
    }
    func saveWithoutRoute() { lock.lock(); defer { lock.unlock() }; writeLocked() }
    private func writeLocked() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? encoder.encode(report) {
            try? data.write(to: directory.appendingPathComponent("health-simulator-verification.json"), options: .atomic)
        }
    }
}

/// Opt-in local integration evidence, compiled only into debug simulators.
@MainActor enum HealthSimulatorVerification {
    static var enabled: Bool { ProcessInfo.processInfo.environment["RUNNERS_HEALTH_QA"] == "1" }
    static func verify(store: HKHealthStore, workout: HKWorkout) {
        guard enabled else { return }
        let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: HKQuery.predicateForObjects(from: workout), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
            let routes = (samples as? [HKWorkoutRoute]) ?? []
            let report = HealthVerificationReport(workoutID: workout.uuid.uuidString, routeSeriesCount: routes.count,
                gpsDistanceMeters: workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()) ?? -1,
                querySucceeded: error == nil, healthDurationSeconds: workout.duration,
                healthStartedAt: workout.startDate.timeIntervalSince1970, healthEndedAt: workout.endDate.timeIntervalSince1970,
                meanHeartBPM: workout.statistics(for: HKQuantityType(.heartRate))?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) ?? -1,
                syncIdentifier: workout.metadata?[HKMetadataKeySyncIdentifier] as? String ?? "")
            let collector = HealthRouteVerificationCollector(report)
            guard let route = routes.first else { collector.saveWithoutRoute(); return }
            store.execute(HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                collector.receive(count: locations?.count ?? 0, done: done, succeeded: error == nil)
            })
        }
        store.execute(query)
    }
}
#endif
