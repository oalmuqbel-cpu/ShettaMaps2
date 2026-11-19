import Foundation
import CoreLocation
import Combine

/// مدى الوقود: يعرف المستخدم كم يمشي خزانه، ويضغط «عبّأت» عند التعبئة. نطرح المسافة المقطوعة،
/// وننبّه إذا صار أقرب محطة معروفة أبعد من المتبقي (بهامش طرق ترابية ٢٥٪ واحتياط ٢٠ كم).
@MainActor
final class FuelRangeMonitor: ObservableObject {
    static let shared = FuelRangeMonitor()

    enum Level: Equatable { case off, ok, low, critical }

    static let rangeKey = "fuelTankRangeKm"
    static let remainingKey = "fuelRemainingKm"
    static let roadFactor = 1.25
    static let reserveKm = 20.0

    @Published private(set) var remainingKm: Double?
    @Published private(set) var nearestFuel: (name: String, km: Double, coordinate: CLLocationCoordinate2D)?
    @Published private(set) var level: Level = .off

    private var last: CLLocation?
    private var lastNearestCheck = Date.distantPast
    private var cancellable: AnyCancellable?

    var tankRangeKm: Double {
        get { UserDefaults.standard.double(forKey: Self.rangeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.rangeKey); objectWillChange.send() }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Self.remainingKey) != nil {
            remainingKm = UserDefaults.standard.double(forKey: Self.remainingKey)
        }
        cancellable = LocationManager.shared.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.observe($0) }
    }

    /// عند التعبئة الكاملة.
    func filledUp() {
        guard tankRangeKm > 0 else { return }
        setRemaining(tankRangeKm)
    }

    func setRemaining(_ km: Double) {
        remainingKm = max(0, km)
        UserDefaults.standard.set(remainingKm, forKey: Self.remainingKey)
        lastNearestCheck = .distantPast
        if let l = last { evaluate(at: l.coordinate) }
    }

    func observe(_ loc: CLLocation) {
        guard tankRangeKm > 0, var remaining = remainingKm else { level = .off; return }
        defer { last = loc }
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 50 else { return }
        if let l = last, loc.speed > 2 {
            let d = loc.distance(from: l)
            // نتجاهل القفزات الشاذة
            if d < 2_000 {
                remaining = max(0, remaining - d / 1000)
                remainingKm = remaining
                UserDefaults.standard.set(remaining, forKey: Self.remainingKey)
            }
        }
        if Date().timeIntervalSince(lastNearestCheck) > 60 { evaluate(at: loc.coordinate) }
    }

    private func evaluate(at c: CLLocationCoordinate2D) {
        lastNearestCheck = Date()
        guard let remaining = remainingKm, tankRangeKm > 0 else { level = .off; return }
        if let (e, m) = SearchService.shared.nearest(.fuel, to: c, count: 1).first {
            nearestFuel = (e.name, m / 1000, .init(latitude: e.lat, longitude: e.lon))
        } else {
            nearestFuel = nil
        }
        level = Self.level(remainingKm: remaining, nearestKm: nearestFuel?.km)
    }

    /// المنطق (مختبر): حرج إذا لم يكفِ المتبقي للوصول، ومنخفض إذا لم يبقَ احتياط ٢٠ كم.
    nonisolated static func level(remainingKm: Double, nearestKm: Double?) -> Level {
        guard let n = nearestKm else { return remainingKm < 60 ? .low : .ok }
        let need = n * roadFactor
        if remainingKm < need { return .critical }
        if remainingKm < need + reserveKm { return .low }
        return .ok
    }
}
