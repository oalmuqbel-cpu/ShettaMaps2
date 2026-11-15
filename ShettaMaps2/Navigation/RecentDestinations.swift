import Foundation
import CoreLocation

/// آخر الوجهات التي بدأت إليها الملاحة (مشتركة بين الهاتف وCarPlay) لاختصار اللمسات.
enum RecentDestinations {
    static let key = "recentDestinations"
    static let maxCount = 8

    static func load(_ defaults: UserDefaults = .standard) -> [Waypoint] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Waypoint].self, from: data)) ?? []
    }

    /// يضيف الوجهة في الأعلى، ويحذف المكررة (نفس المكان ضمن ١٠٠ م)، ويقصر القائمة.
    static func record(_ w: Waypoint, _ defaults: UserDefaults = .standard) {
        var list = load(defaults).filter { GeoMath.distance($0.coordinate, w.coordinate) > 100 }
        list.insert(w, at: 0)
        if list.count > maxCount { list = Array(list.prefix(maxCount)) }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}
