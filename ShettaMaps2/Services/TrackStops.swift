import Foundation
import CoreLocation

/// وقفة داخل الرحلة: نهاية مقطع (توقف) وبداية المقطع التالي (استئناف).
struct TrackStop: Equatable {
    var stopCoordinate: CLLocationCoordinate2D
    var resumeCoordinate: CLLocationCoordinate2D
    var stoppedAt: Date?
    var resumedAt: Date?

    var duration: TimeInterval? {
        guard let a = stoppedAt, let b = resumedAt, b > a else { return nil }
        return b.timeIntervalSince(a)
    }

    static func == (a: TrackStop, b: TrackStop) -> Bool {
        a.stopCoordinate.latitude == b.stopCoordinate.latitude && a.stopCoordinate.longitude == b.stopCoordinate.longitude
            && a.stoppedAt == b.stoppedAt
    }
}

/// استخراج الوقفات ورسم علاماتها الصغيرة. البداية والنهاية الكبيرتان تبقيان للرحلة كاملة.
enum TrackStops {
    /// الوقفات من نقاط مسار واحد أو عدة مسارات مرتبة زمنيًا (كل تغيّر في رقم المقطع = وقفة).
    static func stops(from points: [TrackPoint]) -> [TrackStop] {
        var result: [TrackStop] = []
        guard var prev = points.first else { return [] }
        for p in points.dropFirst() {
            if p.segment != prev.segment {
                result.append(TrackStop(stopCoordinate: prev.coordinate, resumeCoordinate: p.coordinate,
                                        stoppedAt: prev.time, resumedAt: p.time))
            }
            prev = p
        }
        return result
    }

    /// يدمج نقاط عدة مسارات (رحلة) في تسلسل واحد مع فصل كل مسار في مقاطع مستقلة.
    static func merged(_ tracks: [[TrackPoint]]) -> [TrackPoint] {
        var out: [TrackPoint] = []
        var offset = 0
        for pts in tracks where !pts.isEmpty {
            let maxSeg = pts.map(\.segment).max() ?? 0
            out += pts.map { var q = $0; q.segment += offset; return q }
            offset += maxSeg + 1
        }
        return out
    }

    /// علامات صغيرة من مقاطع بلا أوقات (التسجيل الحالي).
    static func pins(segments: [[CLLocationCoordinate2D]], idPrefix: String) -> [MapOverlaySet.Pin] {
        guard segments.count > 1 else { return [] }
        var stops: [TrackStop] = []
        for i in 0..<(segments.count - 1) {
            guard let a = segments[i].last, let b = segments[i + 1].first else { continue }
            stops.append(TrackStop(stopCoordinate: a, resumeCoordinate: b, stoppedAt: nil, resumedAt: nil))
        }
        return pins(stops: stops, idPrefix: idPrefix)
    }

    static func pins(stops: [TrackStop], idPrefix: String) -> [MapOverlaySet.Pin] {
        var pins: [MapOverlaySet.Pin] = []
        for (i, s) in stops.enumerated() {
            let n = i + 1
            var stopInfo: [String] = []
            if let t = s.stoppedAt { stopInfo.append("الساعة " + Fmt.time.string(from: t)) }
            if let d = s.duration { stopInfo.append("مدة الوقفة " + Fmt.duration(d)) }
            pins.append(.init(id: "\(idPrefix)-stop-\(n)", title: "توقف \(n)",
                              subtitle: stopInfo.isEmpty ? "وقفة أثناء الرحلة" : stopInfo.joined(separator: " · "),
                              coordinate: s.stopCoordinate, kind: .stop))
            // الاستئناف من النقطة نفسها تقريبًا لا يحتاج علامة ثانية
            if GeoMath.distance(s.stopCoordinate, s.resumeCoordinate) > 25 {
                pins.append(.init(id: "\(idPrefix)-resume-\(n)", title: "استئناف \(n)",
                                  subtitle: s.resumedAt.map { "الساعة " + Fmt.time.string(from: $0) } ?? "متابعة بعد الوقفة",
                                  coordinate: s.resumeCoordinate, kind: .resume))
            }
        }
        return pins
    }
}
