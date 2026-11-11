import Foundation
import CoreLocation
import Combine
import UIKit

/// أوضاع استهلاك البطارية أثناء التتبع.
enum BatteryMode: String, CaseIterable, Identifiable {
    case precise, balanced, saver
    var id: String { rawValue }
    var title: String {
        switch self {
        case .precise: return "دقة عالية"
        case .balanced: return "متوازن"
        case .saver: return "توفير البطارية"
        }
    }
    var detail: String {
        switch self {
        case .precise: return "أفضل دقة وتحديث كل 5 أمتار تقريبًا. الأعلى استهلاكًا."
        case .balanced: return "دقة جيدة وتحديث كل 15 مترًا تقريبًا. مناسب لمعظم الرحلات."
        case .saver: return "تحديث كل 50 مترًا تقريبًا. المسار المسجّل أقل تفصيلًا."
        }
    }
    var desiredAccuracy: CLLocationAccuracy {
        switch self {
        case .precise: return kCLLocationAccuracyBestForNavigation
        case .balanced: return kCLLocationAccuracyBest
        case .saver: return kCLLocationAccuracyNearestTenMeters
        }
    }
    var distanceFilter: CLLocationDistance {
        switch self {
        case .precise: return 5
        case .balanced: return 15
        case .saver: return 50
        }
    }
}

/// حالة جودة إشارة تحديد الموقع.
enum GPSQuality: Equatable {
    case unavailable, weak, fair, good
    var title: String {
        switch self {
        case .unavailable: return "لا توجد إشارة"
        case .weak: return "إشارة ضعيفة"
        case .fair: return "إشارة متوسطة"
        case .good: return "إشارة جيدة"
        }
    }
}

/// مدير الموقع المشترك بين الآيفون/الآيباد وCarPlay.
/// يستخدم CoreLocation فقط: إشارات أنظمة الملاحة بالأقمار الصناعية (GPS وغيرها) تُستقبل عبر شريحة الجهاز،
/// ولا يملك التطبيق وصولًا إلى عدد الأقمار أو أي اتصال فضائي.
@MainActor
final class LocationManager: NSObject, ObservableObject {
    static let shared = LocationManager()

    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isFullAccuracy: Bool = true
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var lastError: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var backgroundEnabled = false

    /// يبث كل تحديث موقع مقبول لمكوّنات أخرى (التسجيل، الملاحة، CarPlay).
    let locationPublisher = PassthroughSubject<CLLocation, Never>()

    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var backgroundReasons = Set<String>()
    private var lastKnownKey = "lastKnownLocation"

    var weakThreshold: Double {
        let v = UserDefaults.standard.double(forKey: SettingsKeys.weakGPSThreshold)
        return v > 0 ? v : 50
    }

    var batteryMode: BatteryMode {
        BatteryMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.batteryMode) ?? "") ?? .balanced
    }

    private override init() {
        super.init()
        authorization = manager.authorizationStatus
        isFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 2
        applyBatteryMode()
    }

    // MARK: - الأذونات

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// يطلب إذن "دائمًا" لاستمرار التسجيل في الخلفية؛ لا يُطلب إلا بعد منح "أثناء الاستخدام".
    func requestAlwaysIfNeeded() {
        if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    func requestFullAccuracyIfNeeded() {
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Navigation")
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - التشغيل

    func start() {
        if authorization == .notDetermined { requestWhenInUse(); return }
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        isUpdating = true
    }

    func stop() {
        guard backgroundReasons.isEmpty else { return } // لا نوقف التحديثات أثناء تسجيل أو ملاحة
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        isUpdating = false
    }

    func applyBatteryMode() {
        let mode = batteryMode
        manager.desiredAccuracy = mode.desiredAccuracy
        manager.distanceFilter = mode.distanceFilter
    }

    /// يُستخدم عند الاتصال بـ CarPlay لتحسين تقدير اتجاه السيارة.
    func setAutomotive(_ automotive: Bool) {
        manager.activityType = automotive ? .automotiveNavigation : .otherNavigation
    }

    /// يفعّل الاستمرار في الخلفية لسبب محدد (تسجيل، ملاحة، CarPlay). يعود للوضع العادي بعد زوال كل الأسباب.
    func beginBackgroundUpdates(reason: String) {
        backgroundReasons.insert(reason)
        guard isAuthorized else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        if backgroundSession == nil {
            // iOS 17: يحافظ على صلاحية "أثناء الاستخدام" في الخلفية مع إظهار مؤشر للمستخدم.
            backgroundSession = CLBackgroundActivitySession()
        }
        backgroundEnabled = true
        if !isUpdating { start() }
    }

    func endBackgroundUpdates(reason: String) {
        backgroundReasons.remove(reason)
        guard backgroundReasons.isEmpty else { return }
        backgroundSession?.invalidate()
        backgroundSession = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        backgroundEnabled = false
    }

    // MARK: - الحالة المشتقة

    var gpsQuality: GPSQuality {
        guard let loc = location, loc.horizontalAccuracy >= 0 else { return .unavailable }
        if Date().timeIntervalSince(loc.timestamp) > 30 { return .weak }
        switch loc.horizontalAccuracy {
        case ..<15: return .good
        case ..<weakThreshold: return .fair
        default: return .weak
        }
    }

    /// الاتجاه الحالي: البوصلة إن توفرت، وإلا اتجاه الحركة عند السير.
    var currentHeadingDegrees: Double? {
        if let h = heading, h.headingAccuracy >= 0 {
            return h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        }
        if let loc = location, loc.course >= 0, loc.speed > 1.5 { return loc.course }
        return nil
    }

    var isSimulatedLocation: Bool {
        location?.sourceInformation?.isSimulatedBySoftware ?? false
    }

    /// آخر موقع معروف محفوظ (يبقى بعد إغلاق التطبيق).
    var lastKnownCoordinate: (CLLocationCoordinate2D, Date)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: lastKnownKey),
              let lat = dict["lat"] as? Double, let lon = dict["lon"] as? Double,
              let t = dict["t"] as? Double else { return nil }
        return (CLLocationCoordinate2D(latitude: lat, longitude: lon), Date(timeIntervalSince1970: t))
    }

    private func persistLastKnown(_ loc: CLLocation) {
        UserDefaults.standard.set(["lat": loc.coordinate.latitude, "lon": loc.coordinate.longitude,
                                   "t": loc.timestamp.timeIntervalSince1970], forKey: lastKnownKey)
    }

    fileprivate func handle(locations: [CLLocation]) {
        for loc in locations {
            // نتجاهل القراءات غير الصالحة والقديمة جدًا
            guard loc.horizontalAccuracy >= 0,
                  abs(loc.timestamp.timeIntervalSinceNow) < 120 else { continue }
            location = loc
            lastError = nil
            persistLastKnown(loc)
            locationPublisher.send(loc)
        }
    }

    fileprivate func handle(error: Error) {
        let code = (error as? CLError)?.code
        switch code {
        case .locationUnknown:
            lastError = "جارٍ البحث عن إشارة الأقمار الصناعية. اخرج إلى مكان مكشوف."
        case .denied:
            lastError = "تم رفض إذن الموقع. فعّله من الإعدادات."
            isUpdating = false
        case .headingFailure:
            break // تشويش مغناطيسي مؤقت
        default:
            lastError = "تعذّر تحديد الموقع: \(error.localizedDescription)"
        }
    }

    fileprivate func handleAuthorizationChange() {
        authorization = manager.authorizationStatus
        isFullAccuracy = manager.accuracyAuthorization == .fullAccuracy
        if isAuthorized {
            start()
            if !backgroundReasons.isEmpty {
                let reasons = backgroundReasons
                reasons.forEach { beginBackgroundUpdates(reason: $0) }
            }
        } else if isDenied {
            isUpdating = false
        }
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.handle(locations: locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated { self.heading = newHeading }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.handle(error: error) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { self.handleAuthorizationChange() }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        true
    }
}
