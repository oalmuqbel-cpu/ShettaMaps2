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
    @State private var showQibla = false

    private var format: CoordinateFormat { CoordinateFormat(rawValue: formatRaw) ?? .decimal }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s) {
            HStack(alignment: .center, spacing: DS.m) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showQibla.toggle() } } label: {
                    // القرص مرسوم بمقاس ٥٤ ثم يُصغَّر لمقاس الأزرار الموحد
                    CompassDial(heading: location.currentHeadingDegrees, qibla: qiblaBearing)
                        .frame(width: 54, height: 54)
                        .scaleEffect(DS.control / 54)
                        .frame(width: DS.control, height: DS.control)
                }
                .buttonStyle(.plain)
                .accessibilityHint("اضغط لعرض اتجاه القبلة")

                VStack(alignment: .leading, spacing: 3) {
                    if let loc = location.location {
                        Text(CoordinateUtilities.format(loc.coordinate, as: format))
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .environment(\.layoutDirection, .leftToRight)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .onTapGesture { cycleFormat() }
                            .onLongPressGesture {
                                UIPasteboard.general.string = CoordinateUtilities.shareString(loc.coordinate)
                                copied = true
                            }
                            .accessibilityHint("اضغط لتغيير الصيغة، واضغط مطولًا للنسخ")
                        HStack(spacing: DS.m) {
                            Label(Fmt.accuracy(loc.horizontalAccuracy), systemImage: "scope")
                                .foregroundStyle(Theme.accuracyColor(loc.horizontalAccuracy))
                            Label(Fmt.altitude(loc.verticalAccuracy >= 0 ? loc.altitude : nil), systemImage: "mountain.2")
                            if let h = location.currentHeadingDegrees {
                                Label(Fmt.bearing(h), systemImage: "location.north")
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    } else if let last = location.lastKnownCoordinate {
                        Text("آخر موقع معروف: " + CoordinateUtilities.format(last.0, as: .decimal))
                            .font(.footnote)
                        Text(Fmt.dateTime.string(from: last.1)).font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("جارٍ تحديد الموقع…").font(.footnote)
                    }
                }
                Spacer(minLength: 0)
                // حالة الاتصال والخريطة: أيقونات صغيرة بدل نصوص، والتفاصيل لقارئ الشاشة
                VStack(spacing: 6) {
                    statusIcon(network.isOnline ? "wifi" : "wifi.slash", color: network.isOnline ? .green : .orange,
                               label: network.isOnline ? "متصل بالإنترنت" : "دون اتصال")
                    if let c = location.location?.coordinate {
                        let covered = offlineMaps.hasOfflineCoverage(at: c)
                        statusIcon(covered ? "map.fill" : "map", color: covered ? .green : .secondary,
                                   label: covered ? "الخريطة محملة لهذه المنطقة" : "الخريطة غير محملة لهذه المنطقة")
                    }
                    if carPlay.isConnected {
                        statusIcon("car.fill", color: Theme.desertOrange, label: "متصل بـ CarPlay")
                    }
                }
            }
            if showQibla, let q = qiblaInfo {
                HStack(spacing: DS.s) {
                    KaabaMark().frame(width: 12, height: 12)
                    Text("القبلة \(Fmt.bearing(q.bearing))").font(.footnote.weight(.semibold))
                    Text("· مكة المكرمة على بعد \(Fmt.distance(q.distance))").font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .transition(.opacity)
            }
        }
        .hudCard()
        .alert("تم نسخ الإحداثيات", isPresented: $copied) { Button("حسنًا", role: .cancel) {} }
    }

    private var qiblaBearing: Double? { location.location.map { Qibla.bearing(from: $0.coordinate) } }

    private var qiblaInfo: (bearing: Double, distance: Double)? {
        guard let c = location.location?.coordinate else { return nil }
        return (Qibla.bearing(from: c), Qibla.distance(from: c))
    }

    private func statusIcon(_ name: String, color: Color, label: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 22, height: 18)
            .accessibilityLabel(label)
    }

    private func cycleFormat() {
        let all = CoordinateFormat.allCases
        let i = all.firstIndex(of: format) ?? 0
        formatRaw = all[(i + 1) % all.count].rawValue
    }
}

/// اتجاه القبلة: الدائرة العظمى من الموقع إلى الكعبة المشرفة، بالنسبة للشمال الحقيقي.
enum Qibla {
    static let kaaba = CLLocationCoordinate2D(latitude: 21.422487, longitude: 39.826206)
    static func bearing(from c: CLLocationCoordinate2D) -> Double { GeoMath.bearing(from: c, to: kaaba) }
    static func distance(from c: CLLocationCoordinate2D) -> Double { GeoMath.distance(c, kaaba) }
}

/// رمز الكعبة الصغير: مربع داكن بحزام ذهبي.
struct KaabaMark: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: w * 0.12).fill(Color(white: 0.12))
                Rectangle().fill(Color(red: 0.85, green: 0.68, blue: 0.25)).frame(height: max(1.5, w * 0.16)).offset(y: w * 0.24)
            }
        }
        .accessibilityHidden(true)
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
    /// اتجاه القبلة (درجات من الشمال الحقيقي)، يظهر علامة الكعبة على إطار البوصلة.
    var qibla: Double? = nil
    @State private var angle: Double

    init(heading: Double?, qibla: Double? = nil) {
        self.heading = heading
        self.qibla = qibla
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
                // علامة القبلة على الإطار: تدور مع القرص فتشير دائمًا لاتجاه الكعبة الفعلي
                if let q = qibla {
                    KaabaMark()
                        .frame(width: 8, height: 8)
                        .offset(y: -20)
                        .rotationEffect(.degrees(q))
                }
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
    @EnvironmentObject private var navigation: SharedNavigationState
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
            // العودة على نفس المسار المسجل حتى بدايته
            Button {
                let coords = recorder.liveSegments.flatMap { $0 }
                if let plan = TrackBack.plan(coordinates: coords, current: LocationManager.shared.location?.coordinate, name: "المسار") {
                    navigation.start(plan)
                }
            } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.bordered)
                .disabled(recorder.liveSegments.flatMap { $0 }.count < 2 || navigation.snapshot.isNavigating)
                .accessibilityLabel("ارجع من نفس الطريق")
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
    /// nil: لا توجد قراءة سرعة موثوقة الآن.
    let speedMS: Double?
    var limit: Int?
    var over = false
    /// سبب عدم معرفة الحد (لا يُخمَّن حد غير مسجل).
    var limitNote: String? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: -2) {
                Text(speedMS.map { "\(Int(($0 * 3.6).rounded()))" } ?? "—")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(over ? Color.white : Color.primary)
                Text("كم/س").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(over ? Color.white.opacity(0.9) : Color.secondary)
            }
            .frame(width: DS.control + 4, height: DS.control + 4)
            .background(Circle().fill(over ? AnyShapeStyle(Color.red) : AnyShapeStyle(.regularMaterial)))
            .overlay(Circle().stroke(over ? Color.red : Theme.brown.opacity(0.35), lineWidth: over ? 3 : 1.5))
            .shadow(color: over ? .red.opacity(0.5) : .black.opacity(0.15), radius: over ? 8 : 4, y: 1)
            if let limit {
                SpeedLimitSign(limit: limit)
                    .offset(x: -14, y: -14)
            } else if limitNote != nil, let v = speedMS, v > 1.5 {
                // حد غير معروف أثناء السير فقط: إشارة رمادية بلا رقم بدل تخمين حد
                UnknownLimitSign()
                    .offset(x: -14, y: -14)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .animation(.easeInOut(duration: 0.25), value: over)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        var s = speedMS.map { "سرعتك \(Int(($0 * 3.6).rounded())) كيلومتر في الساعة" } ?? "السرعة غير متاحة"
        if let limit { s += "، والحد \(limit)" } else if let limitNote { s += "، \(limitNote)" }
        if over { s += "، تجاوزت الحد" }
        return s
    }
}

/// حد السرعة غير معروف أو غير موثوق.
struct UnknownLimitSign: View {
    var body: some View {
        Text("—")
            .font(.system(size: 15, weight: .heavy, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(.regularMaterial))
            .overlay(Circle().stroke(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 2.5, dash: [3, 2])))
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

/// بطاقة المكان أسفل الخريطة (بدل نافذة الخيارات): الاسم والمسافة والإحداثيات، وأهم الإجراءات أزرارًا،
/// وبقيتها في «المزيد». تعمل بنفس الشكل على الجوال والآيباد.
struct PlaceCard: View {
    struct Action: Identifiable {
        let id: String
        let title: String
        let icon: String
        var role: ButtonRole? = nil
        let run: () -> Void
    }

    let title: String
    var subtitle: String?
    var detail: String?
    let coordinateText: String
    let primary: [Action]
    var more: [Action] = []
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.m) {
            HStack(alignment: .top, spacing: DS.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).lineLimit(2)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: DS.s) {
                        if let detail { Text(detail).font(.footnote.weight(.semibold)) }
                        Text(coordinateText)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("إغلاق")
            }
            HStack(spacing: DS.s) {
                ForEach(Array(primary.enumerated()), id: \.element.id) { i, a in
                    Button(action: a.run) {
                        VStack(spacing: 4) {
                            Image(systemName: a.icon).font(DS.iconFont)
                            Text(a.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(i == 0 ? Color.white : Theme.brown)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(i == 0 ? AnyShapeStyle(Theme.desertOrange) : AnyShapeStyle(Theme.sand)))
                    }
                    .buttonStyle(.plain)
                }
                if !more.isEmpty {
                    Menu {
                        ForEach(more) { a in
                            Button(role: a.role, action: a.run) { Label(a.title, systemImage: a.icon) }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "ellipsis").font(DS.iconFont)
                            Text("المزيد").font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(Theme.brown)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.sand))
                    }
                }
            }
        }
        .hudCard(padding: DS.m)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
