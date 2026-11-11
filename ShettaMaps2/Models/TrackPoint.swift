import Foundation
import CoreLocation

/// نقطة مسار مسجّلة. تُخزّن مجمّعة كبيانات مضغوطة داخل RecordedTrack لتخفيف قاعدة البيانات.
struct TrackPoint: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double
    var alt: Double?
    var time: Date
    var speed: Double?          // م/ث، nil إذا لم تكن موثوقة
    var hAcc: Double?           // الدقة الأفقية بالمتر
    /// يبدأ مقطع جديد بعد الإيقاف المؤقت حتى لا تُرسم قفزة بين المقاطع.
    var segment: Int = 0

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init(lat: Double, lon: Double, alt: Double? = nil, time: Date, speed: Double? = nil, hAcc: Double? = nil, segment: Int = 0) {
        self.lat = lat; self.lon = lon; self.alt = alt; self.time = time
        self.speed = speed; self.hAcc = hAcc; self.segment = segment
    }

    init(location: CLLocation, segment: Int) {
        self.init(lat: location.coordinate.latitude,
                  lon: location.coordinate.longitude,
                  alt: location.verticalAccuracy >= 0 ? location.altitude : nil,
                  time: location.timestamp,
                  speed: location.speedAccuracy >= 0 && location.speed >= 0 ? location.speed : nil,
                  hAcc: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                  segment: segment)
    }
}

enum TrackPointCodec {
    static func encode(_ points: [TrackPoint]) -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return (try? encoder.encode(points)) ?? Data()
    }

    static func decode(_ data: Data?) -> [TrackPoint] {
        guard let data, !data.isEmpty else { return [] }
        return (try? PropertyListDecoder().decode([TrackPoint].self, from: data)) ?? []
    }
}

/// نقطة توقف أو نقطة مرور في رحلة أو خطة ملاحة.
struct Waypoint: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    init(id: UUID = UUID(), name: String, coordinate: CLLocationCoordinate2D) {
        self.id = id; self.name = name
        self.lat = coordinate.latitude; self.lon = coordinate.longitude
    }
}
