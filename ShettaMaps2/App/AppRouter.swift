import SwiftUI
import CoreLocation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case map, places, tracks, trips, offlineMaps, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .map: return "الخريطة"
        case .places: return "المواقع"
        case .tracks: return "المسارات"
        case .trips: return "الرحلات"
        case .offlineMaps: return "الخرائط المحفوظة"
        case .settings: return "الإعدادات"
        }
    }
    var icon: String {
        switch self {
        case .map: return "map"
        case .places: return "mappin.and.ellipse"
        case .tracks: return "point.topleft.down.to.point.bottomright.curvepath"
        case .trips: return "car"
        case .offlineMaps: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

enum MapSheet: Identifiable {
    case savePlace(CLLocationCoordinate2D)
    case search
    case coordinates
    case offlineMaps
    case trips
    case routePlanner
    case recording

    var id: String {
        switch self {
        case .savePlace(let c): return "save-\(c.latitude)-\(c.longitude)"
        case .search: return "search"
        case .coordinates: return "coordinates"
        case .offlineMaps: return "offline"
        case .trips: return "trips"
        case .routePlanner: return "planner"
        case .recording: return "recording"
        }
    }
}

/// حالة التنقل في الواجهة (التبويب المحدد، الأوراق المنبثقة، الملفات الواردة).
@MainActor
final class AppRouter: ObservableObject {
    @Published var selectedSection: AppSection = .map
    @Published var mapSheet: MapSheet?
    @Published var incomingGPX: URL?
    @Published var plannerDraft = RoutePlannerDraft()

    func showOnMap() {
        // على الآيباد الخريطة ظاهرة دائمًا في العمود الأيمن؛ على الآيفون ننتقل لتبويب الخريطة
        if UIDevice.current.userInterfaceIdiom != .pad { selectedSection = .map }
    }

    func handleIncomingFile(_ url: URL) {
        if url.pathExtension.lowercased() == "gpx" {
            incomingGPX = url
            selectedSection = .tracks
        }
    }
}

/// مسودة مخطط المسار متعدد النقاط (مشتركة بين شاشة الإحداثيات وشاشة المخطط).
struct RoutePlannerDraft: Equatable {
    var useCurrentLocationAsOrigin = true
    var origin: Waypoint?
    var waypoints: [Waypoint] = []
    var destination: Waypoint?
}
