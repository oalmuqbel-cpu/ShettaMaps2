import Foundation
import CoreLocation

/// ترميز المسارات بصيغة Google Encoded Polyline (دقة 1e-5) وتبسيطها بخوارزمية Douglas–Peucker.
enum PolylineCodec {
    static func encode(_ coords: [CLLocationCoordinate2D]) -> String {
        var out = ""
        var pLat = 0, pLon = 0
        for c in coords {
            let lat = Int((c.latitude * 1e5).rounded()), lon = Int((c.longitude * 1e5).rounded())
            out += value(lat - pLat) + value(lon - pLon)
            pLat = lat; pLon = lon
        }
        return out
    }

    private static func value(_ v: Int) -> String {
        var n = v < 0 ? ~(v << 1) : (v << 1)
        var s = ""
        while n >= 0x20 {
            s.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (n & 0x1f)) + 63)))
            n >>= 5
        }
        s.unicodeScalars.append(UnicodeScalar(UInt8(n + 63)))
        return s
    }

    static func decode(_ str: String) -> [CLLocationCoordinate2D] {
        let bytes = Array(str.utf8)
        var i = 0, lat = 0, lon = 0
        var result: [CLLocationCoordinate2D] = []
        func next() -> Int? {
            var shift = 0, res = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63; i += 1
                res |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (res & 1) != 0 ? ~(res >> 1) : (res >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat; lon += dLon
            result.append(.init(latitude: Double(lat) / 1e5, longitude: Double(lon) / 1e5))
        }
        return result
    }

    /// تبسيط بحيث لا يتجاوز العدد maxPoints، مع رفع التسامح تدريجيًا.
    static func simplify(_ coords: [CLLocationCoordinate2D], maxPoints: Int, startTolerance: Double = 5) -> [CLLocationCoordinate2D] {
        guard coords.count > 2 else { return coords }
        var tol = startTolerance
        var result = douglasPeucker(coords, tolerance: tol)
        while result.count > maxPoints && tol < 2_000 {
            tol *= 1.6
            result = douglasPeucker(coords, tolerance: tol)
        }
        return result
    }

    static func douglasPeucker(_ pts: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true; keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var maxD = 0.0, idx = a
            for k in (a + 1)..<b {
                let d = crossTrackDistance(pts[k], pts[a], pts[b])
                if d > maxD { maxD = d; idx = k }
            }
            if maxD > tolerance {
                keep[idx] = true
                stack.append((a, idx)); stack.append((idx, b))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    /// المسافة العمودية التقريبية (بالأمتار) من نقطة إلى قطعة مستقيمة على مسقط محلي.
    private static func crossTrackDistance(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let k = cos(a.latitude * .pi / 180) * 111_320.0
        let ax = a.longitude * k, ay = a.latitude * 110_540, bx = b.longitude * k, by = b.latitude * 110_540
        let px = p.longitude * k, py = p.latitude * 110_540
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(px - ax, py - ay) }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    /// إزالة أول وآخر مسافة محددة من المسار لحماية مكان الانطلاق والوصول (البيت أو الاستراحة).
    static func trimEnds(_ coords: [CLLocationCoordinate2D], meters: Double) -> [CLLocationCoordinate2D] {
        guard coords.count > 2, meters > 0 else { return coords }
        var start = 0, acc = 0.0
        while start < coords.count - 1, acc < meters { acc += GeoMath.distance(coords[start], coords[start + 1]); start += 1 }
        var end = coords.count - 1; acc = 0
        while end > start, acc < meters { acc += GeoMath.distance(coords[end], coords[end - 1]); end -= 1 }
        return end > start ? Array(coords[start...end]) : []
    }
}
