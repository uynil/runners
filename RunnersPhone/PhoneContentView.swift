import SwiftUI

struct PhoneContentView: View {
    @EnvironmentObject private var store: PhoneStore
    @EnvironmentObject private var watch: WatchConnection
    @EnvironmentObject private var strava: StravaStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var importing = false
    @State private var reading = false
    @State private var candidates: [PlannedRoute] = []
    @State private var choosing = false
    @State private var linkedMapRoute: PlannedRoute?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                RouteListView(importing: $importing, reading: reading)
            }.tabItem { Label("线路", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }.tag(0)
            NavigationStack {
                ActivityHistoryView()
            }.tabItem { Label("运动", systemImage: "figure.run") }.tag(1)
            NavigationStack { WatchManagementView() }
                .tabItem { Label("Watch", systemImage: "applewatch") }.tag(2)
            NavigationStack { PhoneSettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
            NavigationStack { MapManagementView() }
                .tabItem { Label("地图", systemImage: "map") }.tag(4)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: PhoneStore.importTypes) { result in
            switch result {
            case .success(let url): read(url)
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .onOpenURL { url in
            if url.scheme == "runners", url.host == "maps" {
                guard !reading, !choosing else { return }
                tab = 4
                if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "route" })?.value,
                   let id = UUID(uuidString: raw), let route = store.routes.first(where: { $0.id == id }) {
                    linkedMapRoute = route
                }
                return
            }
            guard url.isFileURL else { return }
            guard !reading, !choosing else { store.error = "请先完成当前导入，再打开其他文件。"; return }
            tab = 0
            read(url)
        }
        .sheet(isPresented: $choosing) {
            ImportSelectionView(routes: candidates) { selected in
                store.save(store.routes + selected)
            }
        }
        .sheet(item: $linkedMapRoute) { route in MapSelectionView(route: route) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { watch.refresh(); strava.resume() } else { strava.suspend() }
        }
    }

    private func read(_ url: URL) {
        guard store.libraryAvailable else { store.reload(); return }
        reading = true
        Task {
            defer { reading = false }
            do {
                candidates = try await Task.detached(priority: .userInitiated) { try PhoneStore.readFile(url) }.value
                choosing = true
            } catch { store.error = error.localizedDescription }
        }
    }
}

private struct RouteListView: View {
    @EnvironmentObject private var store: PhoneStore
    @EnvironmentObject private var maps: OfflineMapStore
    @Binding var importing: Bool
    let reading: Bool
    @State private var query = ""
    @State private var favoritesOnly = false

    private var filtered: [PlannedRoute] {
        store.routes.filter { (!favoritesOnly || $0.isFavorite) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.importedAt > $1.importedAt }
    }
    var body: some View {
        List {
            Section {
                Toggle("只看收藏", isOn: $favoritesOnly)
            }
            if reading { ProgressView("正在读取线路…") }
            if !store.libraryAvailable {
                Button("重新读取线路库") { store.reload() }
            }
            ForEach(filtered) { route in
                NavigationLink {
                    RouteDetailView(id: route.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(route.name).font(.headline)
                            if route.isFavorite { Image(systemName: "star.fill").foregroundStyle(.orange) }
                        }
                        Text("\(route.distanceMeters / 1_000, specifier: "%.2f") km · \(route.segments.count) 段")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(maps.bundles[route.id] == nil ? "线路已保存 · 地图未下载" : "线路与地图已保存在手机")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }
        .overlay {
            if filtered.isEmpty && !reading && store.libraryAvailable {
                ContentUnavailableView(query.isEmpty && !favoritesOnly ? "添加你的第一条线路" : "没有匹配的线路",
                    systemImage: "map", description: Text("从文件导入 GPX 或 KML，查看线路并保存在手机。"))
                    .allowsHitTesting(false).padding(.top, 50)
            }
        }
        .searchable(text: $query, prompt: "搜索线路")
        .navigationTitle("线路")
        .toolbar {
            Button { importing = true } label: { Label("导入线路", systemImage: "plus") }
                .disabled(reading || !store.libraryAvailable)
        }
    }
}

private struct ImportSelectionView: View {
    let routes: [PlannedRoute]
    let save: ([PlannedRoute]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<UUID>()

    var body: some View {
        NavigationStack {
            List {
                Section("选择要保存的线路") {
                    ForEach(routes) { route in
                        Button {
                            if selected.contains(route.id) { selected.remove(route.id) } else { selected.insert(route.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(route.name).foregroundStyle(.primary)
                                    Text("\(route.distanceMeters / 1_000, specifier: "%.2f") km · \(route.segments.count) 段")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selected.contains(route.id) ? "checkmark.circle.fill" : "circle")
                            }
                        }.accessibilityAddTraits(selected.contains(route.id) ? .isSelected : [])
                    }
                }
                Section { Text("文件中的线路独立保存，分段间不连线。此操作只保存到手机。") }
            }
            .navigationTitle("导入线路")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存 \(selected.count) 条") { save(routes.filter { selected.contains($0.id) }); dismiss() }
                        .disabled(selected.isEmpty)
                }
            }
            .onAppear { if routes.count == 1 { selected = Set(routes.map(\.id)) } }
        }
    }
}

private struct RouteDetailView: View {
    let id: UUID
    @EnvironmentObject private var store: PhoneStore
    @EnvironmentObject private var maps: OfflineMapStore
    @EnvironmentObject private var watch: WatchConnection
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var newName = ""
    @State private var deleting = false
    @State private var confirmDownload = false
    @State private var confirmMapDelete = false

    var body: some View {
        if let route = store.routes.first(where: { $0.id == id }) {
            List {
                Section {
                    RouteShapeView(route: route, map: maps.bundles[id]?.map).frame(height: 260)
                    if maps.bundles[id] != nil {
                        if let map = maps.bundles[id]?.map { MapAttributionView(map: map) }
                        Text("离线矢量底图 · 道路 / 步道 / 水系").font(.caption).foregroundStyle(.secondary)
                        if let map = maps.bundles[id]?.map {
                            NavigationLink("查看大图与缩放") { PhoneMapViewer(route: route, map: map) }
                        }
                    } else { Text("线路形状预览 · 无底图").font(.caption).foregroundStyle(.secondary) }
                }
                Section("线路信息") {
                    LabeledContent("距离", value: String(format: "%.2f km", route.distanceMeters / 1_000))
                    LabeledContent("分段", value: "\(route.segments.count)")
                    LabeledContent("位置点", value: "\(route.pointCount)")
                    LabeledContent("来源文件", value: route.sourceName)
                    LabeledContent("爬升", value: "暂无有效数据")
                    LabeledContent("导航方向", value: route.isReversed == true ? "反向" : "原始方向")
                    Button("反转导航方向", systemImage: "arrow.left.arrow.right") {
                        var updated = route
                        updated.reverseDirection()
                        store.update(updated)
                    }
                    .disabled(maps.isBusy(id))
                }
                Section {
                    Label("线路已保存在手机", systemImage: "checkmark.circle")
                    if let bundle = maps.bundles[id] {
                        Label("地图已保存到手机，断网可用", systemImage: "checkmark.circle.fill")
                        LabeledContent("下载时间") { Text(bundle.map.downloadedAt, style: .date) }
                        LabeledContent("地图范围", value: bundle.map.coverageDescription)
                        LabeledContent("地图要素", value: "\(bundle.map.features.count)")
                        let packet = RouteMapBundle(route: route, map: bundle.map)
                        Text(watch.status(for: packet)).font(.caption)
                        Button("发送线路和地图到 Watch") { watch.send(packet) }
                            .disabled(!watch.activated || !watch.paired || !watch.installed)
                    }
                    if maps.isBusy(id) {
                        ProgressView("正在下载地图…")
                        Button("取消下载", role: .cancel) { maps.cancel(id) }
                    } else {
                        Button(maps.bundles[id] == nil ? "选择区域并下载地图" : "更新地图区域") { confirmDownload = true }
                    }
                    NavigationLink("打开地图下载管理") { MapManagementView() }
                    if let error = maps.errors[id] { Text(error).foregroundStyle(.red).font(.caption) }
                    if let error = maps.storageError { Text(error).foregroundStyle(.red).font(.caption) }
                    if let error = watch.error { Text(error).foregroundStyle(.red).font(.caption) }
                    if let map = maps.bundles[id]?.map {
                        NavigationLink("路网检查与路口核验（\((route.cues ?? []).filter(\.confirmed).count) 已核验）") {
                            RouteCueReviewView(routeID: id, map: map)
                        }
                    } else { Label("下载地图后可准备路口提示", systemImage: "arrow.triangle.turn.up.right.diamond") }
                    if maps.bundles[id] != nil {
                        Button("删除手机离线地图", role: .destructive) { confirmMapDelete = true }
                            .disabled(maps.isBusy(id))
                    }
                } header: { Text("准备到 Watch") } footer: {
                    Text("下载线路范围及约 500 米缓冲的道路、步道和水系。数据疏密取决于 OpenStreetMap，可能缺少山地步道；地图保存不代表路口导航已就绪。")
                }
                Section {
                    Button(route.isFavorite ? "取消收藏" : "收藏线路", systemImage: route.isFavorite ? "star.slash" : "star") {
                        var updated = route; updated.isFavorite.toggle(); store.update(updated)
                    }
                    Button("重命名", systemImage: "pencil") { newName = route.name; renaming = true }
                    Button("删除手机线路", systemImage: "trash", role: .destructive) { deleting = true }
                        .disabled(maps.isBusy(id))
                }
            }
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $confirmDownload) { MapSelectionView(route: route) }
            .confirmationDialog("删除手机离线地图？", isPresented: $confirmMapDelete, titleVisibility: .visible) {
                Button("删除手机地图", role: .destructive) { maps.remove(id) }
            } message: { Text("此线路的手机地图将移除，Watch 上已接收的副本不受影响。") }
            .alert("重命名线路", isPresented: $renaming) {
                TextField("线路名称", text: $newName)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    var updated = route
                    updated.name = String(newName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
                    store.update(updated)
                }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .confirmationDialog("删除手机上的这条线路？运动历史和 Watch 内容不受影响。", isPresented: $deleting, titleVisibility: .visible) {
                Button("删除手机线路", role: .destructive) {
                    store.save(store.routes.filter { $0.id != id })
                    if !store.routes.contains(where: { $0.id == id }) {
                        if maps.bundles[id] != nil { maps.remove(id) }
                        dismiss()
                    }
                }
            }
        } else { ContentUnavailableView("线路已移除", systemImage: "map") }
    }
}

private struct WatchManagementView: View {
    @EnvironmentObject private var watch: WatchConnection
    var body: some View {
        List {
            Section {
                LabeledContent("配对", value: watch.activated ? (watch.paired ? "已配对" : "未配对") : "尚未读取")
                LabeledContent("Runners App", value: watch.activated && watch.paired ? (watch.installed ? "已安装" : "未安装") : "未知")
                LabeledContent("即时通信", value: watch.activated ? (watch.reachable ? "当前可用" : "当前不可用") : "未知")
                if let date = watch.checkedAt {
                    LabeledContent("本机状态检查") { Text(date, style: .time) }
                }
                Button("刷新状态", systemImage: "arrow.clockwise") { watch.refresh() }
                if let error = watch.error { Text(error).foregroundStyle(.red) }
            } header: { Text("当前 Watch") } footer: { Text("即时通信不可用不代表未配对，也不代表后台传输不可用。") }
            Section("连接指引") {
                Text("在 iPhone 的 Watch App 中配对手表，并安装 Runners。保持蓝牙和 Wi-Fi 开启。")
            }
            Section {
                if let report = watch.storageReport {
                    LabeledContent("地图占用", value: ByteCountFormatter.string(fromByteCount: report.mapBytes, countStyle: .file))
                    LabeledContent("表端可用空间", value: report.availableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知")
                    LabeledContent("报告时间") { Text(report.reportedAt, style: .relative) }
                } else { LabeledContent("可用空间", value: "尚无表端报告") }
                LabeledContent("表端已确认地图包", value: "\(watch.receipts.count)")
                ForEach(Array(watch.receipts.values).sorted { $0.receivedAt > $1.receivedAt }, id: \.routeID) { receipt in
                    VStack(alignment: .leading) {
                        Text("地图包 \(receipt.routeID.uuidString.prefix(8))").font(.caption)
                        Text(receipt.receivedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("表端存储与内容") } footer: { Text("清单和空间来自 Watch 最近一次报告，断连时可能过时。地图占用不包含运动记录。") }
        }
        .navigationTitle("Watch")
        .onAppear { watch.refresh() }
    }
}

private struct PhoneSettingsView: View {
    @EnvironmentObject private var watch: WatchConnection
    @AppStorage("mapEndpoint") private var mapEndpoint = OfflineMapStore.endpointString
    var body: some View {
        List {
            Section("当前版本") {
                LabeledContent("距离单位", value: "公里")
                Toggle("路口震动", isOn: Binding(get: { watch.navigationSettings.junctionHaptics },
                                                 set: { watch.updateNavigationSettings(junctionHaptics: $0) }))
                Toggle("偏航震动", isOn: Binding(get: { watch.navigationSettings.offRouteHaptics },
                                                 set: { watch.updateNavigationSettings(offRouteHaptics: $0) }))
                LabeledContent("Watch 导航设置", value: watch.navigationSettingsStatus)
                NavigationLink("Strava 连接与上传") { StravaSettingsView() }
            }
            Section("数据与权限") {
                Text("导入线路保存在此 iPhone 的 App 数据中，不会自动上传。删除手机线路不删除运动历史或其他平台记录。")
                Text("运动定位和心率权限在 Watch 开始运动时申请。")
            }
            Section("地图下载服务") {
                Text("OpenStreetMap 原始路网数据")
                TextField("Overpass HTTPS 服务地址", text: $mapEndpoint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("无需 API Key。开发版可手动下载小范围数据；正式发布需配置自建或容量合适的 OSM 数据服务。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("单次区域下载中断后重新请求；完整响应校验保存后可离线使用。OSM 原始路网不包含完整地形等高线。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("OpenStreetMap 数据许可", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            }
            Section("开发进度") {
                Text("可保存离线矢量底图并排队发送到 Watch。完整路口提醒仍在开发；运动记录可回传手机，后台传输需要真机验证。")
            }
        }.navigationTitle("设置")
    }
}
