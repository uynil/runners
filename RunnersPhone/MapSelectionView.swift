import SwiftUI

struct MapSelectionView: View {
    let route: PlannedRoute
    @EnvironmentObject private var maps: OfflineMapStore
    @Environment(\.dismiss) private var dismiss
    @State private var buffer = 500
    @State private var confirming = false
    @State private var customBounds: MapBounds?

    private var bounds: MapBounds? { customBounds ?? (try? MapBounds.around(route, bufferMeters: Double(buffer))) }
    private var viewport: MapBounds? {
        guard let base = try? MapBounds.around(route, bufferMeters: Double(buffer)) else { return nil }
        let dy = (base.north - base.south) * 0.25, dx = (base.east - base.west) * 0.25
        return MapBounds(south: base.south - dy, west: base.west - dx, north: base.north + dy, east: base.east + dx)
    }
    private var selectionValid: Bool { bounds.map { $0.isValid && $0.areaSquareKilometers <= 100 } ?? false }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    RouteShapeView(route: route, map: maps.bundles[route.id]?.map,
                        viewportBounds: viewport, selectionBounds: bounds)
                        .overlay {
                            if let viewport, let bounds, let minimum = try? MapBounds.around(route, bufferMeters: 100),
                               let latitude = route.segments.first?.first?.latitude {
                                MapBoundsHandles(bounds: Binding(get: { self.bounds ?? bounds }, set: { customBounds = $0 }),
                                                 viewport: viewport, minimum: minimum, latitude: latitude)
                            }
                        }.frame(height: 240)
                    Text("拖动蓝框四角调整范围，选区始终保留整条线路。尚未下载的区域只预览线路形状。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("范围与细节") {
                    Picker("线路周边", selection: $buffer) {
                        Text("500 米").tag(500); Text("1 公里").tag(1000); Text("2 公里").tag(2000)
                    }.pickerStyle(.segmented)
                    if let bounds, selectionValid {
                        LabeledContent("覆盖面积", value: String(format: "%.1f km²", bounds.areaSquareKilometers))
                        Text("下载所选区域完整路网；大小需下载后确认，单次响应上限 4 MB。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else { Text("范围超过 100 平方公里，请缩小范围。") .foregroundStyle(.red) }
                }
                Section("地图来源") {
                    Text("OpenStreetMap · 原始矢量路网")
                    Text("包含 OSM 已收录的道路、步道和水系；不包含完整地形等高线。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("下载到 iPhone") { confirming = true }.disabled(!selectionValid)
                }
            }
            .navigationTitle("选择地图范围").navigationBarTitleDisplayMode(.inline)
            .onChange(of: buffer) { _, _ in customBounds = nil }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .confirmationDialog("下载这个区域的地图？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认下载") {
                    if let bounds { maps.enqueue(route: route, bounds: bounds, zoom: 13); dismiss() }
                }
            } message: {
                Text("将所选区域边界发送至 OSM 数据服务（\(OfflineMapStore.endpointString)）获取路网，完整 GPX 不上传。中断后可重新下载。")
            }
        }
    }
}

private struct MapBoundsHandles: View {
    @Binding var bounds: MapBounds
    let viewport: MapBounds
    let minimum: MapBounds
    let latitude: Double

    var body: some View {
        GeometryReader { geometry in
            let cosine = max(0.01, cos(latitude * .pi / 180))
            let factor = min((geometry.size.width - 32) / ((viewport.east - viewport.west) * cosine),
                             (geometry.size.height - 32) / (viewport.north - viewport.south))
            let midLon = (viewport.west + viewport.east) / 2, midLat = (viewport.south + viewport.north) / 2
            ForEach(0..<4) { corner in
                let north = corner < 2, west = corner % 2 == 0
                let lon = west ? bounds.west : bounds.east, lat = north ? bounds.north : bounds.south
                Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 3)).frame(width: 18, height: 18)
                    .padding(9).contentShape(Rectangle())
                    .position(x: (lon - midLon) * cosine * factor + geometry.size.width / 2,
                              y: -(lat - midLat) * factor + geometry.size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("mapRegionSelection"))
                        .onChanged { value in
                            let lon = min(viewport.east, max(viewport.west, midLon + (value.location.x - geometry.size.width / 2) / (cosine * factor)))
                            let lat = min(viewport.north, max(viewport.south, midLat - (value.location.y - geometry.size.height / 2) / factor))
                            bounds = MapBounds(south: north ? bounds.south : min(lat, minimum.south),
                                               west: west ? min(lon, minimum.west) : bounds.west,
                                               north: north ? max(lat, minimum.north) : bounds.north,
                                               east: west ? bounds.east : max(lon, minimum.east))
                        })
                    .accessibilityLabel("调整下载区域\(north ? "北" : "南")\(west ? "西" : "东")角")
            }
        }.coordinateSpace(name: "mapRegionSelection")
    }
}
