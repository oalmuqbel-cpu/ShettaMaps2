import Foundation
import CoreLocation

/// حسابات جغرافية على كرة الأرض (WGS84 تقريبًا). منطق خالص قابل للاختبار.
enum GeoMath {
    static let earthRadius: Double = 6_371_008.8 // متر (نصف القطر المتوسط)

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }
    @inline(__always) static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// المسافة بالأمتار بصيغة هافرساين.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = rad(b.latitude - a.latitude)
        let dLon = rad(b.longitude - a.longitude)
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(rad(a.latitude)) * cos(rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// الاتجاه الابتدائي (السمت) من أ إلى ب بالدرجات من الشمال الجغرافي 0..<360.
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let φ1 = rad(a.latitude), φ2 = rad(b.latitude)
        let Δλ = rad(b.longitude - a.longitude)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        return normalizeDegrees(deg(atan2(y, x)))
    }

    /// النقطة الواقعة على مسافة واتجاه معلومين من نقطة البداية.
    static func destination(from a: CLLocationCoordinate2D, distance: Double, bearing: Double) -> CLLocationCoordinate2D {
        let δ = distance / earthRadius
        let θ = rad(bearing)
        let φ1 = rad(a.latitude), λ1 = rad(a.longitude)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        var lon = deg(λ2)
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: deg(φ2), longitude: lon)
    }

    /// إجمالي طول سلسلة نقاط بالأمتار.
    static func pathLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<coords.count { total += distance(coords[i - 1], coords[i]) }
        return total
    }

    static func normalizeDegrees(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// الفرق الزاوي الموقّع بين اتجاهين في المدى (-180, 180].
    static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = normalizeDegrees(b) - normalizeDegrees(a)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// اسم الاتجاه بالعربية (16 اتجاهًا مختصرة إلى 8 للوضوح).
    static func cardinalName(_ bearing: Double) -> String {
        let names = ["شمال", "شمال شرق", "شرق", "جنوب شرق", "جنوب", "جنوب غرب", "غرب", "شمال غرب"]
        let idx = Int((normalizeDegrees(bearing) + 22.5) / 45) % 8
        return names[idx]
    }

    /// صندوق إحاطة لمجموعة نقاط.
    static func boundingBox(_ coords: [CLLocationCoordinate2D]) -> (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D)? {
        guard let first = coords.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        return (CLLocationCoordinate2D(latitude: minLat, longitude: minLon),
                CLLocationCoordinate2D(latitude: maxLat, longitude: maxLon))
    }

    /// تقدير عدد مربعات الخريطة (tiles) لمنطقة بين مستويي تكبير، لتقدير حجم التنزيل.
    static func estimatedTileCount(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, minZoom: Int, maxZoom: Int) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        var total = 0
        for z in minZoom...maxZoom {
            let (x1, y1) = tileXY(lat: ne.latitude, lon: sw.longitude, zoom: z)
            let (x2, y2) = tileXY(lat: sw.latitude, lon: ne.longitude, zoom: z)
            total += (abs(x2 - x1) + 1) * (abs(y2 - y1) + 1)
        }
        return total
    }

    static func tileXY(lat: Double, lon: Double, zoom: Int) -> (Int, Int) {
        let n = pow(2.0, Double(zoom))
        let clampedLat = max(-85.0511, min(85.0511, lat))
        let x = Int(floor((lon + 180) / 360 * n))
        let latRad = rad(clampedLat)
        let y = Int(floor((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n))
        let maxIndex = Int(n) - 1
        return (min(max(x, 0), maxIndex), min(max(y, 0), maxIndex))
    }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> Double { GeoMath.distance(self, other) }
    func bearing(to other: CLLocationCoordinate2D) -> Double { GeoMath.bearing(from: self, to: other) }
}
