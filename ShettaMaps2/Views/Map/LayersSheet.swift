import SwiftUI

/// لوحة الطبقات والأدوات: نوع الخريطة، ما يُعرض فوقها، وأدوات سريعة.
/// لوحة مستقلة (بدل قائمة منسدلة) حتى لا تتحرك أثناء التمرير مع تحديثات الموقع.
struct LayersSheet: View {
    @ObservedObject var mapManager: MapManager
    let communityEnabled: Bool
    let safeTripActive: Bool
    let followingCount: Int
    var convoyActive: Bool = false
    /// ينفذ إجراء بعد إغلاق اللوحة.
    let perform: (LayersAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.showLandmarks) private var showLandmarks = true
    @AppStorage(SettingsKeys.showCommunity) private var showCommunity = true
    @AppStorage(SettingsKeys.showDirtRoads) private var showDirtRoads = true
    @AppStorage(SettingsKeys.showDetectedRoads) private var showDetectedRoads = true
    @AppStorage(SettingsKeys.showRainMap) private var showRainMap = false
    @AppStorage(SettingsKeys.showReserves) private var showReserves = true
    @AppStorage(SettingsKeys.showWind) private var showWind = true
    @AppStorage(SettingsKeys.showCoverage) private var showCoverage = false
    @AppStorage(SettingsKeys.coverageOnlyMine) private var coverageOnlyMine = true
    @AppStorage(SettingsKeys.showMyTracks) private var showMyTracks = false
    @AppStorage(SettingsKeys.showSpeed) private var showSpeed = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("نوع الخريطة") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 10)], spacing: 10) {
                            ForEach(MapLayer.allCases) { l in
                                Button { mapManager.layer = l } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: l.icon).font(.title2)
                                        Text(l.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                                            .lineLimit(2).minimumScaleFactor(0.8)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 72)
                                    .foregroundStyle(mapManager.layer == l ? Color.white : Theme.brown)
                                    .background(RoundedRectangle(cornerRadius: 14)
                                        .fill(mapManager.layer == l ? AnyShapeStyle(Theme.desertOrange) : AnyShapeStyle(Color(.secondarySystemBackground))))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(mapManager.layer == l ? .isSelected : [])
                            }
                        }
                    }

                    section("على الخريطة") {
                        VStack(spacing: 0) {
                            row("أسماء الأماكن المعروفة", "mappin.circle", $showLandmarks)
                            if communityEnabled { row("مشاركات المجتمع", "person.2", $showCommunity) }
                            row("الردميات والطرق الترابية", "road.lanes", $showDirtRoads)
                            if showDirtRoads { row("طرق مرصودة من الأقمار الصناعية", "globe.asia.australia", $showDetectedRoads, indent: true) }
                            row("مساراتي السابقة", "point.topleft.down.to.point.bottomright.curvepath", $showMyTracks)
                            row("المحميات", "leaf", $showReserves)
                        }
                        .card()
                    }

                    section("الطقس والشبكة") {
                        VStack(spacing: 0) {
                            row("الأمطار والأجواء", "cloud.rain", $showRainMap)
                            row("الرياح", "wind", $showWind)
                            row("تغطية الشبكة", "antenna.radiowaves.left.and.right", $showCoverage)
                            if showCoverage { row("شركتي فقط", "simcard", $coverageOnlyMine, indent: true) }
                            row("سرعتي وحد السرعة", "speedometer", $showSpeed)
                        }
                        .card()
                    }

                    section("أدوات") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            tool("الطقس", "cloud.sun", .weather)
                            tool("أقرب محطة وقود", "fuelpump", .fuel)
                            tool(safeTripActive ? "الرحلة الآمنة (مفعلة)" : "الرحلة الآمنة", "shield.lefthalf.filled", .safeTrip,
                                 highlight: safeTripActive)
                            tool(followingCount > 0 ? "أتابعهم (\(followingCount))" : "أتابعهم", "person.2.wave.2", .following)
                            tool(convoyActive ? "القافلة (مفعلة)" : "القافلة", "car.2", .convoy, highlight: convoyActive)
                            tool("الطوارئ وإنجاد", "sos", .emergency, tint: .red)
                            tool("إرسال موقعي برسالة", "message", .sendLocation)
                            tool("بلّغ عن الشبكة هنا", "exclamationmark.bubble", .reportCoverage)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("الطبقات والأدوات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            content()
        }
    }

    private func row(_ title: String, _ icon: String, _ on: Binding<Bool>, indent: Bool = false) -> some View {
        Toggle(isOn: on) {
            Label(title, systemImage: icon).font(indent ? .subheadline : .body)
        }
        .tint(Theme.desertOrange)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .padding(.leading, indent ? 18 : 0)
    }

    private func tool(_ title: String, _ icon: String, _ action: LayersAction, tint: Color = Theme.desertOrange,
                      highlight: Bool = false) -> some View {
        Button {
            dismiss()
            perform(action)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(highlight ? Color.white : tint).frame(width: 26)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(highlight ? Color.white : Color.primary)
                    .lineLimit(2).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 14).fill(highlight ? AnyShapeStyle(Color.green) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))))
        }
        .buttonStyle(.plain)
    }
}

enum LayersAction {
    case weather, fuel, safeTrip, following, convoy, emergency, sendLocation, reportCoverage
}

private extension View {
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }
}
