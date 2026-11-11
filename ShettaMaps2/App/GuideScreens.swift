#if DEBUG
import SwiftUI
import CoreLocation

/// لالتقاط صور دليل الاستخدام آليًا على المحاكي فقط (نسخة التطوير): يفتح شاشة محددة عبر الوسيط -GuideScreen <اسم>.
@MainActor
enum GuideScreens {
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GuideScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func applyIfRequested(router: AppRouter, mapManager: MapManager) async {
        guard let screen = requested else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let env = AppEnvironment.shared
        let here = env.location.location?.coordinate ?? CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)
        UserDefaults.standard.set("", forKey: SettingsKeys.landmarkKinds)
        switch screen {
        case "map":
            mapManager.send(.focus(here, spanMeters: 40_000))
        case "filter":
            UserDefaults.standard.set("rawdah,valley", forKey: SettingsKeys.landmarkKinds)
            mapManager.send(.focus(here, spanMeters: 160_000))
        case "pick":
            mapManager.send(.focus(here, spanMeters: 20_000))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            mapManager.pickedCoordinate = GeoMath.destination(from: here, distance: 3_000, bearing: 45)
        case "search":
            router.pendingSearchQuery = "روضة"
            router.mapSheet = .search
        case "coords":
            router.pendingCoordinateText = "24 42.816 ش 46 40.518 ق"
            router.mapSheet = .coordinates
        case "save":
            router.mapSheet = .savePlace(GeoMath.destination(from: here, distance: 2_000, bearing: 80))
        case "offline":
            mapManager.send(.focus(here, spanMeters: 15_000))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            router.mapSheet = .offlineMaps
        case "trips":
            if env.trips.activeTrip == nil { _ = env.trips.startTrip(name: "طلعة البر", autoRecord: false) }
            router.mapSheet = .trips
        case "tracks":
            router.selectedSection = .tracks
        case "settings":
            router.selectedSection = .settings
        default:
            break
        }
    }
}
#endif
