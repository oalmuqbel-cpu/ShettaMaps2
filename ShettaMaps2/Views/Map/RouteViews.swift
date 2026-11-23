import SwiftUI
import CoreLocation

/// اختيار الطريق قبل الانطلاق (مثل Google Maps): طرق السيارة البديلة أو الخط المباشر.
struct RoutePreviewPanel: View {
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var location: LocationManager
    @ObservedObject private var graphs = RouteGraphStore.shared
    let preview: RoutePreview

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.destination.name).font(.headline).lineLimit(1)
                    if let here = location.location?.coordinate {
                        Text("بخط مستقيم \(Fmt.distance(GeoMath.distance(here, preview.destination.coordinate)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { navigation.cancelPreview() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).frame(width: 32, height: 32)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("إغلاق")
            }

            if preview.loading {
                HStack(spacing: 8) { ProgressView(); Text("جارٍ حساب طرق السيارة…").font(.subheadline).foregroundStyle(.secondary) }
            } else if !preview.routes.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(preview.routes.enumerated()), id: \.offset) { i, r in
                        routeRow(r, index: i, selected: i == preview.selected)
                    }
                }
            } else if let e = preview.error {
                Text(e).font(.footnote).foregroundStyle(.orange)
                if let rid = preview.suggestedRegion {
                    downloadRow(rid)
                }
            }

            HStack(spacing: DS.s) {
                if preview.selectedRoute != nil {
                    Button { start(.road) } label: {
                        Label("ابدأ", systemImage: "car.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.route)
                }
                Button { start(.direct) } label: {
                    Label("خط مباشر", systemImage: "location.north.line").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        }
        .padding(DS.m)
        .floatingSurface()
        .onAppear(perform: fit)
        .onChange(of: preview.routes.count) { _, _ in fit() }
    }

    private func routeRow(_ r: RoadRoute, index: Int, selected: Bool) -> some View {
        Button { navigation.selectPreviewRoute(index); } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Fmt.tripDuration(r.expectedTravelTime)).font(.title3.weight(.bold))
                            .foregroundStyle(selected ? Theme.route : .primary)
                        if index == 0, preview.routes.count > 1 {
                            Text("الأسرع").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green)
                        }
                    }
                    Text([Fmt.distance(r.distance), r.name.isEmpty ? nil : "عبر \(r.name)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.route : .secondary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.route.opacity(0.08) : Color(.secondarySystemBackground)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func downloadRow(_ rid: String) -> some View {
        let title = RegionPackService.shared.manifest?.regions.first { $0.id == rid }?.title ?? rid
        if let p = graphs.progress[rid] {
            ProgressView(value: p) { Text("تنزيل طرق \(title)").font(.caption) }
        } else {
            Button {
                Task {
                    if graphs.manifest == nil { await graphs.loadManifest() }
                    graphs.download(rid)
                }
            } label: { Label("تنزيل طرق الملاحة: \(title)", systemImage: "arrow.down.circle") }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func start(_ mode: GuidanceMode) {
        navigation.startFromPreview(mode: mode)
        mapManager.send(.followCourse)
    }

    private func fit() {
        var pts = preview.routes.flatMap(\.coordinates)
        if pts.isEmpty {
            pts = [preview.destination.coordinate]
            if let here = location.location?.coordinate { pts.append(here) }
        }
        mapManager.send(.fit(pts))
        // مرة ثانية بعد استقرار الخريطة (أول أمر قد يصل قبل جاهزيتها)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { mapManager.send(.fit(pts)) }
    }
}

/// أيقونة المناورة حسب زاوية الانعطاف.
enum ManeuverIcon {
    static func symbol(_ step: RoadStep?) -> String {
        guard let step else { return "arrow.up" }
        let text = step.instruction
        if text.contains("الدوار") { return "arrow.triangle.turn.up.right.circle" }
        guard let a = step.turnAngle else { return "flag.checkered" }
        switch a {
        case 145...: return "arrow.uturn.down"
        case 55..<145: return "arrow.turn.up.right"
        case 20..<55: return "arrow.up.right"
        case -55 ... -20: return "arrow.up.left"
        case -145 ..< -55: return "arrow.turn.up.left"
        case ..<(-145): return "arrow.uturn.down"
        default: return "arrow.up"
        }
    }
}

/// لافتة المنعطف القادم أعلى الشاشة أثناء القيادة على الطريق (مثل Waze وGoogle Maps).
struct ManeuverBanner: View {
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var location: LocationManager

    var body: some View {
        let s = navigation.snapshot
        let step = s.currentRoadStep
        let next = s.roadRoute.flatMap { r in r.steps.indices.contains(s.roadStepIndex + 1) ? r.steps[s.roadStepIndex + 1] : nil }
        let d = step.flatMap { st in location.location.map { GeoMath.distance($0.coordinate, st.endCoordinate) } }
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: s.status == .arrived ? "flag.checkered" : ManeuverIcon.symbol(step))
                    .font(.system(size: 40, weight: .bold))
                    .frame(width: 56)
                    .environment(\.layoutDirection, .leftToRight)
                VStack(alignment: .leading, spacing: 2) {
                    if let d, s.status != .arrived {
                        Text(Fmt.distance(d)).font(.system(size: 28, weight: .heavy, design: .rounded)).monospacedDigit()
                    }
                    Text(s.status == .arrived ? "وصلت إلى الوجهة" : (step?.instruction ?? s.instruction))
                        .font(.headline).lineLimit(2).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.m).padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(Color(red: 0.05, green: 0.42, blue: 0.30))
            if let next, s.status != .arrived {
                HStack(spacing: 8) {
                    Text("ثم").font(.caption.weight(.semibold))
                    Image(systemName: ManeuverIcon.symbol(next)).environment(\.layoutDirection, .leftToRight)
                    Text(next.instruction).font(.caption).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, DS.m).padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Color(red: 0.03, green: 0.32, blue: 0.23))
            }
            if let n = s.notice {
                Text(n).font(.caption2).foregroundStyle(.orange).padding(6).frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }
}

/// شريط الرحلة أسفل الشاشة أثناء القيادة: وقت الوصول والمتبقي والإنهاء.
struct RoadTripBar: View {
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager

    var body: some View {
        let s = navigation.snapshot
        HStack(spacing: DS.m) {
            Button(role: .destructive) { navigation.stop() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 46, height: 46)
                    .background(Circle().fill(Color.red.opacity(0.15))).foregroundStyle(.red)
            }
            .accessibilityLabel("إنهاء الملاحة")
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                if let eta = s.progress?.estimatedSeconds {
                    Text(Date().addingTimeInterval(eta), style: .time).font(.title2.weight(.bold)).foregroundStyle(.green)
                    Text("\(Fmt.tripDuration(eta)) · \(Fmt.distance(s.progress?.remainingDistance ?? 0))")
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                } else if let p = s.progress {
                    Text(Fmt.distance(p.remainingDistance)).font(.title2.weight(.bold))
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button { mapManager.send(.fit(s.roadRoute?.coordinates ?? [])) } label: { Label("عرض الطريق كاملًا", systemImage: "map") }
                Button { mapManager.send(.followCourse) } label: { Label("تتبع موقعي", systemImage: "location.north.line") }
                Button { navigation.setMode(.direct) } label: { Label("التحويل للخط المباشر", systemImage: "location.north.line.fill") }
            } label: {
                Image(systemName: "ellipsis").font(.headline).frame(width: 46, height: 46)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .accessibilityLabel("خيارات")
        }
        .padding(.horizontal, DS.m).padding(.vertical, 10)
        .floatingSurface()
    }
}
