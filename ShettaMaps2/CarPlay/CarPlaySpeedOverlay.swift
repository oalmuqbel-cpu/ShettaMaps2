import SwiftUI
import CoreLocation
import Combine

/// سرعتك وحد السرعة على خريطة السيارة (مثل Waze وخرائط Google).
/// نفس فقاعة الهاتف ونفس قواعدها: سرعة حية فقط، وحد موثوق فقط، ولا يُخمَّن حد غير مسجل.
struct CarPlaySpeedOverlay: View {
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var limits = SpeedLimitStore.shared
    @AppStorage(SettingsKeys.showSpeed) private var showSpeed = true
    /// تحديث كل ثانية حتى تختفي السرعة القديمة عند انقطاع GPS.
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            if showSpeed {
                SpeedGauge(kmh: kmh, limit: limits.currentLimit, over: limits.isOver,
                           limitUnknown: limits.state.note != nil)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
        .onReceive(timer) { tick = $0 }
    }

    private var kmh: Double? {
        LiveSpeed.kmh(location.location, now: tick, recent: location.recentLocations)
    }
}

/// عداد سرعة دائري: قوس يمتلئ بسرعتك الحالية، وعلامة حمراء عند حد الشارع، والحد مكتوب أسفل العداد.
struct SpeedGauge: View {
    let kmh: Double?
    var limit: Int?
    var over = false
    var limitUnknown = false

    private let startAngle = 135.0, sweep = 270.0

    /// أعلى قيمة في العداد تتكيّف مع حد الشارع وسرعتك.
    private var scaleMax: Double {
        let base = max(Double(limit ?? 100) * 1.4, (kmh ?? 0) * 1.1, 80)
        return min(240, (base / 20).rounded(.up) * 20)
    }
    private var fraction: Double { min(1, max(0, (kmh ?? 0) / scaleMax)) }
    private var speedText: String { kmh.map { String(Int($0.rounded())) } ?? "—" }
    private var accent: Color { over ? .red : Color(red: 0.86, green: 0.55, blue: 0.27) }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let line = d * 0.075
            ZStack {
                Circle().fill(Color.black.opacity(0.72))
                Circle().stroke(over ? Color.red : Color.white.opacity(0.25), lineWidth: over ? d * 0.02 : 1)
                // المسار الكامل
                arc(1).stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .padding(line)
                // سرعتك الآن
                arc(fraction).stroke(accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .padding(line)
                    .animation(.easeOut(duration: 0.6), value: fraction)
                ticks(d: d, line: line)
                if let limit {
                    limitMarker(Double(limit), d: d, line: line)
                }
                VStack(spacing: d * 0.005) {
                    Text(verbatim: speedText)
                        .font(.system(size: d * 0.3, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(over ? Color.red : Color.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .frame(maxWidth: d * 0.56)
                    Text("كم/س").font(.system(size: d * 0.09, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.75))
                }
                .offset(y: -d * 0.07)
                limitBadge(d: d)
                    .offset(y: d * 0.32)
            }
            .frame(width: d, height: d)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(\.layoutDirection, .leftToRight)
        .animation(.easeInOut(duration: 0.25), value: over)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private func arc(_ f: Double) -> some Shape {
        GaugeArc(start: startAngle, sweep: sweep * f)
    }

    private func point(_ value: Double, radius r: Double, center c: CGPoint) -> CGPoint {
        let a = (startAngle + sweep * min(1, value / scaleMax)) * .pi / 180
        return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
    }

    private func ticks(d: Double, line: Double) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let rOut = d / 2 - line * 2.2, rIn = rOut - d * 0.04
            var v = 0.0
            while v <= scaleMax + 0.1 {
                var p = Path()
                p.move(to: point(v, radius: rIn, center: c))
                p.addLine(to: point(v, radius: rOut, center: c))
                ctx.stroke(p, with: .color(.white.opacity(0.55)), lineWidth: max(1, d * 0.012))
                v += 20
            }
        }
    }

    private func limitMarker(_ v: Double, d: Double, line: Double) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = d / 2 - line
            var p = Path()
            p.move(to: point(v, radius: r - line * 0.9, center: c))
            p.addLine(to: point(v, radius: r + line * 0.9, center: c))
            ctx.stroke(p, with: .color(.red), style: StrokeStyle(lineWidth: max(2, d * 0.03), lineCap: .round))
        }
    }

    @ViewBuilder private func limitBadge(d: Double) -> some View {
        let s = d * 0.25
        if let limit {
            Text(verbatim: String(limit))
                .font(.system(size: s * (limit >= 100 ? 0.36 : 0.44), weight: .heavy, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: s, height: s)
                .background(Circle().fill(.white))
                .overlay(Circle().stroke(Color.red, lineWidth: s * 0.13))
        } else if limitUnknown, (kmh ?? 0) > 5 {
            Text(verbatim: "—")
                .font(.system(size: s * 0.4, weight: .heavy))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: s, height: s)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: s * 0.08))
        }
    }

    private var accessibility: String {
        var s = kmh.map { "سرعتك \(Int($0.rounded())) كيلومتر في الساعة" } ?? "السرعة غير متاحة"
        if let limit { s += "، وحد الشارع \(limit)" }
        if over { s += "، تجاوزت الحد" }
        return s
    }
}

struct GaugeArc: Shape {
    var start: Double
    var sweep: Double
    var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard sweep > 0.01 else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(start), endAngle: .degrees(start + sweep), clockwise: false)
        return p
    }
}

/// إحداثيات موقعي الحالي أسفل خريطة السيارة، مختصرة وجاهزة للقراءة أو الإرسال لشخص آخر.
struct CarPlayCoordinateBar: View {
    static let key = "carPlayShowCoordinates"
    @ObservedObject private var location = LocationManager.shared
    @AppStorage(CarPlayCoordinateBar.key) private var show = true

    var body: some View {
        Group {
            if show, let c = location.location?.coordinate {
                Text(Self.text(c))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityLabel("موقعي \(Self.text(c))")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }

    /// خط العرض ثم خط الطول بخمس منازل عشرية (دقة نحو متر واحد)، بأرقام لاتينية.
    static func text(_ c: CLLocationCoordinate2D) -> String {
        let f = { (v: Double) in String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), v) }
        return "\(f(c.latitude)), \(f(c.longitude))"
    }
}
