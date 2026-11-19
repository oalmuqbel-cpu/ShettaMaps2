import Foundation
import CoreLocation
import Combine
import SwiftData
import UserNotifications

/// تنبيه الاقتراب: عند الوصول لمسافة محددة من مكان محفوظ أو مورد ماء معروف،
/// يظهر شريط في الخريطة ويُقرأ صوتيًا، ويصل إشعار إن كان التطبيق في الخلفية.
@MainActor
final class ProximityAlerts: ObservableObject {
    static let shared = ProximityAlerts()

    static let savedKey = "proximity.saved"
    static let waterKey = "proximity.water"
    static let radiusKey = "proximity.radiusM"
    static let cooldown: TimeInterval = 12 * 3600

    struct Candidate: Equatable {
        var id: String
        var name: String
        var kind: String          // «مكان محفوظ» أو «ماء»
        var coordinate: CLLocationCoordinate2D
        static func == (a: Candidate, b: Candidate) -> Bool { a.id == b.id }
    }

    @Published private(set) var current: (candidate: Candidate, meters: Double)?

    private var candidates: [Candidate] = []
    private var candidatesCenter: CLLocation?
    private var candidatesAt = Date.distantPast
    private var alerted: [String: Date] = [:]
    private var primed = false
    private var cancellable: AnyCancellable?

    static var radius: Double {
        let v = UserDefaults.standard.double(forKey: radiusKey)
        return v > 0 ? v : 1000
    }
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: savedKey) || UserDefaults.standard.bool(forKey: waterKey)
    }

    private init() {
        cancellable = LocationManager.shared.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.observe($0) }
    }

    func dismiss() { current = nil }

    func observe(_ loc: CLLocation) {
        guard Self.enabled, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        if candidatesCenter.map({ $0.distance(from: loc) > 3_000 }) ?? true || Date().timeIntervalSince(candidatesAt) > 600 {
            reloadCandidates(around: loc)
        }
        let radius = Self.radius
        // أول تقييم بعد التشغيل: لا ننبّه عن أماكن نحن فيها أصلًا (البيت مثلًا)
        if !primed {
            primed = true
            for c in candidates where GeoMath.distance(c.coordinate, loc.coordinate) <= radius { alerted[c.id] = Date() }
            return
        }
        guard let hit = Self.due(candidates, at: loc.coordinate, radius: radius, alerted: alerted, now: Date()) else { return }
        alerted[hit.0.id] = Date()
        current = (hit.0, hit.1)
        let text = "\(hit.0.name) على بعد \(Fmt.distance(hit.1))"
        if VoicePrompter.enabled { VoicePrompter.shared.speak(text, tone: true) }
        notify(title: "اقتربت من \(hit.0.kind)", body: text, id: "proximity-\(hit.0.id)")
    }

    /// أقرب مكان داخل النطاق لم يُنبَّه عنه خلال فترة التهدئة.
    nonisolated static func due(_ list: [Candidate], at c: CLLocationCoordinate2D, radius: Double,
                                alerted: [String: Date], now: Date) -> (Candidate, Double)? {
        var best: (Candidate, Double)?
        for x in list {
            if let t = alerted[x.id], now.timeIntervalSince(t) < cooldown { continue }
            let d = GeoMath.distance(c, x.coordinate)
            guard d <= radius else { continue }
            if best == nil || d < best!.1 { best = (x, d) }
        }
        return best
    }

    private func reloadCandidates(around loc: CLLocation) {
        candidatesCenter = loc
        candidatesAt = Date()
        var list: [Candidate] = []
        let d = UserDefaults.standard
        if d.bool(forKey: Self.savedKey) {
            let places = (try? AppEnvironment.shared.container.mainContext.fetch(FetchDescriptor<SavedPlace>())) ?? []
            for p in places {
                let c = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
                guard GeoMath.distance(c, loc.coordinate) < 20_000 else { continue }
                list.append(.init(id: "saved-\(p.id.uuidString)", name: p.name, kind: "مكان محفوظ", coordinate: c))
            }
        }
        if d.bool(forKey: Self.waterKey) {
            let span = 0.2
            let sw = CLLocationCoordinate2D(latitude: loc.coordinate.latitude - span, longitude: loc.coordinate.longitude - span)
            let ne = CLLocationCoordinate2D(latitude: loc.coordinate.latitude + span, longitude: loc.coordinate.longitude + span)
            for e in SearchService.shared.entries(sw: sw, ne: ne, limit: 200, kinds: [.water, .coldWater]) {
                list.append(.init(id: "gz-\(e.id)", name: e.name, kind: "ماء",
                                  coordinate: .init(latitude: e.lat, longitude: e.lon)))
            }
        }
        candidates = list
    }

    private func notify(title: String, body: String, id: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }
}
