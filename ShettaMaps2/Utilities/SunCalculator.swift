import Foundation
import CoreLocation

/// حساب وقت الشروق والغروب محليًا دون إنترنت (خوارزمية NOAA المبسطة، دقة بحدود دقيقة أو دقيقتين).
enum SunCalculator {
    enum Event { case sunrise, sunset }

    static func time(_ event: Event, on date: Date, at c: CLLocationCoordinate2D, zenith: Double = 90.833) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let dayStart = cal.date(from: comps), let n = cal.ordinality(of: .day, in: .year, for: dayStart) else { return nil }
        let rad = Double.pi / 180
        let lngHour = c.longitude / 15
        let t = Double(n) + ((event == .sunrise ? 6 : 18) - lngHour) / 24
        let m = 0.9856 * t - 3.289
        var l = m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634
        l = l.truncatingRemainder(dividingBy: 360); if l < 0 { l += 360 }
        var ra = atan(0.91764 * tan(l * rad)) / rad
        ra = ra.truncatingRemainder(dividingBy: 360); if ra < 0 { ra += 360 }
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90
        ra /= 15
        let sinDec = 0.39782 * sin(l * rad)
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(zenith * rad) - sinDec * sin(c.latitude * rad)) / (cosDec * cos(c.latitude * rad))
        guard cosH >= -1, cosH <= 1 else { return nil }
        var h = event == .sunrise ? 360 - acos(cosH) / rad : acos(cosH) / rad
        h /= 15
        let localT = h + ra - 0.06571 * t - 6.622
        var ut = (localT - lngHour).truncatingRemainder(dividingBy: 24); if ut < 0 { ut += 24 }
        return dayStart.addingTimeInterval(ut * 3600)
    }
}
