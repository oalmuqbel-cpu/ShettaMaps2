import SwiftUI
import Charts

/// رسم مقطع الارتفاع: المسافة أفقيًا والارتفاع رأسيًا، مع إمكانية السحب لقراءة نقطة.
struct ElevationChart: View {
    let profile: ElevationProfile
    @State private var picked: ElevationProfile.Sample?

    private var lowerBound: Double {
        let span = max(20, profile.maxAltitude - profile.minAltitude)
        return (profile.minAltitude - span * 0.15).rounded(.down)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                stat("صعود", Fmt.altitude(profile.gain), "arrow.up.right")
                stat("نزول", Fmt.altitude(profile.loss), "arrow.down.right")
                Spacer()
                if let p = picked {
                    Text("\(Fmt.distance(p.distance)) · \(Fmt.altitude(p.altitude))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Chart(profile.samples) { s in
                AreaMark(x: .value("المسافة", s.distance / 1000),
                         yStart: .value("الأساس", lowerBound),
                         yEnd: .value("الارتفاع", s.altitude))
                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("المسافة", s.distance / 1000), y: .value("الارتفاع", s.altitude))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                if let p = picked, p == s {
                    RuleMark(x: .value("المسافة", p.distance / 1000)).foregroundStyle(.secondary.opacity(0.6))
                    PointMark(x: .value("المسافة", p.distance / 1000), y: .value("الارتفاع", p.altitude))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .chartYScale(domain: lowerBound...(profile.maxAltitude + 5))
            .chartXAxisLabel("كم", alignment: .trailing)
            .chartYAxisLabel("م")
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard let plot = proxy.plotFrame else { return }
                                let x = v.location.x - geo[plot].origin.x
                                guard let km: Double = proxy.value(atX: x) else { return }
                                picked = profile.samples.min { abs($0.distance - km * 1000) < abs($1.distance - km * 1000) }
                            }
                            .onEnded { _ in picked = nil })
                }
            }
            .frame(height: 160)
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityLabel("مقطع الارتفاع: من \(Fmt.altitude(profile.minAltitude)) إلى \(Fmt.altitude(profile.maxAltitude))")
        }
        .padding(.vertical, 4)
    }

    private func stat(_ title: String, _ value: String, _ icon: String) -> some View {
        Label { Text("\(title) \(value)").font(.subheadline.monospacedDigit()) } icon: {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
    }
}
