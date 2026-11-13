import SwiftUI

struct MapManagementView: View {
    @EnvironmentObject private var maps: OfflineMapStore
    @EnvironmentObject private var store: PhoneStore
    @EnvironmentObject private var watch: WatchConnection
    @State private var selection: PlannedRoute?
    @State private var deletingMap: UUID?
    @State private var deletingJob: UUID?
    @State private var deletingWatch: UUID?

    private var usedBytes: Int64 {
        maps.bundles.keys.reduce(0) { total, id in total + Int64((try? maps.storage.fileURL(id).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    var body: some View {
        List {
            Section {
                #if targetEnvironment(simulator)
                Text("模拟器前台分块同步 · 请同时打开两端 App；后台文件传输需真机验证。")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                LabeledContent("手机地图占用", value: ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                LabeledContent("已保存", value: "\(maps.bundles.count) / 20 个地图包")
                LabeledContent("未完成下载", value: ByteCountFormatter.string(fromByteCount: (try? maps.jobStorage.stagingBytes()) ?? 0, countStyle: .file))
                if let error = maps.storageError { Text(error).foregroundStyle(.red) }
                if let error = watch.error { Text(error).foregroundStyle(.red) }
            }
            if !maps.jobs.isEmpty {
                Section("下载任务") {
                    ForEach(maps.jobs.sorted { $0.createdAt > $1.createdAt }) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(job.route.name).font(.headline)
                            HStack {
                                Text(job.phase.title)
                                Spacer()
                                Text("\(job.completedTiles) / \(job.totalTiles) 区域").monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                            if job.phase == .downloading { ProgressView("正在获取区域数据…") }
                            else { ProgressView(value: Double(job.completedTiles), total: Double(max(1, job.totalTiles))) }
                            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                            HStack {
                                if job.phase == .downloading || job.phase == .queued {
                                    Button("暂停") { maps.pause(job.id) }
                                } else if job.phase != .completed {
                                    Button(job.phase == .failed ? "重试" : "继续") { maps.resume(job.id) }
                                }
                                Spacer()
                                Button("移除任务", role: .destructive) { deletingJob = job.id }
                                    .disabled(job.phase == .downloading)
                            }.buttonStyle(.bordered).font(.caption)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section("已下载地图") {
                if maps.bundles.isEmpty { Text("从线路选择区域并下载，之后可同步到 Watch。") }
                ForEach(Array(maps.bundles.values).sorted { $0.map.downloadedAt > $1.map.downloadedAt }) { bundle in
                    let packet = RouteMapBundle(route: store.routes.first(where: { $0.id == bundle.id }) ?? bundle.route, map: bundle.map)
                    VStack(alignment: .leading, spacing: 8) {
                        NavigationLink(bundle.route.name) { PhoneMapViewer(route: bundle.route, map: bundle.map) }
                            .font(.headline)
                        Text("\(bundle.map.provider == "thunderforest" ? "Thunderforest Outdoors" : "OSM") · \(bundle.map.coverageDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(watch.status(for: packet)).font(.caption)
                            if let fraction = watch.progress(for: bundle.id) {
                                ProgressView(value: fraction)
                            }
                        }
                        HStack {
                            Button("同步到 Watch") { watch.send(packet) }
                                .disabled(!watch.activated || !watch.paired || !watch.installed)
                            Button("取消传输") { watch.cancelTransfer(bundle.id) }
                                .disabled(!watch.hasTransfer(bundle.id))
                        }.buttonStyle(.bordered).font(.caption)
                        HStack {
                            Button("更新地图") { selection = store.routes.first(where: { $0.id == bundle.id }) ?? bundle.route }
                            Button("删除手机地图", role: .destructive) { deletingMap = bundle.id }
                        }.font(.caption)
                        if watch.receipts[bundle.id] != nil {
                            Button("从 Watch 移除", role: .destructive) { deletingWatch = bundle.id }.font(.caption)
                        }
                        if let message = watch.removals[bundle.id] { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 6)
                }
            }
        }
        .navigationTitle("离线地图")
        .toolbar {
            Menu {
                if store.routes.isEmpty { Text("请先导入线路") }
                ForEach(store.routes) { route in Button(route.name) { selection = route } }
            } label: { Label("添加地图", systemImage: "plus") }
        }
        .sheet(item: $selection) { route in MapSelectionView(route: route) }
        .confirmationDialog("删除手机地图？Watch 副本不受影响。", isPresented: Binding(get: { deletingMap != nil }, set: { if !$0 { deletingMap = nil } }), titleVisibility: .visible) {
            Button("删除手机地图", role: .destructive) { if let id = deletingMap { maps.remove(id) }; deletingMap = nil }
        }
        .confirmationDialog("从 Watch 移除地图？手机副本保留，手表运动期间会延后执行。", isPresented: Binding(get: { deletingWatch != nil }, set: { if !$0 { deletingWatch = nil } }), titleVisibility: .visible) {
            Button("从 Watch 移除", role: .destructive) { if let id = deletingWatch { watch.removeFromWatch(id) }; deletingWatch = nil }
        }
        .confirmationDialog("移除下载任务和已下载的临时数据？已保存的完整地图不受影响。", isPresented: Binding(get: { deletingJob != nil }, set: { if !$0 { deletingJob = nil } }), titleVisibility: .visible) {
            Button("移除下载任务", role: .destructive) { if let id = deletingJob { maps.removeJob(id) }; deletingJob = nil }
        }
    }
}
