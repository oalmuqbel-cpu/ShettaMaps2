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

/// بوصلة حقيقية: الإبرة الحمراء تشير دائمًا إلى الشمال، والمؤشر الثابت أعلى القرص يمثل اتجاه الجوال.
/// الدوران يُحسب بأقصر طريق (لا تلف دورة كاملة عند المرور بين 359° و0°)، والرسم من اليسار لليمين دائمًا.
struct CompassDial: View {
    let heading: Double?
    @State private var angle: Double

    init(heading: Double?) {
        self.heading = heading
        _angle = State(initialValue: -(heading ?? 0))
    }

    static let needleNorth = Color(red: 0.86, green: 0.12, blue: 0.10)

    var body: some View {
        ZStack {
            Circle().fill(Theme.beige)
            Circle().stroke(Theme.brown.opacity(0.5), lineWidth: 2)
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(Theme.brown.opacity(i % 3 == 0 ? 0.7 : 0.3))
                        .frame(width: 1.5, height: i % 3 == 0 ? 5 : 3)
                        .offset(y: -23)
                        .rotationEffect(.degrees(Double(i) * 30))
                }
                Text("ش").font(.system(size: 10, weight: .heavy)).foregroundStyle(Self.needleNorth).offset(y: -15)
                Text("ج").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.brown).offset(y: 15)
                Text("ق").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.brown).offset(x: 15)
                Text("غ").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.brown).offset(x: -15)
                CompassNeedle()
                    .frame(width: 8, height: 30)
                    .opacity(heading == nil ? 0.35 : 1)
            }
            .rotationEffect(.degrees(angle))
            // مؤشر اتجاه الجوال (ثابت أعلى القرص)
            Triangle().fill(Theme.desertOrange).frame(width: 8, height: 6).offset(y: -27)
        }
        .environment(\.layoutDirection, .leftToRight)
        .onChange(of: heading) { _, new in
            guard let h = new else { return }
            // أقصر فرق بين الزاوية الحالية والجديدة
            var delta = (-h - angle).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            withAnimation(.easeOut(duration: 0.2)) { angle += delta }
        }
        .accessibilityLabel(heading.map { "اتجاهك \(Fmt.bearing($0))، والإبرة الحمراء تشير إلى الشمال" } ?? "البوصلة غير متاحة")
    }
}

/// إبرة البوصلة: النصف الأحمر للشمال والرمادي للجنوب.
struct CompassNeedle: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Path { p in
                p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w, y: h / 2))
                p.addLine(to: CGPoint(x: 0, y: h / 2)); p.closeSubpath()
            }.fill(CompassDial.needleNorth)
            Path { p in
                p.move(to: CGPoint(x: 0, y: h / 2)); p.addLine(to: CGPoint(x: w, y: h / 2))
                p.addLine(to: CGPoint(x: w / 2, y: h)); p.closeSubpath()
            }.fill(Color.gray.opacity(0.7))
            Circle().fill(.white).frame(width: 3, height: 3).position(x: w / 2, y: h / 2)
        }
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.closeSubpath()
        }
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
                        .environment(\.layoutDirection, .leftToRight)
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


/// سرعتك الحالية بالكيلومتر في الساعة مع لوحة حد السرعة إن عُرف؛ تصير حمراء عند التجاوز.
struct SpeedBubble: View {
    let speedMS: Double
    var limit: Int?
    var over = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: -2) {
                Text("\(Int((speedMS * 3.6).rounded()))")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(over ? Color.white : Color.primary)
                Text("كم/س").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(over ? Color.white.opacity(0.9) : Color.secondary)
            }
            .frame(width: 62, height: 62)
            .background(Circle().fill(over ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial)))
            .overlay(Circle().stroke(over ? Color.red : Theme.brown.opacity(0.35), lineWidth: over ? 3 : 1.5))
            .shadow(color: over ? .red.opacity(0.5) : .black.opacity(0.15), radius: over ? 8 : 4, y: 1)
            if let limit {
                SpeedLimitSign(limit: limit)
                    .offset(x: -16, y: -16)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .animation(.easeInOut(duration: 0.25), value: over)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var s = "سرعتك \(Int((speedMS * 3.6).rounded())) كيلومتر في الساعة"
        if let limit { s += "، والحد \(limit)" }
        if over { s += "، تجاوزت الحد" }
        return s
    }
}

/// لوحة حد السرعة (دائرة بإطار أحمر).
struct SpeedLimitSign: View {
    let limit: Int
    var body: some View {
        Text("\(limit)")
            .font(.system(size: limit >= 100 ? 13 : 15, weight: .heavy, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: 36, height: 36)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(Color.red, lineWidth: 4))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}
