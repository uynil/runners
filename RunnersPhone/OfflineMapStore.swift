import Foundation
import Combine

@MainActor
final class OfflineMapStore: ObservableObject {
    @Published private(set) var bundles: [UUID: RouteMapBundle] = [:]
    @Published private(set) var downloading = Set<UUID>()
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var storageError: String?
    @Published private(set) var jobs: [MapDownloadJob] = []
    private var activeJob: UUID?
    private var jobsAvailable = true
    private var tasks: [UUID: Task<Void, Never>] = [:]
    let storage: MapBundleStorage
    let jobStorage: MapJobStorage

    static var endpointString: String {
        if let value = UserDefaults.standard.string(forKey: "mapEndpoint") { return value }
        #if DEBUG
        return "https://overpass-api.de/api/interpreter"
        #else
        return ""
        #endif
    }

    init() {
        jobStorage = MapJobStorage(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runners/MapDownloads"))
        storage = MapBundleStorage(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Runners/Maps"))
        do {
            let result = try storage.scan()
            bundles = Dictionary(uniqueKeysWithValues: result.bundles.map { ($0.id, $0) })
            if result.invalidCount > 0 { storageError = "有 \(result.invalidCount) 个地图包损坏，原文件已保留；其他地图仍可使用。" }
        }
        catch { storageError = "地图读取失败：\(error.localizedDescription)" }
        do {
            jobs = try jobStorage.load().map { job in
                var job = job
                if job.phase == .downloading || job.phase == .queued { job.phase = .paused; job.error = "上次下载中断，可继续。" }
                return job
            }
        } catch { jobsAvailable = false; storageError = "下载任务读取失败，原文件已保留。" }
    }

    func enqueue(route: PlannedRoute, bounds: MapBounds, zoom: Int, coverageRegions: [MapBounds]? = nil) {
        guard jobsAvailable else { storageError = "下载任务文件不可读取，请先恢复原文件。"; return }
        do {
            if let existing = jobs.first(where: { $0.route.id == route.id && $0.phase != .completed }) {
                guard existing.bounds == bounds, existing.zoom == zoom, existing.coverageRegions == coverageRegions else {
                    throw MapError.invalid("这条线路已有未完成下载，请先在地图管理中移除原任务，再更改区域。")
                }
                resume(existing.id); return
            }
            guard jobs.count < 20 else { throw MapError.invalid("最多保留 20 个下载任务，请先移除旧任务。") }
            let job = try MapDownloadJob(route: route, bounds: bounds, zoom: zoom, coverageRegions: coverageRegions)
            try jobStorage.save(jobs + [job])
            jobs.append(job)
            resume(job.id)
        } catch { errors[route.id] = error.localizedDescription }
    }

    func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].phase != .completed,
              activeJob != id, jobsAvailable else { return }
        jobs[index].phase = .queued; jobs[index].error = nil
        guard persistJobs() else { return }
        startNext()
    }

    @discardableResult private func persistJobs() -> Bool {
        do { try jobStorage.save(jobs); return true }
        catch { storageError = "下载进度无法保存，请检查手机存储空间。"; return false }
    }

    private func startNext() {
        guard activeJob == nil, let index = jobs.firstIndex(where: { $0.phase == .queued }) else { return }
        let job = jobs[index]
        guard let endpoint = URL(string: Self.endpointString), endpoint.scheme == "https" else {
            jobs[index].phase = .failed; jobs[index].error = "请先在设置中配置 OSM 数据服务地址。"; persistJobs(); return
        }
        activeJob = job.id; downloading.insert(job.route.id)
        jobs[index].phase = .downloading
        guard persistJobs() else { activeJob = nil; downloading.remove(job.route.id); return }
        tasks[job.route.id] = Task {
            defer {
                activeJob = nil; downloading.remove(job.route.id); tasks[job.route.id] = nil
                startNext()
            }
            do {
                let bundle = try await OSMRegionDownloader().download(job: job, endpoint: endpoint, storage: jobStorage) { completed, total, bytes in
                    try Task.checkCancellation()
                    guard let i = self.jobs.firstIndex(where: { $0.id == job.id }) else { throw CancellationError() }
                    self.jobs[i].completedTiles = completed; self.jobs[i].totalTiles = total; self.jobs[i].receivedBytes = bytes
                    guard self.persistJobs() else { throw MapError.invalid("进度保存失败。") }
                }
                try Task.checkCancellation()
                bundles[job.route.id] = try storage.save(bundle)
                if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].phase = .completed; jobs[i].error = nil }
                if persistJobs() { try? jobStorage.removeTiles(job.id) }
            } catch {
                if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[i].phase = Task.isCancelled ? .paused : .failed
                    jobs[i].error = Task.isCancelled ? nil : ((error as? MapError)?.localizedDescription ?? "地图下载失败，请检查网络后继续。")
                    persistJobs()
                }
            }
        }
    }

    func pause(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if activeJob == id { tasks[jobs[index].route.id]?.cancel() }
        else { jobs[index].phase = .paused; persistJobs() }
    }

    func removeJob(_ id: UUID) {
        guard activeJob != id else { storageError = "请先暂停任务，等待下载停止后再移除。"; return }
        let next = jobs.filter { $0.id != id }
        do { try jobStorage.save(next); jobs = next; try jobStorage.removeTiles(id) }
        catch { storageError = "无法移除下载任务。" }
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        for index in jobs.indices where jobs[index].route.id == id && jobs[index].phase == .queued { jobs[index].phase = .paused }
        persistJobs()
    }
    func isBusy(_ id: UUID) -> Bool {
        downloading.contains(id) || jobs.contains { $0.route.id == id && ($0.phase == .queued || $0.phase == .downloading) }
    }
    func remove(_ id: UUID) {
        guard !isBusy(id) else { errors[id] = "请先暂停下载，等待任务停止后再删除。"; storageError = errors[id]; return }
        do { try storage.remove(id); bundles[id] = nil; errors[id] = nil }
        catch { errors[id] = error.localizedDescription }
    }
}
