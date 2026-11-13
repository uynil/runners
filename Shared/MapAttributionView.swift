import SwiftUI

struct MapAttributionView: View {
    let map: OfflineMap
    var body: some View {
        HStack(spacing: 4) {
            if map.provider == "thunderforest" {
                Link("© Thunderforest", destination: URL(string: "https://www.thunderforest.com")!)
            }
            Link("© OpenStreetMap · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
        }.font(.caption2)
    }
}
