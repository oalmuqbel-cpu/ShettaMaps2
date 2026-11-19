import Foundation
import SwiftUI
import CoreLocation

/// حالة الطقس في نقطة: الآن وللساعات القادمة. المصدر Open-Meteo (CC BY 4.0).
struct WeatherNow: Equatable {
    var time: Date
    var temperature: Double
    var humidity: Double?
    var windSpeed: Double          // كم/س
    var windDirection: Double      // الاتجاه الذي تهب منه الرياح (درجات)
    var windGusts: Double?
    var weatherCode: Int
    var precipitation: Double      // مم
    var visibility: Double?        // متر
}

struct WeatherHour: Identifiable, Equatable {
    var time: Date
    var temperature: Double
    var windSpeed: Double
    var windDirection: Double
    var windGusts: Double?
    var precipitationProbability: Double?
    var precipitation: Double
    var weatherCode: Int
    var id: Date { time }
}

struct WeatherReport: Equatable {
    var coordinate: CLLocationCoordinate2D
    var fetchedAt: Date
    var now: WeatherNow
    var hours: [WeatherHour]
    var sunrise: Date?
    var sunset: Date?
    static func == (a: WeatherReport, b: WeatherReport) -> Bool { a.fetchedAt == b.fetchedAt && a.now == b.now }
}

/// مربع في خريطة الأمطار: كمية المطر المتوقعة لكل ساعة.
struct RainCell: Identifiable, Equatable {
    var id: String
    var lat: Double
    var lon: Double
    var size: Double
    var hourly: [Double]   // مم لكل ساعة ابتداءً من الساعة الحالية
    var cloud: [Double]    // نسبة الغيوم %
    /// عرض المربع بالطول إن اختلف عن ارتفاعه (مستطيل يجمع عدة نقاط متجاورة من صورة القمر الصناعي).
    var width: Double? = nil

    var corners: [CLLocationCoordinate2D] {
        let h = size / 2, w = (width ?? size) / 2
        return [.init(latitude: lat - h, longitude: lon - w), .init(latitude: lat + h, longitude: lon - w),
                .init(latitude: lat + h, longitude: lon + w), .init(latitude: lat - h, longitude: lon + w)]
    }
}

enum WeatherText {
    /// وصف رمز الطقس (WMO) بالعربية.
    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "صحو"
        case 1: return "صحو غالبًا"
        case 2: return "غائم جزئيًا"
        case 3: return "غائم"
        case 45, 48: return "ضباب"
        case 51, 53, 55, 56, 57: return "رذاذ"
        case 61, 63, 66: return "أمطار"
        case 65, 67: return "أمطار غزيرة"
        case 71, 73, 75, 77: return "ثلوج"
        case 80, 81: return "زخات مطر"
        case 82: return "زخات غزيرة"
        case 85, 86: return "زخات ثلج"
        case 95: return "عواصف رعدية"
        case 96, 99: return "عواصف رعدية مع برد"
        default: return "—"
        }
    }

    static func icon(_ code: Int, night: Bool = false) -> String {
        switch code {
        case 0, 1: return night ? "moon.stars.fill" : "sun.max.fill"
        case 2: return night ? "cloud.moon.fill" : "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud"
        }
    }

    /// اتجاه هبوب الرياح بالعربية (من أين تهب).
    static func windFrom(_ deg: Double) -> String {
        let names = ["شمالية", "شمالية شرقية", "شرقية", "جنوبية شرقية", "جنوبية", "جنوبية غربية", "غربية", "شمالية غربية"]
        let i = Int(((deg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return names[i]
    }

    /// تنبيه الغبار والرياح القوية (تقديري من سرعة الهبات والرؤية).
    static func dustWarning(_ n: WeatherNow) -> String? {
        let gust = n.windGusts ?? n.windSpeed
        if let v = n.visibility, v < 1000 { return "الرؤية أقل من كيلومتر: احتمال غبار أو ضباب كثيف." }
        if gust >= 60 { return "رياح شديدة جدًا (هبات \(Int(gust)) كم/س): احتمال عاصفة رملية. تجنب القيادة في الطعوس." }
        if gust >= 40 { return "رياح نشطة (هبات \(Int(gust)) كم/س): احتمال غبار يحد من الرؤية." }
        return nil
    }
}

@MainActor
final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published private(set) var report: WeatherReport?
    @Published private(set) var lastError: String?
    @Published private(set) var rainCells: [RainCell] = []
    @Published private(set) var rainHours: [Date] = []
    @Published private(set) var rainLoading = false

    private var lastFetch: (CLLocationCoordinate2D, Date)?
    private var lastRainBox: (Double, Double, Double, Double, Date)?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    private init() {
        report = Self.loadCache()
    }

    /// يجلب الطقس عند تغير الموقع أكثر من ١٠ كم أو مرور ٢٠ دقيقة.
    func refresh(at c: CLLocationCoordinate2D, force: Bool = false) async {
        if !force, let (lc, t) = lastFetch, GeoMath.distance(lc, c) < 10_000, Date().timeIntervalSince(t) < 1_200 { return }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", c.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", c.longitude)),
            .init(name: "current", value: "temperature_2m,relative_humidity_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,weather_code,precipitation,visibility"),
            .init(name: "hourly", value: "temperature_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,precipitation_probability,precipitation,weather_code"),
            .init(name: "daily", value: "sunrise,sunset"),
            .init(name: "forecast_days", value: "2"),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "wind_speed_unit", value: "kmh")
        ]
        do {
            let (data, resp) = try await session.data(from: comps.url!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let r = Self.parse(json, at: c) else { throw URLError(.badServerResponse) }
            report = r
            lastFetch = (c, Date())
            lastError = nil
            Self.saveCache(data, c)
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = "الطقس يحتاج اتصالًا بالإنترنت. المعروض آخر تحديث محفوظ."
        } catch {
            lastError = "تعذّر جلب الطقس الآن."
        }
    }

    nonisolated static func parse(_ json: [String: Any], at c: CLLocationCoordinate2D) -> WeatherReport? {
        func d(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        guard let cur = json["current"] as? [String: Any], let t = d(cur["time"]) else { return nil }
        let now = WeatherNow(time: Date(timeIntervalSince1970: t), temperature: d(cur["temperature_2m"]) ?? 0,
                             humidity: d(cur["relative_humidity_2m"]), windSpeed: d(cur["wind_speed_10m"]) ?? 0,
                             windDirection: d(cur["wind_direction_10m"]) ?? 0, windGusts: d(cur["wind_gusts_10m"]),
                             weatherCode: Int(d(cur["weather_code"]) ?? 0), precipitation: d(cur["precipitation"]) ?? 0,
                             visibility: d(cur["visibility"]))
        var hours: [WeatherHour] = []
        if let h = json["hourly"] as? [String: Any], let times = h["time"] as? [Any] {
            func arr(_ k: String) -> [Any] { h[k] as? [Any] ?? [] }
            let temp = arr("temperature_2m"), ws = arr("wind_speed_10m"), wd = arr("wind_direction_10m"), wg = arr("wind_gusts_10m")
            let pp = arr("precipitation_probability"), pr = arr("precipitation"), wc = arr("weather_code")
            for (i, tv) in times.enumerated() {
                guard let ts = d(tv) else { continue }
                let date = Date(timeIntervalSince1970: ts)
                guard date > Date().addingTimeInterval(-3_600) else { continue }
                func at(_ a: [Any]) -> Double? { i < a.count ? d(a[i]) : nil }
                hours.append(WeatherHour(time: date, temperature: at(temp) ?? 0, windSpeed: at(ws) ?? 0, windDirection: at(wd) ?? 0,
                                         windGusts: at(wg), precipitationProbability: at(pp), precipitation: at(pr) ?? 0,
                                         weatherCode: Int(at(wc) ?? 0)))
                if hours.count >= 24 { break }
            }
        }
        var rise: Date?, set: Date?
        if let daily = json["daily"] as? [String: Any] {
            rise = (daily["sunrise"] as? [Any])?.first.flatMap { d($0) }.map { Date(timeIntervalSince1970: $0) }
            set = (daily["sunset"] as? [Any])?.first.flatMap { d($0) }.map { Date(timeIntervalSince1970: $0) }
        }
        return WeatherReport(coordinate: c, fetchedAt: Date(), now: now, hours: hours, sunrise: rise, sunset: set)
    }

    // MARK: - خريطة الأمطار

    /// شبكة نقاط على المنطقة الظاهرة (حتى ١٠×١٠) بطلب واحد متعدد المواقع.
    func refreshRain(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async {
        let spanLat = ne.latitude - sw.latitude, spanLon = ne.longitude - sw.longitude
        guard spanLat > 0, spanLat < 12 else { rainCells = []; return }
        if let b = lastRainBox, Date().timeIntervalSince(b.4) < 900,
           sw.latitude >= b.0, sw.longitude >= b.1, ne.latitude <= b.2, ne.longitude <= b.3 { return }
        // نوسّع المنطقة قليلًا ونختار حجم مربع ثابت حسب التكبير
        let size = max(0.05, max(spanLat, spanLon) / 9)
        let lat0 = (sw.latitude / size).rounded(.down) * size, lon0 = (sw.longitude / size).rounded(.down) * size
        var lats: [Double] = [], lons: [Double] = []
        var la = lat0
        while la <= ne.latitude + size, lats.count < 12 { lats.append(la + size / 2); la += size }
        var lo = lon0
        while lo <= ne.longitude + size, lons.count < 12 { lons.append(lo + size / 2); lo += size }
        var pts: [(Double, Double)] = []
        for a in lats { for b in lons { pts.append((a, b)) } }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: pts.map { String(format: "%.3f", $0.0) }.joined(separator: ",")),
            .init(name: "longitude", value: pts.map { String(format: "%.3f", $0.1) }.joined(separator: ",")),
            .init(name: "hourly", value: "precipitation,cloud_cover"),
            .init(name: "forecast_hours", value: "13"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "auto")
        ]
        rainLoading = true
        defer { rainLoading = false }
        do {
            let (data, resp) = try await session.data(from: comps.url!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let any = try JSONSerialization.jsonObject(with: data)
            let list: [[String: Any]] = (any as? [[String: Any]]) ?? ((any as? [String: Any]).map { [$0] } ?? [])
            var cells: [RainCell] = []
            var hoursOut: [Date] = []
            for (i, item) in list.enumerated() where i < pts.count {
                guard let h = item["hourly"] as? [String: Any] else { continue }
                let pr = (h["precipitation"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                let cc = (h["cloud_cover"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                if hoursOut.isEmpty {
                    hoursOut = (h["time"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }.map { Date(timeIntervalSince1970: $0) }
                }
                let p = pts[i]
                cells.append(RainCell(id: String(format: "%.3f_%.3f_%.3f", p.0, p.1, size), lat: p.0, lon: p.1, size: size,
                                      hourly: pr, cloud: cc))
            }
            rainCells = cells
            rainHours = hoursOut
            lastRainBox = (sw.latitude, sw.longitude, ne.latitude, ne.longitude, Date())
        } catch {
            // دون اتصال: نبقي آخر خريطة
        }
    }

    // MARK: - التخزين

    private nonisolated static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("weather-cache.json")
    }

    private static func saveCache(_ data: Data, _ c: CLLocationCoordinate2D) {
        let wrapper: [String: Any] = ["lat": c.latitude, "lon": c.longitude, "json": String(data: data, encoding: .utf8) ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: wrapper) { try? d.write(to: cacheURL, options: .atomic) }
    }

    private static func loadCache() -> WeatherReport? {
        guard let d = try? Data(contentsOf: cacheURL),
              let w = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let lat = w["lat"] as? Double, let lon = w["lon"] as? Double, let s = w["json"] as? String,
              let json = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              var r = parse(json, at: .init(latitude: lat, longitude: lon)) else { return nil }
        r.fetchedAt = r.now.time
        return r
    }
}
