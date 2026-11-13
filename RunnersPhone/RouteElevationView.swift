import SwiftUI

struct RouteElevationView: View {
    let profile: RouteElevationProfile

    var body: some View {
        LabeledContent("累计爬升", value: "\(Int(profile.ascentMeters.rounded())) 米")
        LabeledContent("累计下降", value: "\(Int(profile.descentMeters.rounded())) 米")
        VStack(alignment: .leading, spacing: 8) {
            Text("海拔剖面").font(.subheadline.bold())
            Canvas { context, size in
                let low = profile.minimumMeters - 1
                let range = profile.maximumMeters - profile.minimumMeters + 2
                func position(_ point: RouteElevationProfile.Sample) -> CGPoint {
                    CGPoint(x: size.width * point.distanceMeters / profile.distanceMeters,
                            y: size.height * (1 - (point.elevationMeters - low) / range))
                }
                var path = Path()
                for segment in profile.segments {
                    guard let start = segment.first else { continue }
                    path.move(to: position(start))
                    for point in segment.dropFirst() { path.addLine(to: position(point)) }
                }
                context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            .frame(height: 92)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("海拔剖面，\(Int(profile.minimumMeters.rounded())) 至 \(Int(profile.maximumMeters.rounded())) 米")
            HStack {
                Text("0 km")
                Spacer()
                Text(String(format: "%.2f km", profile.distanceMeters / 1_000))
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(profile.coverage >= 0.999
                 ? "按线路文件中的海拔计算。"
                 : "仅统计有连续海拔的路段（\(Int((profile.coverage * 100).rounded(.down)))%）；缺测处断开。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
