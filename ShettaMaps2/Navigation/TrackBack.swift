import Foundation
import CoreLocation

/// «ارجع من نفس الطريق»: يحوّل مسارًا مسجلًا إلى خطة ملاحة معكوسة بنقاط كل ~٢٠٠ م حتى نقطة البداية.
enum TrackBack {
    static let spacing: Double = 200

    static func plan(from points: [TrackPoint], current: CLLocationCoordinate2D?, name: String) -> NavigationPlan? {
        plan(coordinates: points.map(\.coordinate), current: current, name: name)
    }

    static func plan(coordinates coords: [CLLocationCoordinate2D], current: CLLocationCoordinate2D?, name: String) -> NavigationPlan? {
        guard coords.count >= 2 else { return nil }
        var rev = Array(coords.reversed())
        // نبدأ من أقرب نقطة على المسار للموقع الحالي (لا من آخره) إن كان المستخدم قد تحرك عنه
        if let c = current, let nearest = rev.indices.min(by: { GeoMath.distance(c, rev[$0]) < GeoMath.distance(c, rev[$1]) }) {
            rev = Array(rev[nearest...])
        }
        guard let start = rev.last else { return nil }
        var sampled: [CLLocationCoordinate2D] = []
        var last: CLLocationCoordinate2D?
        for p in rev.dropLast() {
            if let l = last, GeoMath.distance(l, p) < spacing { continue }
            sampled.append(p); last = p
        }
        // نقطة قريبة جدًا من البداية لا داعي لها
        if let l = sampled.last, GeoMath.distance(l, start) < spacing / 2 { sampled.removeLast() }
        let waypoints = sampled.enumerated().map { Waypoint(name: "\(name) · \($0.offset + 1)", coordinate: $0.element) }
        var plan = NavigationPlan(origin: current.map { Waypoint(name: "موقعي", coordinate: $0) },
                                  waypoints: waypoints, destination: Waypoint(name: "بداية \(name)", coordinate: start), mode: .direct)
        plan.breadcrumb = true
        return plan
    }
}
