import Foundation
import CoreLocation

/// حسابات القمر محليًا دون إنترنت (صيغ التقويم الفلكي منخفضة الدقة؛ أوقات الشروق والغروب بحدود ١٠ دقائق).
enum MoonCalculator {
    private static let rad = Double.pi / 180

    private static func days(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5 - 2_451_545.0
    }

    private static func norm(_ x: Double) -> Double {
        let v = x.truncatingRemainder(dividingBy: 360); return v < 0 ? v + 360 : v
    }

    /// خط طول القمر والشمس الكسوفي وعرض القمر (درجات).
    private static func ecliptic(_ d: Double) -> (lambda: Double, beta: Double, sun: Double) {
        let L = 218.316 + 13.176396 * d
        let M = 134.963 + 13.064993 * d
        let F = 93.272 + 13.229350 * d
        let lambda = norm(L + 6.289 * sin(M * rad))
        let beta = 5.128 * sin(F * rad)
        let ms = 357.5291 + 0.98560028 * d
        let c = 1.9148 * sin(ms * rad) + 0.02 * sin(2 * ms * rad)
        let sun = norm(ms + c + 102.9372 + 180)
        return (lambda, beta, sun)
    }

    /// الاستطالة (٠ محاق، ١٨٠ بدر) وكسر الإضاءة ٠…١.
    static func phase(at date: Date) -> (elongation: Double, illumination: Double) {
        let e = ecliptic(days(date))
        let elong = norm(e.lambda - e.sun)
        let cosPsi = cos(e.beta * rad) * cos(elong * rad)
        return (elong, (1 - cosPsi) / 2)
    }

    static func phaseName(elongation e: Double) -> String {
        switch e {
        case ..<10, 350...: return "محاق"
        case ..<80: return "هلال متزايد"
        case ..<100: return "تربيع أول"
        case ..<170: return "أحدب متزايد"
        case ..<190: return "بدر"
        case ..<260: return "أحدب متناقص"
        case ..<280: return "تربيع أخير"
        default: return "هلال متناقص"
        }
    }

    /// ارتفاع مركز القمر عن الأفق (مركزي الأرض، درجات).
    static func altitude(at date: Date, _ c: CLLocationCoordinate2D) -> Double {
        let d = days(date)
        let e = ecliptic(d)
        let eps = 23.4397 * rad
        let l = e.lambda * rad, b = e.beta * rad
        let ra = atan2(sin(l) * cos(eps) - tan(b) * sin(eps), cos(l))
        let dec = asin(sin(b) * cos(eps) + cos(b) * sin(eps) * sin(l))
        let lst = (280.16 + 360.9856235 * d + c.longitude) * rad
        let h = lst - ra
        let phi = c.latitude * rad
        return asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h)) / rad
    }

    /// أول شروق وغروب للقمر في الفترة.
    static func riseSet(from start: Date, hours: Double = 24, at c: CLLocationCoordinate2D) -> (rise: Date?, set: Date?) {
        let h0 = 0.125, step: TimeInterval = 600
        var rise: Date?, set: Date?
        var t = start
        var prev = altitude(at: t, c) - h0
        while t < start.addingTimeInterval(hours * 3600), rise == nil || set == nil {
            let n = t.addingTimeInterval(step)
            let cur = altitude(at: n, c) - h0
            if prev < 0, cur >= 0, rise == nil { rise = t.addingTimeInterval(step * (-prev / (cur - prev))) }
            if prev >= 0, cur < 0, set == nil { set = t.addingTimeInterval(step * (prev / (prev - cur))) }
            prev = cur; t = n
        }
        return (rise, set)
    }
}

/// «ليلة البر»: الشفق والظلام والقمر وأجواء الليلة القادمة (أو الحالية).
struct DesertNight: Equatable {
    var sunset: Date
    var civilDusk: Date?
    var astroDusk: Date?
    var astroDawn: Date?
    var sunrise: Date
    var illumination: Double
    var phaseName: String
    var moonRise: Date?
    var moonSet: Date?
    /// ساعات الظلام الكامل دون قمر فوق الأفق.
    var darkHours: Double
    /// أطول فترة متصلة مظلمة بلا قمر (لرصد النجوم).
    var bestDark: (start: Date, end: Date)?
    var windMax: Double?
    var gustMax: Double?
    var tempMin: Double?

    static func == (a: DesertNight, b: DesertNight) -> Bool { a.sunset == b.sunset && a.windMax == b.windMax }

    static func make(at c: CLLocationCoordinate2D, now: Date = Date(), hours: [WeatherHour] = [],
                     timeZone: TimeZone = .current) -> DesertNight? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let noon = { (d: Date) in cal.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d }
        let today = noon(now)
        // إذا كنا قبل شروق اليوم فالليلة الحالية بدأت أمس
        var evening = today
        if let rise = SunCalculator.time(.sunrise, on: today, at: c), now < rise { evening = today.addingTimeInterval(-86_400) }
        let morning = evening.addingTimeInterval(86_400)
        guard let sunset = SunCalculator.time(.sunset, on: evening, at: c),
              let sunrise = SunCalculator.time(.sunrise, on: morning, at: c) else { return nil }
        let civil = SunCalculator.time(.sunset, on: evening, at: c, zenith: 96)
        let astroDusk = SunCalculator.time(.sunset, on: evening, at: c, zenith: 108)
        let astroDawn = SunCalculator.time(.sunrise, on: morning, at: c, zenith: 108)

        let mid = sunset.addingTimeInterval(sunrise.timeIntervalSince(sunset) / 2)
        let ph = MoonCalculator.phase(at: mid)
        let rs = MoonCalculator.riseSet(from: sunset.addingTimeInterval(-6 * 3600), hours: 30, at: c)
        let moonRise = rs.rise.flatMap { $0 <= sunrise ? $0 : nil }
        let moonSet = rs.set.flatMap { $0 <= sunrise ? $0 : nil }

        // ظلام كامل بلا قمر: نمسح كل ١٠ دقائق بين الشفق الفلكي مساءً وفجرًا
        var dark = 0.0
        var best: (Date, Date)?
        var runStart: Date?
        if let a = astroDusk, let b = astroDawn, b > a {
            var t = a
            while t < b {
                // الهلال الرفيع (أقل من ١٥٪) لا يفسد الظلام
                let moonUp = MoonCalculator.altitude(at: t, c) > 0.125 && ph.illumination > 0.15
                if !moonUp {
                    dark += 600
                    if runStart == nil { runStart = t }
                } else if let s = runStart {
                    if best.map({ t.timeIntervalSince(s) > $0.1.timeIntervalSince($0.0) }) ?? true { best = (s, t) }
                    runStart = nil
                }
                t = t.addingTimeInterval(600)
            }
            if let s = runStart, best.map({ b.timeIntervalSince(s) > $0.1.timeIntervalSince($0.0) }) ?? true { best = (s, b) }
        }

        let night = hours.filter { $0.time >= sunset && $0.time <= sunrise }
        return DesertNight(sunset: sunset, civilDusk: civil, astroDusk: astroDusk, astroDawn: astroDawn, sunrise: sunrise,
                           illumination: ph.illumination, phaseName: MoonCalculator.phaseName(elongation: ph.elongation),
                           moonRise: moonRise, moonSet: moonSet, darkHours: dark / 3600,
                           bestDark: best.flatMap { $0.1.timeIntervalSince($0.0) >= 1800 ? (start: $0.0, end: $0.1) : nil },
                           windMax: night.map(\.windSpeed).max(), gustMax: night.compactMap(\.windGusts).max(),
                           tempMin: night.map(\.temperature).min())
    }
}
