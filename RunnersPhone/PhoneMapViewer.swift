import SwiftUI

struct PhoneMapViewer: View {
    let route: PlannedRoute
    let map: OfflineMap
    @State private var zoom: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                RouteShapeView(route: route, map: map)
                    .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Button("缩小", systemImage: "minus.magnifyingglass") { zoom = max(1, zoom / 2) }
                        .disabled(zoom == 1)
                    Text("\(Int(zoom))×").monospacedDigit()
                    Button("放大", systemImage: "plus.magnifyingglass") { zoom = min(8, zoom * 2) }
                        .disabled(zoom == 8)
                }.buttonStyle(.bordered).padding(8).background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            MapAttributionView(map: map).padding(8)
        }
        .navigationTitle(route.name).navigationBarTitleDisplayMode(.inline)
    }
}
