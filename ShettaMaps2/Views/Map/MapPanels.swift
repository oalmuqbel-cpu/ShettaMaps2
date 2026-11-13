import SwiftUI
import CoreLocation

/// لوحة الحالة العلوية: الإحداثيات، الدقة، البوصلة، الارتفاع، الاتصال، وتوفر الخرائط دون إنترنت.
struct StatusHUD: View {
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var offlineMaps: OfflineMapManager
    @EnvironmentObject private var carPlay: CarPlayConnectionMonitor
    @AppStorage(SettingsKeys.coordinateFormat) private var formatRaw = CoordinateFormat.decimal.rawValue
    @State private var copied = false

    private var format: CoordinateFormat { CoordinateFormat(rawValue: formatRaw) ?? .decimal }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CompassDial(heading: location.currentHeadingDegrees)
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                if let loc = location.location {
                    Text(CoordinateUtilities.format(loc.coordinate, as: format))
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        .environment(\.layoutDirection, .leftToRight)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .onTapGesture { cycleFormat() }
                        .onLongPressGesture {
                            UIPasteboard.general.string = CoordinateUtilities.shareString(loc.coordinate)
                            copied = true
                        }
                        .accessibilityHint("اضغط لتغيير الصيغة، واضغط مطولًا للنسخ")
                    HStack(spacing: 10) {
                        Label(Fmt.accuracy(loc.horizontalAccuracy), systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(Theme.accuracyColor(loc.horizontalAccuracy))
                        Label(Fmt.altitude(loc.verticalAccuracy >= 0 ? loc.altitude : nil), systemImage: "arrow.up.and.down")
                        if let h = location.currentHeadingDegrees {
                            Label(Fmt.bearing(h), systemImage: "safari")
                        }
                    }
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                } else if let last = location.lastKnownCoordinate {
                    Text("آخر موقع معروف: " + CoordinateUtilities.format(last.0, as: .decimal))
                        .font(.footnote)
                    Text(Fmt.dateTime.string(from: last.1)).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("جارٍ تحديد الموقع…").font(.footnote)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                StatusChip(icon: network.isOnline ? "wifi" : "wifi.slash",
                           text: network.isOnline ? "متصل" : "دون اتصال",
                           color: network.isOnline ? .green : .orange)
                if let c = location.location?.coordinate {
                    let covered = offlineMaps.hasOfflineCoverage(at: c)
                    StatusChip(icon: covered ? "checkmark.circle" : "xmark.circle",
                               text: covered ? "خريطة محملة" : "غير محملة",
                               color: covered ? .green : .gray)
                }
                if carPlay.isConnected {
                    StatusChip(icon: "car", text: "CarPlay", color: Theme.desertOrange)
                }
            }
        }
        .hudCard()
        .alert("تم نسخ الإحداثيات", isPresented: $copied) { Button("حسنًا", role: .cancel) {} }
    }

    private func cycleFormat() {
        let all = CoordinateFormat.allCases
        let i = all.firstIndex(of: format) ?? 0
        formatRaw = all[(i + 1) % all.count].rawValue
    }
}

struct StatusChip: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }
}

/// بوصلة تدور حسب اتجاه الجهاز.
struct CompassDial: View {
    let heading: Double?

    var body: some View {
        ZStack {
            Circle().fill(Theme.beige)
            Circle().stroke(Theme.brown.opacity(0.5), lineWidth: 2)
            Group {
                Text("ش").font(.caption2.bold()).offset(y: -18)
                Text("ج").font(.caption2).offset(y: 18)
                Text("ق").font(.caption2).offset(x: 18)
                Text("غ").font(.caption2).offset(x: -18)
            }
            .foregroundStyle(Theme.brown)
            .environment(\.layoutDirection, .leftToRight)
            .rotationEffect(.degrees(-(heading ?? 0)))
            Image(systemName: "location.north.fill")
                .foregroundStyle(heading == nil ? .gray : Theme.desertOrange)
                .font(.system(size: 16, weight: .bold))
        }
        .animation(.easeOut(duration: 0.25), value: heading)
        .accessibilityLabel(heading.map { "الاتجاه \(Fmt.bearing($0))" } ?? "البوصلة غير متاحة")
    }
}

/// لوحة الملاحة النشطة: المسافة والاتجاه والتعليمة.
struct NavigationPanel: View {
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager

    var body: some View {
        let s = navigation.snapshot
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let rel = s.progress?.relativeBearing {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Theme.desertOrange)
                        .rotationEffect(.degrees(rel))
                        .frame(width: 48)
                } else {
                    Image(systemName: "flag.checkered").font(.title).foregroundStyle(Theme.desertOrange).frame(width: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.status == .arrived ? "وصلت إلى الوجهة" : s.instruction)
                        .font(.headline)
                        .lineLimit(2)
                    if let p = s.progress {
                        HStack(spacing: 12) {
                            Text("إلى الهدف: \(Fmt.distance(p.distanceToTarget))")
                            Text("الاتجاه: \(Fmt.bearing(p.bearingToTarget))")
                        }
                        .font(.caption)
                        HStack(spacing: 12) {
                            Text("المتبقي: \(Fmt.distance(p.remainingDistance))")
                            if let eta = p.estimatedSeconds { Text("الوقت المقدر: \(Fmt.duration(eta))") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let n = s.notice {
                Text(n).font(.caption2).foregroundStyle(.orange)
            }
            HStack {
                if let plan = s.plan, plan.targets.count > 1, s.progress?.isFinalTarget == false {
                    Button("تخطي النقطة") { navigation.skipToNextTarget() }
                }
                if let plan = s.plan {
                    Menu(plan.mode == .direct ? "خط مباشر" : "طريق") {
                        Button("خط مباشر (إرشاد جغرافي)") { navigation.setMode(.direct) }
                        Button("طريق معبد عند توفره (يتطلب إنترنت)") { navigation.setMode(.road) }
                    }
                    Button("عرض المسار") {
                        mapManager.send(.fit(plan.allPoints.map(\.coordinate)))
                    }
                }
                Spacer()
                Button("إنهاء", role: .destructive) { navigation.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .hudCard()
    }
}

/// لوحة التسجيل النشط.
struct RecordingPanel: View {
    @EnvironmentObject private var recorder: RouteRecordingManager
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(recorder.state == .recording ? Color.red : Color.orange)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(recorder.isAutoPaused ? "متوقف تلقائيًا — يكمل عند الحركة" : recorder.state.title).font(.caption.weight(.semibold))
                HStack(spacing: 10) {
                    Text(Fmt.distance(recorder.distance))
                    Text(Fmt.duration(recorder.elapsed))
                    Text(Fmt.speed(recorder.currentSpeed))
                }
                .font(.system(.footnote, design: .rounded).monospacedDigit())
            }
            Spacer()
            Button {
                recorder.state == .recording ? recorder.pause() : recorder.resume()
            } label: {
                Image(systemName: recorder.state == .recording ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(recorder.state == .recording ? "إيقاف مؤقت" : "استئناف")
            Button(action: onStop) { Image(systemName: "stop.fill") }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityLabel("إنهاء التسجيل")
        }
        .hudCard()
    }
}

/// الشريط السفلي للإجراءات الرئيسية.
struct ActionBar: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var recorder: RouteRecordingManager
    let onRecordTap: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ActionTile(systemImage: "mappin.and.ellipse", title: "حفظ الموقع") {
                if let c = location.location?.coordinate { router.mapSheet = .savePlace(c) }
            }
            .disabled(location.location == nil)
            ActionTile(systemImage: recordIcon, title: recordTitle, tint: recorder.isActive ? .red : Theme.desertOrange,
                       action: onRecordTap)
            ActionTile(systemImage: "magnifyingglass", title: "البحث") { router.mapSheet = .search }
            ActionTile(systemImage: "number", title: "الإحداثيات") { router.mapSheet = .coordinates }
            ActionTile(systemImage: "arrow.down.circle", title: "الخرائط") { router.mapSheet = .offlineMaps }
            ActionTile(systemImage: "clock.arrow.circlepath", title: "الرحلات") { router.mapSheet = .trips }
        }
        .padding(.vertical, 6)
        .hudCard()
    }

    private var recordIcon: String {
        switch recorder.state {
        case .idle: return "record.circle"
        case .recording: return "pause.circle"
        case .paused: return "play.circle"
        }
    }

    private var recordTitle: String {
        switch recorder.state {
        case .idle: return "تسجيل مسار"
        case .recording: return "إيقاف مؤقت"
        case .paused: return "استئناف"
        }
    }
}
