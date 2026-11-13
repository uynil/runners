import Combine
import CoreLocation
import HealthKit
import Foundation
import WatchKit

@MainActor
final class WorkoutRecorder: NSObject, ObservableObject {
    enum Phase { case idle, authorizing, starting, recovering, running, paused, saving, finished }

    @Published private(set) var phase: Phase = .idle
    @Published var selectedActivity: OutdoorActivity = .running
    @Published private(set) var summary: RunSummary?
    @Published private(set) var heartRate: Double?
    @Published private(set) var heartDate: Date?
    @Published private(set) var lastFix: GPSFix?
    @Published private(set) var trail = RecordedTrail()
    @Published private(set) var message: String?
    @Published private(set) var storageError: String?
    @Published private(set) var locationStatus = "尚未定位"
    @Published private(set) var navigationRoute: NavigationRoute?
    @Published private(set) var navigationResult: NavigationResult?
    @Published private(set) var navigationError: String?
    @Published private(set) var navigationCue: NavigationCueNotice?
    private var cueTrigger = NavigationCueTrigger()
    private var navigationSettings = NavigationSettings()

    private let healthStore = HKHealthStore()
    private let locationManager = CLLocationManager()
    private let storage = RunStorage()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var healthWriter: HealthWorkoutWriter?
    private var lastHealthDistanceDate: Date?
    private var distance = DistanceAccumulator()
    private var elevation = ElevationAccumulator()
    private var recentPace = RecentPace()
    private var lapStartSeconds: Double = 0
    private var lapStartMeters: Double = 0
    private var lastEnergyDate: Date?

    func currentPace(at date: Date) -> Double? {
        guard phase == .running else { return nil }
        return recentPace.secondsPerKilometer(at: date)
    }

    private func recordEvent(_ kind: String, at date: Date) {
        append(RunSample(kind: kind, timestamp: date, receivedAt: Date(), fix: nil,
                         heartRate: nil, acceptedForDistance: nil))
    }

    func markLap() {
        guard phase == .running else { return }
        closeLap(at: Date(), partial: false)
        WKInterfaceDevice.current().play(.click)
        checkpoint()
    }

    private func closeLap(at date: Date, partial: Bool) {
        guard let summary else { return }
        let seconds = activeTime(at: date)
        guard seconds - lapStartSeconds > 0 else { return }
        let lap = WorkoutLap(number: (summary.laps?.count ?? 0) + 1, endedAt: date,
                             activeSeconds: seconds - lapStartSeconds,
                             distanceMeters: max(0, summary.distanceMeters - lapStartMeters), isPartial: partial)
        self.summary?.laps = (summary.laps ?? []) + [lap]
        lapStartSeconds = seconds
        lapStartMeters = summary.distanceMeters
        recordEvent(partial ? "finalLap" : "lap", at: date)
    }

    private var observationStart: Date?
    private var activeSegmentStart: Date?
    private var checkpointTimer: Timer?
    private var finishingHealth = false
    private var recoveryInFlight = false
    private var navigator: RouteNavigator?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        summary = storage.latestSummary()
        reloadNavigationRoute()
        if let summary {
            phase = summary.endedAt == nil || summary.healthStatus == "正在保存至健康" ? .recovering : .finished
        }
    }

    var canStart: Bool {
        (phase == .idle || phase == .finished) && storageError == nil
    }

    func recoverIfNeeded() {
        guard phase == .recovering, !recoveryInFlight, let saved = summary else { return }
        recoveryInFlight = true
        Task {
            defer { recoveryInFlight = false }
            let recovered: HKWorkoutSession?
            do { recovered = try await healthStore.recoverActiveWorkoutSession() }
            catch let error as HKError where error.code == .errorDatabaseInaccessible {
                message = "解锁手表后重试接续运动。原记录已保留。"
                return
            } catch { recovered = nil }
            let now = Date()
            do {
                let reopened = try storage.reopen(saved, asOf: now)
                summary = reopened.summary
                guard let recovered else {
                    preserveInterrupted(at: reopened.lastSampleAt)
                    return
                }
                let recoveredBuilder = recovered.associatedWorkoutBuilder()
                let start = recoveredBuilder.startDate ?? recovered.startDate
                guard let start, abs(start.timeIntervalSince(saved.startedAt)) <= 1,
                      [.running, .paused, .stopped].contains(recovered.state) else {
                    preserveInterrupted(at: reopened.lastSampleAt)
                    return
                }
                session = recovered; builder = recoveredBuilder
                recoveredBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: recovered.workoutConfiguration)
                recoveredBuilder.dataSource?.disableCollection(for: HKQuantityType(.distanceWalkingRunning))
                recovered.delegate = self; recoveredBuilder.delegate = self
                healthWriter = HealthWorkoutWriter(builder: recoveredBuilder, store: healthStore)
                selectedActivity = saved.activity ?? .running
                distance = DistanceAccumulator(meters: summary?.distanceMeters ?? 0)
                elevation = ElevationAccumulator(ascent: saved.metrics?.ascentMeters ?? 0, descent: saved.metrics?.descentMeters ?? 0)
                lapStartMeters = saved.laps?.reduce(0) { $0 + $1.distanceMeters } ?? 0
                lapStartSeconds = saved.laps?.reduce(0) { $0 + $1.activeSeconds } ?? 0
                navigationSettings = NavigationSettings.load() ?? NavigationSettings()
                lastHealthDistanceDate = now
                let state = recovered.state
                if saved.endedAt != nil || state == .stopped {
                    let end = saved.endedAt ?? recovered.endDate ?? now
                    summary?.endedAt = end
                    phase = .saving
                    if state == .stopped { finishHealth(at: end) }
                    else { recovered.stopActivity(with: end) }
                    return
                }
                summary?.recoveryCount = (saved.recoveryCount ?? 0) + 1
                summary?.metrics?.altitudeMeters = nil
                append(RunSample(kind: "recoveryGap", timestamp: now, receivedAt: now, fix: nil,
                    heartRate: nil, acceptedForDistance: nil,
                    gapStartedAt: min(now, max(reopened.lastSampleAt, saved.lastCheckpointAt ?? saved.startedAt))))
                if state == .running { recordEvent("resume", at: now) }
                // Do not reconstruct unobserved time, GPS distance, or heart samples.
                observationStart = now
                activeSegmentStart = state == .running ? now : nil
                phase = state == .running ? .running : .paused
                message = "已接回运动，记录中断处保留缺口。"
                checkpoint()
                scheduleCheckpoints()
                startLocationIfAuthorized()
            } catch {
                // Keep the original files and never start a replacement workout silently.
                storageError = "无法接续原采样文件：\(error.localizedDescription)"
                message = "已保留原始运动记录。"
                phase = .finished
            }
        }
    }

    private func preserveInterrupted(at lastSample: Date) {
        guard let saved = summary else { return }
        let end = saved.endedAt ?? max(saved.lastCheckpointAt ?? saved.startedAt, lastSample)
        summary?.endedAt = end
        summary?.healthStatus = "运动中断；健康保存未确认"
        recordEvent("interrupted", at: end)
        message = "系统没有可接续的运动；已保留中断前记录。"
        checkpoint()
        phase = .finished
    }

    func reloadNavigationRoute() {
        guard phase == .idle || phase == .finished || phase == .recovering else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("navigation-route.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 10 * 1_024 * 1_024 else { throw NavigationRoute.RouteError.invalid }
            let route = try NavigationRoute.decode(Data(contentsOf: url))
            navigationRoute = route
            navigator = RouteNavigator(route: route)
            navigationResult = nil
            navigationCue = nil
            cueTrigger = NavigationCueTrigger()
            navigationError = nil
        } catch { navigationError = error.localizedDescription }
    }

    func updateSelectedRoute(from bundles: [RouteMapBundle]) {
        guard phase == .idle || phase == .finished, let id = navigationRoute?.id,
              let route = bundles.first(where: { $0.id == id })?.route,
              let updatedAt = route.cuesUpdatedAt else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("navigation-route.json")
        guard let data = try? Data(contentsOf: url),
              let current = try? JSONDecoder().decode(PlannedRoute.self, from: data),
              updatedAt > (current.cuesUpdatedAt ?? .distantPast) else { return }
        do {
            try JSONEncoder().encode(route).write(to: url, options: .atomic)
            reloadNavigationRoute()
        } catch { navigationError = error.localizedDescription }
    }

    func elapsed(at date: Date) -> Double {
        guard let summary else { return 0 }
        return max(0, (summary.endedAt ?? date).timeIntervalSince(summary.startedAt))
    }

    func activeTime(at date: Date) -> Double {
        (summary?.activeSeconds ?? 0) + activeSegmentStart.map { max(0, date.timeIntervalSince($0)) }.defaultZero
    }

    func start() {
        guard canStart else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            message = "此设备的健康数据不可用。"
            return
        }
        phase = .authorizing
        message = nil
        let heartType = HKQuantityType(.heartRate)
        var readTypes: Set<HKObjectType> = [heartType, HKQuantityType(.activeEnergyBurned)]
        #if DEBUG && targetEnvironment(simulator)
        if HealthSimulatorVerification.enabled { readTypes.formUnion([HKSeriesType.workoutRoute(), HKObjectType.workoutType()]) }
        #endif
        healthStore.requestAuthorization(toShare: [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning), HKSeriesType.workoutRoute()],
            read: readTypes) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard success, error == nil else {
                    self.phase = .idle
                    self.message = error?.localizedDescription ?? "健康授权未完成。"
                    return
                }
                guard self.healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                    self.phase = .idle
                    self.message = "需要允许保存运动后才能开始。"
                    return
                }
                self.beginSession()
            }
        }
    }

    private func beginSession() {
        phase = .starting
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = selectedActivity == .hiking ? .hiking : .running
        configuration.locationType = .outdoor
        do {
            let newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newSession.delegate = self
            newBuilder.delegate = self
            newBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            newBuilder.dataSource?.disableCollection(for: HKQuantityType(.distanceWalkingRunning))
            let now = Date()
            let newSummary = RunSummary(id: UUID(), startedAt: now, endedAt: nil, activeSeconds: 0,
                                        distanceMeters: 0, gpsSampleCount: 0, heartSampleCount: 0,
                                        healthStatus: "采集中", healthWorkoutID: nil,
                                        activity: selectedActivity, metrics: WorkoutMetrics(), laps: [])
            try storage.begin(newSummary)
            summary = newSummary
            session = newSession
            builder = newBuilder
            healthWriter = HealthWorkoutWriter(builder: newBuilder, store: healthStore)
            lastHealthDistanceDate = now
            distance = DistanceAccumulator()
            elevation = ElevationAccumulator()
            recentPace = RecentPace()
            lapStartSeconds = 0
            lapStartMeters = 0
            lastEnergyDate = nil
            recordEvent("start", at: now)
            navigator = navigationRoute.map { RouteNavigator(route: $0) }
            navigationSettings = NavigationSettings.load() ?? NavigationSettings()
            navigationResult = nil
            navigationCue = nil
            cueTrigger = NavigationCueTrigger()
            heartRate = nil
            heartDate = nil
            lastFix = nil
            trail = RecordedTrail()
            finishingHealth = false
            locationStatus = "等待 GPS"
            locationManager.requestWhenInUseAuthorization()
            newSession.startActivity(with: now)
            newBuilder.beginCollection(withStart: now) { [weak self] success, error in
                guard !success || error != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.session === newSession else { return }
                    self.interrupt(error?.localizedDescription ?? "运动采集启动失败。")
                }
            }
            scheduleCheckpoints()
        } catch {
            phase = .idle
            message = "无法开始：\(error.localizedDescription)"
        }
    }

    private func scheduleCheckpoints() {
        checkpointTimer?.invalidate()
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkpoint() }
        }
    }

    func togglePause() {
        if phase == .running { session?.pause() }
        else if phase == .paused { session?.resume() }
    }

    func stopAndSave() {
        guard phase == .running || phase == .paused else { return }
        let now = Date()
        closeLap(at: now, partial: true)
        recordEvent("stop", at: now)
        settleTime(at: now)
        activeSegmentStart = nil
        phase = .saving
        summary?.endedAt = now
        summary?.healthStatus = "正在保存至健康"
        locationManager.stopUpdatingLocation()
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        checkpoint()
        session?.stopActivity(with: now)
    }

    func checkpoint() {
        guard summary != nil else { return }
        settleTime(at: Date())
        healthWriter?.flush()
        do {
            summary?.lastCheckpointAt = Date()
            try storage.checkpoint(summary!)
            storageError = nil
        } catch {
            storageError = "本地保存失败：\(error.localizedDescription)"
        }
    }

    private func settleTime(at now: Date) {
        if let activeSegmentStart {
            summary?.activeSeconds += max(0, now.timeIntervalSince(activeSegmentStart))
            self.activeSegmentStart = now
        }
    }

    private func append(_ sample: RunSample) {
        do { try storage.append(sample) }
        catch { storageError = "采集文件写入失败：\(error.localizedDescription)" }
    }

    private func finishHealth(at date: Date) {
        guard !finishingHealth, let builder else { return }
        finishingHealth = true
        Task {
            await healthWriter?.drain()
            do {
                if let id = summary?.id {
                    try await builder.addMetadata([HKMetadataKeySyncIdentifier: "runners-\(id.uuidString)", HKMetadataKeySyncVersion: 1])
                }
                if builder.endDate == nil { try await builder.endCollection(at: date) }
                let workout = try await builder.finishWorkout()
                finishResult(workout: workout, error: nil)
            } catch { finishResult(workout: nil, error: error) }
        }
    }

    private func finishResult(workout: HKWorkout?, error: Error?) {
        if let builder { receiveEnergy(from: builder) }
        summary?.healthWorkoutID = workout?.uuid
        summary?.healthStatus = workout == nil ? "健康保存未成功" : "运动已保存至健康"
        let recovered = (summary?.recoveryCount ?? 0) > 0
        summary?.healthRouteStatus = workout == nil ? "运动未保存，健康轨迹未确认"
            : recovered ? "中断前最后一批 GPS 可能未写入；完整本地采样保留" : healthWriter?.routeStatus
        summary?.healthDistanceStatus = recovered ? "中断前后健康距离可能与本地不同" : healthWriter?.distanceStatus
        if let error { message = error.localizedDescription }
        session?.end()
        phase = .finished
        checkpoint()
        #if DEBUG && targetEnvironment(simulator)
        if let workout { HealthSimulatorVerification.verify(store: healthStore, workout: workout) }
        #endif
    }

    private func interrupt(_ reason: String) {
        guard phase != .finished && phase != .idle else { return }
        let now = Date()
        closeLap(at: now, partial: true)
        recordEvent("interrupted", at: now)
        settleTime(at: now)
        activeSegmentStart = nil
        summary?.endedAt = now
        summary?.healthStatus = "运动中断；健康保存未确认"
        message = reason
        locationManager.stopUpdatingLocation()
        checkpointTimer?.invalidate()
        checkpointTimer = nil
        session?.end()
        phase = .finished
        checkpoint()
    }

    private func startLocationIfAuthorized() {
        guard phase == .running else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationStatus = "等待 GPS"
            locationManager.startUpdatingLocation()
        case .denied, .restricted:
            locationStatus = "定位未授权"
        default:
            locationStatus = "等待定位授权"
        }
    }

    private func receiveLocations(_ locations: [CLLocation]) {
        guard phase == .running, let startedAt = observationStart else { return }
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let fix = GPSFix(timestamp: location.timestamp, latitude: location.coordinate.latitude,
                             longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy)
            guard fix.latitude.isFinite, fix.longitude.isFinite, fix.accuracy.isFinite else {
                trail.breakSegment()
                continue
            }
            let now = Date()
            if fix.timestamp >= startedAt {
                navigationResult = navigator?.consume(fix, receivedAt: now)
                if navigationSettings.offRouteHaptics, navigationResult?.shouldAlert == true {
                    WKInterfaceDevice.current().play(.notification)
                }
                if let result = navigationResult {
                    navigationCue = cueTrigger.consume(result, cues: navigationRoute?.cues ?? [])
                    if navigationSettings.junctionHaptics, navigationCue?.shouldAlert == true {
                        WKInterfaceDevice.current().play(.notification)
                    }
                }
            }
            let accepted: Bool
            let previousMeters = distance.meters
            if fix.timestamp >= startedAt { accepted = distance.consume(fix, receivedAt: now) }
            else { accepted = false }
            if lastFix == nil || fix.timestamp > lastFix!.timestamp { lastFix = fix }
            summary?.gpsSampleCount += 1
            summary?.distanceMeters = distance.meters
            append(RunSample(kind: "gps", timestamp: fix.timestamp, receivedAt: now, fix: fix,
                             heartRate: nil, acceptedForDistance: accepted,
                             altitudeMeters: location.altitude.isFinite ? location.altitude : nil,
                             verticalAccuracy: location.verticalAccuracy.isFinite ? location.verticalAccuracy : nil,
                             cumulativeDistanceMeters: distance.meters))
            if accepted {
                healthWriter?.append(location, distance: distance.meters - previousMeters,
                                     since: lastHealthDistanceDate ?? startedAt)
                lastHealthDistanceDate = fix.timestamp
                recentPace.consume(timestamp: fix.timestamp, meters: distance.meters)
                elevation.consume(altitude: location.altitude, accuracy: location.verticalAccuracy, timestamp: fix.timestamp)
                if elevation.current != nil { summary?.metrics?.elevationSampleCount += 1 }
                summary?.metrics?.altitudeMeters = elevation.current
                summary?.metrics?.ascentMeters = elevation.ascent
                summary?.metrics?.descentMeters = elevation.descent
                trail.append(fix)
            } else {
                recentPace.breakSegment()
                elevation.breakSegment()
                summary?.metrics?.altitudeMeters = nil
                trail.breakSegment()
            }
        }
    }

    private func receiveHeartRate(from builder: HKLiveWorkoutBuilder) {
        guard phase == .running else { return }
        let type = HKQuantityType(.heartRate)
        guard let statistics = builder.statistics(for: type),
              let quantity = statistics.mostRecentQuantity(),
              let date = statistics.mostRecentQuantityDateInterval()?.end,
              date >= (observationStart ?? .distantFuture),
              heartDate == nil || date > heartDate! else { return }
        let value = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        guard value.isFinite, value > 0 else { return }
        heartRate = value
        heartDate = date
        summary?.heartSampleCount += 1
        summary?.metrics?.recordHeartRate(value)
        append(RunSample(kind: "heartRate", timestamp: date, receivedAt: Date(), fix: nil,
                         heartRate: value, acceptedForDistance: nil))
    }
    private func receiveEnergy(from builder: HKLiveWorkoutBuilder) {
        guard phase == .running || phase == .paused || phase == .saving else { return }
        guard let statistics = builder.statistics(for: HKQuantityType(.activeEnergyBurned)),
              let quantity = statistics.sumQuantity() else { return }
        let value = quantity.doubleValue(for: .kilocalorie())
        let date = statistics.endDate
        guard value.isFinite, value >= 0, lastEnergyDate == nil || date > lastEnergyDate! else { return }
        lastEnergyDate = date
        summary?.metrics?.activeEnergyKilocalories = value
        append(RunSample(kind: "energy", timestamp: date, receivedAt: Date(), fix: nil,
                         heartRate: nil, acceptedForDistance: nil, activeEnergyKilocalories: value))
    }
}

extension WorkoutRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            guard workoutSession === self.session else { return }
            switch toState {
            case .running:
                guard self.phase == .starting || self.phase == .paused else { return }
                self.observationStart = date
                self.activeSegmentStart = date
                self.distance.breakSegment()
                self.elevation.breakSegment()
                self.recentPace.breakSegment()
                self.summary?.metrics?.altitudeMeters = nil
                if fromState == .paused { self.recordEvent("resume", at: date) }
                self.trail.breakSegment()
                self.phase = .running
                self.startLocationIfAuthorized()
            case .paused:
                guard self.phase == .running else { return }
                self.settleTime(at: date)
                self.activeSegmentStart = nil
                self.distance.breakSegment()
                self.elevation.breakSegment()
                self.recentPace.breakSegment()
                self.summary?.metrics?.altitudeMeters = nil
                self.trail.breakSegment()
                self.recordEvent("pause", at: date)
                self.navigator?.breakObservation()
                self.phase = .paused
                self.locationManager.stopUpdatingLocation()
                self.checkpoint()
            case .stopped:
                guard self.phase == .saving else { return }
                // The delegate may arrive after the stop request. Disk and Health
                // must use the same end instant, independent of callback latency.
                self.finishHealth(at: self.summary?.endedAt ?? date)
            default: break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard workoutSession === self.session else { return }
            self.interrupt(error.localizedDescription)
        }
    }
}

extension WorkoutRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        Task { @MainActor in
            guard workoutBuilder === self.builder else { return }
            if collectedTypes.contains(HKQuantityType(.heartRate)) { self.receiveHeartRate(from: workoutBuilder) }
            if collectedTypes.contains(HKQuantityType(.activeEnergyBurned)) { self.receiveEnergy(from: workoutBuilder) }
        }
    }
}

extension WorkoutRecorder: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.receiveLocations(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .denied, .restricted: self.locationStatus = "定位未授权"
            case .authorizedAlways, .authorizedWhenInUse:
                self.locationStatus = "等待 GPS"
                self.startLocationIfAuthorized()
            default: self.locationStatus = "等待定位授权"
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.locationStatus = "定位暂不可用" }
    }
}

private extension Optional where Wrapped == Double {
    var defaultZero: Double { self ?? 0 }
}
