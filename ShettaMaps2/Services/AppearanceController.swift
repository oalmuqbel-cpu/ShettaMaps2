import SwiftUI
import CoreLocation

/// نمط العرض: تلقائي حسب الشروق والغروب في موقعك، أو نهاري، أو ليلي، أو حسب إعداد الجهاز.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case sun, light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sun: return "تلقائي حسب الشروق والغروب"
        case .light: return "نهاري دائمًا"
        case .dark: return "ليلي دائمًا"
        case .system: return "حسب إعداد الجهاز"
        }
    }
}

@MainActor
final class AppearanceController: ObservableObject {
    static let shared = AppearanceController()
    @Published private(set) var scheme: ColorScheme?
    private var timer: Timer?

    private init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in AppearanceController.shared.update() }
        }
    }

    var mode: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.appearanceMode) ?? "") ?? .sun
    }

    func update() {
        let new: ColorScheme?
        switch mode {
        case .light: new = .light
        case .dark: new = .dark
        case .system: new = nil
        case .sun: new = Self.isNight(at: LocationManager.shared.location?.coordinate
                                       ?? LocationManager.shared.lastKnownCoordinate?.0) ? .dark : .light
        }
        if new != scheme { scheme = new }
    }

    /// ليل إذا كان الوقت بعد الغروب أو قبل الشروق في الموقع (أو الرياض إن لم يتحدد الموقع).
    nonisolated static func isNight(at c: CLLocationCoordinate2D?, now: Date = Date()) -> Bool {
        let at = c ?? CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)
        guard let rise = SunCalculator.time(.sunrise, on: now, at: at),
              let set = SunCalculator.time(.sunset, on: now, at: at) else { return false }
        return now < rise || now > set
    }
}
