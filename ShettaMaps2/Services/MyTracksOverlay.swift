import Foundation
import CoreLocation

/// يخزن نسخًا مبسطة من مساراتي السابقة لعرضها كلها على الخريطة بسرعة دون فك كل النقاط في كل رسم.
@MainActor
final class MyTracksOverlay {
    static let shared = MyTracksOverlay()

    private struct Entry {
        var pointCount: Int
        var segments: [[CLLocationCoordinate2D]]
        var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    }
    private var cache: [UUID: Entry] = [:]

    /// خطوط المسارات المكتملة التي تتقاطع مع المنطقة الظاهرة.
    func lines(for tracks: [RecordedTrack], sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
               excluding excluded: Set<UUID> = []) -> [MapOverlaySet.Line] {
        var out: [MapOverlaySet.Line] = []
        for t in tracks where t.isComplete && !excluded.contains(t.id) && t.pointCount > 1 {
            let e = entry(for: t)
            guard e.maxLat >= sw.latitude, e.minLat <= ne.latitude, e.maxLon >= sw.longitude, e.minLon <= ne.longitude else { continue }
            out += e.segments.map { MapOverlaySet.Line(kind: .myTracks, coordinates: $0) }
            if out.count > 400 { break }
        }
        return out
    }

    private func entry(for t: RecordedTrack) -> Entry {
        if let e = cache[t.id], e.pointCount == t.pointCount { return e }
        let segs = TrackAccumulator.segments(of: t.points).map { PolylineCodec.simplify($0, maxPoints: 250) }
        let all = segs.flatMap { $0 }
        let e = Entry(pointCount: t.pointCount, segments: segs,
                      minLat: all.map(\.latitude).min() ?? 0, maxLat: all.map(\.latitude).max() ?? 0,
                      minLon: all.map(\.longitude).min() ?? 0, maxLon: all.map(\.longitude).max() ?? 0)
        cache[t.id] = e
        return e
    }
}
