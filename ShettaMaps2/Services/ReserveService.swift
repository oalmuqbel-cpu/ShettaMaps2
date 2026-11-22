import Foundation
import CoreLocation
import Combine
import MapKit
import UserNotifications

/// محمية أو منطقة محمية (حدود تقريبية من OpenStreetMap).
struct Reserve: Identifiable, Equatable {
    enum Kind: String {
        case royal, wildlife, park
        var title: String {
            switch self {
            case .royal: return "محمية ملكية"
            case .wildlife: return "محمية طبيعية"
            case .park: return "متنزه وطني أو منطقة محمية"
            }
        }
        var uiColor: UIColor {
            switch self {
            case .royal: return UIColor(red: 0.55, green: 0.35, blue: 0.15, alpha: 1)
            case .wildlife: return UIColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 1)
            case .park: return UIColor(red: 0.08, green: 0.40, blue: 0.75, alpha: 1)
            }
        }
    }
    var id: String
    var name: String
    var nameEn: String?
    var kind: Kind
    var operatorName: String?
    var website: URL?
    var source: URL?
    var country: String?
    var areaKm2: Int
    /// مضلعات: كل مضلع حلقة خارجية ثم ثقوب.
    var polygons: [[[CLLocationCoordinate2D]]]
    var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    var labelPoint: CLLocationCoordinate2D

    static func == (a: Reserve, b: Reserve) -> Bool { a.id == b.id }

    func intersects(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> Bool {
        !(maxLat < sw.latitude || minLat > ne.latitude || maxLon < sw.longitude || minLon > ne.longitude)
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        guard c.latitude >= minLat, c.latitude <= maxLat, c.longitude >= minLon, c.longitude <= maxLon else { return false }
        for poly in polygons {
            guard let outer = poly.first, Self.inside(c, outer) else { continue }
            if !poly.dropFirst().contains(where: { Self.inside(c, $0) }) { return true }
        }
        return false
    }

    /// اختبار نقطة داخل حلقة (إطلاق شعاع).
    static func inside(_ p: CLLocationCoordinate2D, _ ring: [CLLocationCoordinate2D]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                let x = (b.longitude - a.longitude) * (p.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if p.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    var mkPolygons: [MKPolygon] {
        polygons.compactMap { poly in
            guard let outer = poly.first, outer.count > 2 else { return nil }
            let holes = poly.dropFirst().filter { $0.count > 2 }.map { MKPolygon(coordinates: $0, count: $0.count) }
            return MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes.isEmpty ? nil : holes)
        }
    }
}

/// طبقة المحميات: تحميل أسبوعي من بيانات سَمْت (OpenStreetMap) وحفظها دون إنترنت،
/// وتنبيه عند دخول نطاق محمية أثناء السير.
@MainActor
final class ReserveService: ObservableObject {
    static let shared = ReserveService()
    nonisolated static let remote = URL(string: "https://oalmuqbel-cpu.github.io/ShettaMaps2/data/reserves.geojson")!
    nonisolated static var localURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reserves.geojson")
    }
    static let cooldown: TimeInterval = 6 * 3600

    @Published private(set) var reserves: [Reserve] = []
    @Published private(set) var revision = 0
    @Published private(set) var current: Reserve?

    private var alerted: [String: Date] = [:]
    private var primed = false
    private var cancellable: AnyCancellable?

    static var alertsEnabled: Bool { UserDefaults.standard.object(forKey: SettingsKeys.reserveAlerts) as? Bool ?? true }

    private init() {
        let url = Self.localURL
        Task.detached(priority: .utility) {
            let list = (try? Data(contentsOf: url)).flatMap { try? ReserveService.parse($0) } ?? []
            await MainActor.run {
                if self.reserves.isEmpty, !list.isEmpty { self.reserves = list; self.revision += 1 }
            }
            await self.refresh()
        }
        cancellable = LocationManager.shared.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.observe($0) }
    }

    func refresh(force: Bool = false) async {
        let key = "reservesFetchedAt"
        let have = FileManager.default.fileExists(atPath: Self.localURL.path)
        if !force, have, let last = UserDefaults.standard.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < 7 * 86_400 { return }
        guard NetworkMonitor.shared.isOnline else { return }
        var req = URLRequest(url: Self.remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        req.setValue("Samt/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try? await Task.detached(priority: .utility, operation: { try ReserveService.parse(data) }).value,
              list.count >= 5 else { return }
        try? FileManager.default.createDirectory(at: Self.localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.localURL, options: .atomic)
        UserDefaults.standard.set(Date(), forKey: key)
        reserves = list
        revision += 1
    }

    func reserves(in sw: CLLocationCoordinate2D, _ ne: CLLocationCoordinate2D) -> [Reserve] {
        reserves.filter { $0.intersects(sw: sw, ne: ne) }
    }

    /// أصغر محمية تحتوي النقطة (المحمية الأصغر داخل الأكبر أدق وصفًا).
    func reserve(at c: CLLocationCoordinate2D) -> Reserve? {
        reserves.filter { $0.contains(c) }.min { $0.areaKm2 < $1.areaKm2 }
    }

    func reserve(id: String) -> Reserve? { reserves.first { $0.id == id } }

    /// المحميات التي يمر بها مسار (عينات كل 500 م تقريبًا).
    func reserves(along coords: [CLLocationCoordinate2D]) -> [Reserve] {
        guard coords.count > 1, !reserves.isEmpty else { return coords.first.flatMap { reserve(at: $0) }.map { [$0] } ?? [] }
        var found: [Reserve] = []
        func check(_ c: CLLocationCoordinate2D) {
            if let r = reserve(at: c), !found.contains(r) { found.append(r) }
        }
        for (a, b) in zip(coords, coords.dropFirst()) {
            let d = GeoMath.distance(a, b)
            let steps = max(1, Int(d / 500))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                check(CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                             longitude: a.longitude + (b.longitude - a.longitude) * t))
            }
        }
        return found
    }

    // MARK: - تنبيه الدخول

    func observe(_ loc: CLLocation) {
        guard !reserves.isEmpty, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100 else { return }
        let r = reserve(at: loc.coordinate)
        defer { if current != r { current = r } }
        // أول قراءة بعد التشغيل: لا ننبّه عن محمية نحن داخلها أصلًا
        guard primed else { primed = true; if let r { alerted[r.id] = Date() }; return }
        guard let r, r != current, Self.alertsEnabled, loc.speed > 1.5 else { return }
        if let t = alerted[r.id], Date().timeIntervalSince(t) < Self.cooldown { return }
        alerted[r.id] = Date()
        let text = "دخلت نطاق \(r.name)"
        if VoicePrompter.enabled { VoicePrompter.shared.speak(text, tone: true) }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = text
            c.body = "قد يلزم تصريح للدخول أو التخييم. تأكد من أنظمة الجهة المسؤولة."
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "reserve-\(r.id)", content: c, trigger: nil))
        }
    }

    // MARK: - القراءة

    nonisolated static func parse(_ data: Data) throws -> [Reserve] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feats = root["features"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        var out: [Reserve] = []
        for (i, f) in feats.enumerated() {
            guard let p = f["properties"] as? [String: Any], let g = f["geometry"] as? [String: Any],
                  let type = g["type"] as? String, let name = p["name"] as? String else { continue }
            var polys: [[[CLLocationCoordinate2D]]] = []
            func ring(_ a: Any) -> [CLLocationCoordinate2D] {
                (a as? [[Double]] ?? []).compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil }
            }
            if type == "Polygon", let rings = g["coordinates"] as? [Any] {
                polys = [rings.map(ring)]
            } else if type == "MultiPolygon", let ps = g["coordinates"] as? [[Any]] {
                polys = ps.map { $0.map(ring) }
            }
            polys = polys.filter { ($0.first?.count ?? 0) > 2 }
            guard !polys.isEmpty else { continue }
            let all = polys.flatMap { $0.first ?? [] }
            let lats = all.map(\.latitude), lons = all.map(\.longitude)
            // نقطة الاسم: أقرب رأس من الحلقة الكبرى إلى مركزها إن كان المركز خارجها
            let biggest = polys.max { $0[0].count < $1[0].count }![0]
            let c = CLLocationCoordinate2D(latitude: biggest.map(\.latitude).reduce(0, +) / Double(biggest.count),
                                           longitude: biggest.map(\.longitude).reduce(0, +) / Double(biggest.count))
            let label = Reserve.inside(c, biggest) ? c : biggest.min { GeoMath.distance($0, c) < GeoMath.distance($1, c) }!
            out.append(Reserve(
                id: (p["osm"] as? String) ?? "r\(i)",
                name: name,
                nameEn: p["name_en"] as? String,
                kind: Reserve.Kind(rawValue: p["kind"] as? String ?? "") ?? .wildlife,
                operatorName: p["operator"] as? String,
                website: (p["website"] as? String).flatMap { s in
                    URL(string: s.hasPrefix("http") ? s : "https://" + s)
                },
                source: (p["osm"] as? String).flatMap(URL.init(string:)),
                country: p["country"] as? String,
                areaKm2: (p["area_km2"] as? Int) ?? Int((p["area_km2"] as? Double) ?? 0),
                polygons: polys,
                minLat: lats.min()!, maxLat: lats.max()!, minLon: lons.min()!, maxLon: lons.max()!,
                labelPoint: label))
        }
        return out
    }
}
