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
        Group {
            if showSpeed {
                SpeedBubble(speedMS: speedMS, limit: limits.currentLimit, over: limits.isOver,
                            limitNote: limits.state.note)
                    .scaleEffect(1.2, anchor: .topTrailing)  // أكبر قليلًا في شاشة السيارة
                    .padding(.top, 18).padding(.leading, 18) // مساحة لإشارة الحد فوق الفقاعة
            }
        }
        // حجم ثابت ملتصق بأعلى يمين المساحة، فلا تنزاح الفقاعة لوسط الشاشة
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .onReceive(timer) { tick = $0 }
    }

    private var speedMS: Double? {
        guard let kmh = LiveSpeed.kmh(location.location, now: tick) else { return nil }
        return kmh > 4.3 ? kmh / 3.6 : 0
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
