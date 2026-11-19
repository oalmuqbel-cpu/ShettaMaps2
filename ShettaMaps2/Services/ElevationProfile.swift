import Foundation
import CoreLocation

/// مقطع الارتفاع لمسار مسجّل: نقاط (مسافة، ارتفاع) مع إجمالي الصعود والنزول.
/// ارتفاع GPS متذبذب، لذلك يُنعَّم بمتوسط متحرك ولا يُحتسب الصعود إلا بعد تغيّر ٣ م فأكثر.
struct ElevationProfile: Equatable {
    struct Sample: Equatable, Identifiable {
        var distance: Double   // متر من بداية المسار
        var altitude: Double   // متر فوق سطح البحر
        var id: Double { distance }
    }
    var samples: [Sample]
    var gain: Double
    var loss: Double
    var minAltitude: Double
    var maxAltitude: Double
    var totalDistance: Double { samples.last?.distance ?? 0 }

    static let hysteresis = 3.0

    /// يعيد nil إذا لم تكن هناك ارتفاعات كافية (مسار مستورد بلا ارتفاع مثلًا).
    static func make(from points: [TrackPoint], maxSamples: Int = 300) -> ElevationProfile? {
        var raw: [Sample] = []
        var dist = 0.0
        var prev: TrackPoint?
        for p in points {
            if let q = prev, q.segment == p.segment { dist += GeoMath.distance(q.coordinate, p.coordinate) }
            prev = p
            if let a = p.alt, a.isFinite, a > -500, a < 9000 { raw.append(.init(distance: dist, altitude: a)) }
        }
        guard raw.count >= 5, dist > 50 else { return nil }

        // تنعيم بمتوسط متحرك (٥ نقاط)
        let w = 2
        var smooth = raw
        for i in raw.indices {
            let lo = max(0, i - w), hi = min(raw.count - 1, i + w)
            smooth[i].altitude = raw[lo...hi].map(\.altitude).reduce(0, +) / Double(hi - lo + 1)
        }

        // الصعود والنزول بعتبة
        var gain = 0.0, loss = 0.0
        var ref = smooth[0].altitude
        for s in smooth.dropFirst() {
            let d = s.altitude - ref
            if d >= hysteresis { gain += d; ref = s.altitude }
            else if d <= -hysteresis { loss -= d; ref = s.altitude }
        }

        // تقليل النقاط للعرض بخطوة مسافة ثابتة
        var out: [Sample] = []
        let step = max(1, dist / Double(maxSamples))
        var next = 0.0
        for s in smooth where s.distance >= next {
            out.append(s); next = s.distance + step
        }
        if let last = smooth.last, out.last != last { out.append(last) }

        let alts = smooth.map(\.altitude)
        return ElevationProfile(samples: out, gain: gain, loss: loss,
                                minAltitude: alts.min() ?? 0, maxAltitude: alts.max() ?? 0)
    }
}
