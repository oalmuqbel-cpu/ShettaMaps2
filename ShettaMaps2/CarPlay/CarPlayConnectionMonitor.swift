import Foundation

/// يتتبع حالة اتصال CarPlay ويحتفظ بسجل أحداث لشاشة الاختبار في الإعدادات.
@MainActor
final class CarPlayConnectionMonitor: ObservableObject {
    static let shared = CarPlayConnectionMonitor()

    struct Event: Identifiable {
        let id = UUID()
        let date = Date()
        let text: String
    }

    @Published private(set) var isConnected = false
    @Published private(set) var isDashboardConnected = false
    @Published private(set) var isInstrumentClusterConnected = false
    @Published private(set) var events: [Event] = []
    @Published private(set) var connectionCount = 0

    private init() {}

    func carPlayConnected() {
        isConnected = true
        connectionCount += 1
        log("اتصال CarPlay")
    }

    func carPlayDisconnected() {
        isConnected = false
        log("انقطاع CarPlay — تستمر الملاحة والتسجيل على الهاتف")
    }

    func setDashboard(_ connected: Bool) {
        isDashboardConnected = connected
        log(connected ? "اتصال لوحة CarPlay (Dashboard)" : "انقطاع لوحة CarPlay")
    }

    func setInstrumentCluster(_ connected: Bool) {
        isInstrumentClusterConnected = connected
        log(connected ? "اتصال شاشة العدادات" : "انقطاع شاشة العدادات")
    }

    func log(_ text: String) {
        events.insert(Event(text: text), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
        appLog.info("CarPlay: \(text, privacy: .public)")
    }
}
