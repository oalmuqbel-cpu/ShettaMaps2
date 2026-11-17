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
                    .padding(.top, 16).padding(.leading, 16) // مساحة لإشارة الحد فوق الفقاعة
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
