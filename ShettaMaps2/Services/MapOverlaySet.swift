import Foundation
import CoreLocation

/// وصف محايد للعناصر المرسومة فوق الخريطة، يستخدمه محرك MapKit ومحرك MapLibre وواجهة CarPlay
/// حتى تظهر النقاط والمسارات نفسها على كل الشاشات.
struct MapOverlaySet: Equatable {
    struct Pin: Equatable {
        var id: String
        var title: String
        var subtitle: String?
        var coordinate: CLLocationCoordinate2D
        var kind: PinKind
        /// رمز SF Symbol مخصص (لأنواع الأماكن الجغرافية).
        var symbol: String? = nil
        static func == (a: Pin, b: Pin) -> Bool {
            a.id == b.id && a.title == b.title && a.kind == b.kind
                && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }
    enum PinKind: Equatable { case saved, destination, waypoint, picked, start, search, landmark, community }
    enum LineKind: Equatable { case track, direct, road, importedTrack }

    struct Line: Equatable {
        var kind: LineKind
        var coordinates: [CLLocationCoordinate2D]
        static func == (a: Line, b: Line) -> Bool {
            guard a.kind == b.kind, a.coordinates.count == b.coordinates.count else { return false }
            // مقارنة سريعة: العدد + أول وآخر نقطة (يكفي لاكتشاف تغيّر المسار الحي والخط المباشر)
            guard let l1 = a.coordinates.last, let l2 = b.coordinates.last,
                  let f1 = a.coordinates.first, let f2 = b.coordinates.first else { return true }
            return l1.latitude == l2.latitude && l1.longitude == l2.longitude
                && f1.latitude == f2.latitude && f1.longitude == f2.longitude
        }
    }

    var pins: [Pin] = []
    var lines: [Line] = []

    /// يبني مجموعة العناصر من حالة التطبيق الحالية.
    static func build(places: [SavedPlace],
                      liveSegments: [[CLLocationCoordinate2D]],
                      navigation: NavigationSnapshot,
                      currentLocation: CLLocationCoordinate2D?,
                      picked: CLLocationCoordinate2D? = nil,
                      extraPins: [Pin] = [],
                      extraLines: [Line] = []) -> MapOverlaySet {
        var set = MapOverlaySet()
        set.pins = places.map {
            Pin(id: "p-\($0.id.uuidString)", title: $0.name, subtitle: $0.category?.name, coordinate: $0.coordinate, kind: .saved)
        }
        set.lines = liveSegments.map { Line(kind: .track, coordinates: $0) }

        if let plan = navigation.plan, navigation.isNavigating {
            let targetIndex = navigation.progress?.targetIndex ?? 0
            for (i, w) in plan.waypoints.enumerated() {
                set.pins.append(Pin(id: "w-\(w.id)", title: w.name, subtitle: "نقطة مرور \(i + 1)", coordinate: w.coordinate, kind: .waypoint))
            }
            set.pins.append(Pin(id: "d-\(plan.destination.id)", title: plan.destination.name, subtitle: "الوجهة",
                                coordinate: plan.destination.coordinate, kind: .destination))
            // الخط المباشر: من الموقع الحالي إلى الهدف الحالي ثم بقية الأهداف
            var coords: [CLLocationCoordinate2D] = []
            if let c = currentLocation { coords.append(c) } else if let o = plan.origin { coords.append(o.coordinate) }
            coords += plan.targets.dropFirst(targetIndex).map(\.coordinate)
            if coords.count > 1 { set.lines.append(Line(kind: .direct, coordinates: coords)) }
            if let road = navigation.roadRoute { set.lines.append(Line(kind: .road, coordinates: road.coordinates)) }
        }
        if let picked {
            set.pins.append(Pin(id: "picked", title: "نقطة محددة", subtitle: nil, coordinate: picked, kind: .picked))
        }
        set.pins += extraPins
        set.lines += extraLines
        return set
    }
}
