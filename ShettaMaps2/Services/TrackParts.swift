import Foundation
import CoreLocation

/// جزء من مسار بين وقفتين (مقطع واحد). يبقى داخل المسار الرئيسي.
struct TrackPart: Identifiable, Equatable {
    /// معرّف ثابت: وقت بداية الجزء (لا يتغير بحذف أجزاء أخرى أو قصها).
    var key: Int
    var id: Int { key }
    var index: Int
    var segment: Int
    var range: Range<Int>
    var start: Date
    var end: Date
    var distance: Double
    /// مدة الوقفة بعد هذا الجزء (nil للجزء الأخير).
    var stopAfter: TimeInterval?
    var coordinates: [CLLocationCoordinate2D]

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var keyString: String { String(key) }

    static func == (a: TrackPart, b: TrackPart) -> Bool { a.key == b.key && a.range == b.range }
}

/// تقسيم المسار إلى أجزاء حسب الوقفات (منطق مستقل قابل للاختبار).
enum TrackParts {
    /// مدة الوقفة التي تقسم المسار: نفس إعداد «الإيقاف التلقائي» في الإعدادات (٠ = لا تقسيم بالوقت).
    static var stopThreshold: TimeInterval {
        (UserDefaults.standard.object(forKey: SettingsKeys.autoPauseMinutes) as? Double ?? 15) * 60
    }

    /// يعيد ترقيم المقاطع تسلسليًا ويقسم أيضًا عند كل فجوة زمنية بطول الوقفة أو أكثر
    /// (وقفات لم يُوقف فيها التسجيل تلقائيًا، أو مسارات مستوردة).
    static func normalized(_ pts: [TrackPoint], stopThreshold: TimeInterval) -> [TrackPoint] {
        guard var prev = pts.first else { return pts }
        var out = pts
        var seg = 0
        out[0].segment = 0
        for i in 1..<pts.count {
            let p = pts[i]
            let gap = p.time.timeIntervalSince(prev.time)
            if p.segment != prev.segment || (stopThreshold > 0 && gap >= stopThreshold) { seg += 1 }
            out[i].segment = seg
            prev = p
        }
        return out
    }

    static func parts(_ pts: [TrackPoint]) -> [TrackPart] {
        var result: [TrackPart] = []
        var i = 0
        while i < pts.count {
            var j = i
            while j + 1 < pts.count, pts[j + 1].segment == pts[i].segment { j += 1 }
            let slice = pts[i...j]
            var d = 0.0
            for k in i..<j { d += GeoMath.distance(pts[k].coordinate, pts[k + 1].coordinate) }
            let stop = j + 1 < pts.count ? pts[j + 1].time.timeIntervalSince(pts[j].time) : nil
            result.append(TrackPart(key: Int(pts[i].time.timeIntervalSince1970), index: result.count + 1, segment: pts[i].segment,
                                    range: i..<(j + 1), start: pts[i].time, end: pts[j].time, distance: d,
                                    stopAfter: stop, coordinates: slice.map(\.coordinate)))
            i = j + 1
        }
        return result
    }

    /// حذف جزء كامل: تُحذف نقاطه فقط ويبقى مكانه فراغًا (لا يُوصل ما قبله بما بعده).
    static func removing(_ part: TrackPart, from pts: [TrackPoint]) -> [TrackPoint] {
        guard part.range.lowerBound >= 0, part.range.upperBound <= pts.count else { return pts }
        var out = pts
        out.removeSubrange(part.range)
        return out
    }

    static func points(of part: TrackPart, in pts: [TrackPoint]) -> [TrackPoint] {
        guard part.range.lowerBound >= 0, part.range.upperBound <= pts.count else { return [] }
        return Array(pts[part.range])
    }
}
