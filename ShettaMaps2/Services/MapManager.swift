import Foundation
import MapKit
import SwiftUI

/// طبقات الخريطة المتاحة. طبقات MapKit تحتاج إلى الإنترنت (مع تخزين مؤقت محدود يديره النظام)،
/// وطبقة "دون إنترنت" تعرض حزم MapLibre أو ملفات MBTiles المحملة مسبقًا.
enum MapLayer: String, CaseIterable, Identifiable {
    case standard, terrain, satellite, hybrid, dirt, offline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "عادية"
        case .terrain: return "تضاريس"
        case .satellite: return "أقمار صناعية"
        case .hybrid: return "هجينة"
        case .dirt: return "طرق ترابية وردميات"
        case .offline: return "دون إنترنت"
        }
    }
    var icon: String {
        switch self {
        case .standard: return "map"
        case .terrain: return "mountain.2"
        case .satellite: return "globe.asia.australia"
        case .hybrid: return "square.2.layers.3d"
        case .dirt: return "road.lanes"
        case .offline: return "arrow.down.circle"
        }
    }
    var needsInternet: Bool { self != .offline }
    /// الطبقات التي تُعرض بمحرك MapLibre بدل MapKit.
    var usesMapLibre: Bool { self == .offline || self == .dirt }

    /// نمط MapKit المقابل. "تضاريس" تستخدم الارتفاعات الواقعية حيث توفرها Apple.
    var mapStyle: MapStyle {
        switch self {
        case .standard, .offline, .dirt: return .standard(elevation: .flat, pointsOfInterest: .all)
        case .terrain: return .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)
        case .satellite: return .imagery(elevation: .realistic)
        case .hybrid: return .hybrid(elevation: .realistic)
        }
    }

    var mkMapType: MKMapType {
        switch self {
        case .standard, .offline, .terrain, .dirt: return .standard
        case .satellite: return .satellite
        case .hybrid: return .hybrid
        }
    }
}

/// أوامر للخريطة تُرسل من الأزرار إلى المحرك النشط (MapKit أو MapLibre).
enum MapCommand: Equatable {
    case zoomIn, zoomOut, centerOnUser, resetNorth
    case focus(CLLocationCoordinate2D, spanMeters: Double)
    case fit([CLLocationCoordinate2D])
    /// منظور ثلاثي الأبعاد (ميلان الكاميرا) أو مسطح.
    case pitch(Bool)

    static func == (a: MapCommand, b: MapCommand) -> Bool {
        switch (a, b) {
        case (.zoomIn, .zoomIn), (.zoomOut, .zoomOut), (.centerOnUser, .centerOnUser), (.resetNorth, .resetNorth): return true
        case let (.focus(c1, s1), .focus(c2, s2)): return c1.latitude == c2.latitude && c1.longitude == c2.longitude && s1 == s2
        case let (.fit(x), .fit(y)): return x.count == y.count
        case let (.pitch(x), .pitch(y)): return x == y
        default: return false
        }
    }
}

/// حالة الخريطة المشتركة للشاشة الرئيسية.
@MainActor
final class MapManager: ObservableObject {
    @Published var layer: MapLayer {
        didSet { UserDefaults.standard.set(layer.rawValue, forKey: SettingsKeys.mapLayer) }
    }
    @Published var followsUser = true
    @Published var isPickingPoint = false
    @Published var pickedCoordinate: CLLocationCoordinate2D?
    /// مركز الخريطة ومنطقتها الظاهرة (تستخدم لتنزيل منطقة دون إنترنت والبحث).
    @Published var visibleRegion: MKCoordinateRegion?
    @Published var cameraHeading: Double = 0
    /// المنظور ثلاثي الأبعاد مفعل.
    @Published var is3D = false
    /// علامة ضغط عليها المستخدم على الخريطة (مكان معروف، روضة، مكان محفوظ...).
    @Published var selectedPin: MapOverlaySet.Pin?
    @Published private(set) var command: MapCommand?
    @Published private(set) var commandID = 0

    init() {
        layer = MapLayer(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.mapLayer) ?? "") ?? .standard
    }

    func send(_ c: MapCommand) {
        switch c {
        case .centerOnUser: followsUser = true
        case .zoomIn, .zoomOut, .resetNorth: break
        case .pitch(let on): is3D = on
        case .focus, .fit: followsUser = false
        }
        command = c
        commandID += 1
    }

    var visibleBounds: (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D)? {
        guard let r = visibleRegion else { return nil }
        let sw = CLLocationCoordinate2D(latitude: r.center.latitude - r.span.latitudeDelta / 2,
                                        longitude: r.center.longitude - r.span.longitudeDelta / 2)
        let ne = CLLocationCoordinate2D(latitude: r.center.latitude + r.span.latitudeDelta / 2,
                                        longitude: r.center.longitude + r.span.longitudeDelta / 2)
        return (sw, ne)
    }
}
