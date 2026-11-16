import Foundation
import MapKit
import SwiftData

/// تصنيفات البحث الصحراوي.
enum PlaceKind: String, CaseIterable, Identifiable, Codable {
    case all, mountain, valley, rawdah, nafud, shaib, camp, water, coldWater, cave, fuel, landmark, saved
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "الكل"
        case .mountain: return "جبال"
        case .valley: return "أودية"
        case .rawdah: return "فياض وروضات"
        case .nafud: return "نفود وعروق ورمال"
        case .shaib: return "شعبان"
        case .camp: return "مخيمات ومواقع برية"
        case .water: return "مياه وآبار"
        case .coldWater: return "ماء بارد"
        case .cave: return "غيران"
        case .fuel: return "محطات وقود"
        case .landmark: return "معالم"
        case .saved: return "محفوظة"
        }
    }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .mountain: return "mountain.2"
        case .valley: return "water.waves"
        case .rawdah: return "leaf"
        case .nafud: return "sun.dust"
        case .shaib: return "point.topleft.down.to.point.bottomright.curvepath"
        case .camp: return "tent"
        case .water: return "drop"
        case .coldWater: return "waterbottle"
        case .cave: return "flashlight.on.fill"
        case .fuel: return "fuelpump.fill"
        case .landmark: return "building.columns"
        case .saved: return "bookmark"
        }
    }

    /// أنواع الأماكن المعروفة التي تظهر أسماؤها على الخريطة (للفلترة).
    static let mapKinds: [PlaceKind] = [.rawdah, .nafud, .mountain, .valley, .shaib, .coldWater, .water, .cave, .fuel, .camp, .landmark]

    /// يحوّل قيمة الفلتر المحفوظة ("rawdah,valley") إلى مجموعة؛ الفارغة تعني الكل.
    static func decodeSet(_ raw: String) -> Set<PlaceKind> {
        Set(raw.split(separator: ",").compactMap { PlaceKind(rawValue: String($0)) }.filter { mapKinds.contains($0) })
    }
    static func encodeSet(_ set: Set<PlaceKind>) -> String {
        mapKinds.filter { set.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

struct SearchResult: Identifiable, Hashable {
    enum Source: String { case saved, gazetteer, online, community }
    var id: String
    var name: String
    var subtitle: String
    var kind: PlaceKind
    var latitude: Double
    var longitude: Double
    var source: Source
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var waypoint: Waypoint { Waypoint(name: name, coordinate: coordinate) }
}

/// مدخل في قاعدة البيانات الجغرافية المحلية (GeoJSON). لا تُضمَّن أسماء أو إحداثيات مخترعة؛
/// القاعدة تُبنى من مصدر موثق (مثل OpenStreetMap بموجب ODbL) عبر الأداة tools/build_gazetteer.py.
struct GazetteerEntry: Codable, Hashable {
    var id: String
    var name: String
    var altNames: [String]
    var kind: PlaceKind
    var lat: Double
    var lon: Double
    var region: String?
    var source: String
    /// رابط المصدر الأصلي (مثل قائمة «مارد ماء» في خرائط Google).
    var url: String? = nil
}

/// البحث المحلي (دون إنترنت) والبحث عبر الإنترنت.
@MainActor
final class SearchService: ObservableObject {
    static let shared = SearchService()

    @Published private(set) var gazetteer: [GazetteerEntry] = []
    @Published private(set) var gazetteerSource: String = ""
    private var normalizedIndex: [(entry: GazetteerEntry, keys: [String])] = []

    private init() { loadGazetteer() }

    private var userGazetteerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gazetteer.geojson")
    }

    // MARK: - تطبيع العربية

    nonisolated static func normalizeArabic(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x064B...0x065F, 0x0670, 0x0640: continue // التشكيل والتطويل
            case 0x0622, 0x0623, 0x0625, 0x0671: out.append("ا")
            case 0x0629: out.append("ه")
            case 0x0649: out.append("ي")
            case 0x0624: out.append("و")
            case 0x0626: out.append("ي")
            default: out.unicodeScalars.append(scalar)
            }
        }
        var r = out.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while r.contains("  ") { r = r.replacingOccurrences(of: "  ", with: " ") }
        return r
    }

    /// يحذف أداة التعريف من بداية كل كلمة لمطابقة "الطويق" مع "طويق".
    nonisolated static func stripDefiniteArticle(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            let word = String(w)
            return word.hasPrefix("ال") && word.count > 3 ? String(word.dropFirst(2)) : word
        }.joined(separator: " ")
    }

    nonisolated static func searchKey(_ s: String) -> String { stripDefiniteArticle(normalizeArabic(s)) }

    // MARK: - قاعدة البيانات الجغرافية

    func loadGazetteer() {
        let userURL = userGazetteerURL
        let useUser = FileManager.default.fileExists(atPath: userURL.path)
        gazetteerSource = useUser ? "قاعدة مستوردة" : "OpenStreetMap (مضمنة)"
        guard let url = useUser ? userURL : Bundle.main.url(forResource: "gazetteer", withExtension: "geojson") else {
            gazetteer = []; return
        }
        // التحليل في الخلفية لأن القاعدة كبيرة
        let extraURL = Self.extraURL
        Task.detached(priority: .userInitiated) {
            let base = (try? Data(contentsOf: url)).flatMap { try? SearchService.parseGeoJSON($0) } ?? []
            let extra = (try? Data(contentsOf: extraURL)).flatMap { try? SearchService.parseGeoJSON($0) } ?? []
            await MainActor.run {
                self.baseEntries = base
                self.extraEntries = extra
                self.rebuildIndex()
            }
            await self.refreshExtra()
        }
    }

    // MARK: - طبقات أماكن تُحدَّث من الإنترنت دون نسخة جديدة من التطبيق
    // (مثل قائمة «مارد ماء» لموارد المياه بإذن صاحبها). تُخزَّن محليًا فتعمل دون إنترنت.

    nonisolated static let extraRemote = URL(string: "https://oalmuqbel-cpu.github.io/ShettaMaps2/data/places-extra.geojson")!
    nonisolated static var extraURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("places-extra.geojson")
    }
    private var baseEntries: [GazetteerEntry] = []
    private var extraEntries: [GazetteerEntry] = []
    /// مصادر الطبقات الإضافية للعرض في الإعدادات.
    @Published private(set) var extraSources: [String: Int] = [:]

    private func rebuildIndex() {
        let all = baseEntries + extraEntries
        gazetteer = all
        normalizedIndex = all.map { e in (e, ([e.name] + e.altNames).map(Self.searchKey)) }
        extraSources = Dictionary(grouping: extraEntries, by: \.source).mapValues(\.count)
    }

    /// تحديث الطبقات الإضافية (مرة كل ٦ ساعات كحد أقصى).
    func refreshExtra(force: Bool = false) async {
        let key = "extraPlacesFetchedAt"
        if !force, let last = UserDefaults.standard.object(forKey: key) as? Date, Date().timeIntervalSince(last) < 6 * 3600 { return }
        guard NetworkMonitor.shared.isOnline else { return }
        var req = URLRequest(url: Self.extraRemote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Samt/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let entries = try? Self.parseGeoJSON(data) else { return }
        try? FileManager.default.createDirectory(at: Self.extraURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.extraURL, options: .atomic)
        UserDefaults.standard.set(Date(), forKey: key)
        extraEntries = entries
        rebuildIndex()
    }

    func importGazetteer(from source: URL) throws -> Int {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        let entries = try Self.parseGeoJSON(data)
        try data.write(to: userGazetteerURL, options: .atomic)
        baseEntries = entries
        rebuildIndex()
        gazetteerSource = "قاعدة مستوردة"
        return entries.count
    }

    /// يقرأ GeoJSON من نوع FeatureCollection بنقاط تحتوي خصائص name و kind.
    nonisolated static func parseGeoJSON(_ data: Data) throws -> [GazetteerEntry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        var result: [GazetteerEntry] = []
        for (i, f) in features.enumerated() {
            guard let geom = f["geometry"] as? [String: Any], geom["type"] as? String == "Point",
                  let coords = geom["coordinates"] as? [Double], coords.count >= 2,
                  let props = f["properties"] as? [String: Any],
                  let name = props["name"] as? String, !name.isEmpty else { continue }
            let lon = coords[0], lat = coords[1]
            guard (-90...90).contains(lat), (-180...180).contains(lon) else { continue }
            let kind = PlaceKind(rawValue: props["kind"] as? String ?? "") ?? .landmark
            result.append(GazetteerEntry(id: props["id"] as? String ?? "g\(i)", name: name,
                                         altNames: props["alt_names"] as? [String] ?? [],
                                         kind: kind, lat: lat, lon: lon,
                                         region: props["region"] as? String,
                                         source: props["source"] as? String ?? "OpenStreetMap",
                                         url: (props["url"] as? String) ?? (root["sourceURL"] as? String)))
        }
        return result
    }

    // MARK: - البحث

    func searchLocal(_ query: String, kind: PlaceKind, places: [SavedPlace], near: CLLocationCoordinate2D?, limit: Int = 100) -> [SearchResult] {
        let key = Self.searchKey(query)
        var results: [SearchResult] = []

        if kind == .all || kind == .saved {
            for p in places where key.isEmpty || Self.searchKey(p.name).contains(key) || Self.searchKey(p.notes).contains(key) {
                results.append(SearchResult(id: "s-\(p.id)", name: p.name, subtitle: p.category?.name ?? "موقع محفوظ",
                                            kind: .saved, latitude: p.latitude, longitude: p.longitude, source: .saved))
            }
        }
        if kind != .saved {
            for item in normalizedIndex where (kind == .all || item.entry.kind == kind) {
                guard key.isEmpty || item.keys.contains(where: { $0.contains(key) }) else { continue }
                let e = item.entry
                results.append(SearchResult(id: "g-\(e.id)", name: e.name,
                                            subtitle: [e.kind.title, e.region].compactMap { $0 }.joined(separator: " · "),
                                            kind: e.kind, latitude: e.lat, longitude: e.lon, source: .gazetteer))
            }
        }
        if let near {
            results.sort { GeoMath.distance(near, $0.coordinate) < GeoMath.distance(near, $1.coordinate) }
        }
        return Array(results.prefix(limit))
    }

    /// أشهر الأماكن داخل منطقة ظاهرة لعرض أسمائها على الخريطة (عدد محدود لوضوح العرض).
    /// kinds الفارغة تعني كل الأنواع، و nameFilter يطابق الاسم أو الأسماء البديلة بعد التطبيع.
    func entries(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, limit: Int = 120,
                 kinds: Set<PlaceKind> = [], nameFilter: String = "") -> [GazetteerEntry] {
        let priority: [PlaceKind: Int] = [.nafud: 0, .rawdah: 0, .valley: 1, .mountain: 2, .cave: 3, .camp: 4, .coldWater: 5, .water: 5, .fuel: 6, .shaib: 7, .landmark: 8]
        let key = Self.searchKey(nameFilter)
        var found: [GazetteerEntry] = []
        for item in normalizedIndex {
            let e = item.entry
            guard (sw.latitude...ne.latitude).contains(e.lat), (sw.longitude...ne.longitude).contains(e.lon),
                  kinds.isEmpty || kinds.contains(e.kind),
                  key.isEmpty || item.keys.contains(where: { $0.contains(key) }) else { continue }
            found.append(e)
            if found.count > limit * 6, kinds != [.nafud] { break }
        }
        // النفود والعروق الكبرى (الدهناء، النفود الكبير...) قبل الطعوس والكثبان الصغيرة
        func rank(_ e: GazetteerEntry) -> Int {
            let base = (priority[e.kind] ?? 9) * 2
            return e.kind == .nafud && !Self.isMajorSand(e.name) ? base + 1 : base
        }
        found.sort { rank($0) < rank($1) }
        return Array(found.prefix(limit))
    }

    /// أسماء المناطق الرملية الكبرى.
    nonisolated static func isMajorSand(_ name: String) -> Bool {
        let n = normalizeArabic(name)
        return ["نفود", "النفود", "عروق", "العروق", "الدهناء", "الربع الخالي", "الجافوره", "رمله", "رمال", "الرمال"]
            .contains { n == $0 || n.hasPrefix($0 + " ") }
    }

    /// مدخل القاعدة لمعرّف علامة على الخريطة («g-…»).
    func entry(forPinID id: String) -> GazetteerEntry? {
        guard id.hasPrefix("g-") else { return nil }
        let gid = String(id.dropFirst(2))
        return gazetteer.first { $0.id == gid }
    }

    /// أقرب أماكن من نوع معيّن (مثل محطات الوقود) لموقعك، دون إنترنت.
    func nearest(_ kind: PlaceKind, to c: CLLocationCoordinate2D, count: Int = 5) -> [(GazetteerEntry, Double)] {
        var best: [(GazetteerEntry, Double)] = []
        for item in normalizedIndex where item.entry.kind == kind {
            let d = GeoMath.distance(c, CLLocationCoordinate2D(latitude: item.entry.lat, longitude: item.entry.lon))
            if best.count < count || d < best[best.count - 1].1 {
                best.append((item.entry, d))
                best.sort { $0.1 < $1.1 }
                if best.count > count { best.removeLast() }
            }
        }
        return best
    }

    /// بحث Apple Maps — يتطلب الإنترنت.
    func searchOnline(_ query: String, region: MKCoordinateRegion?) async throws -> [SearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region { request.region = region }
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.enumerated().compactMap { i, item in
            let c = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(c) else { return nil }
            return SearchResult(id: "o-\(i)-\(c.latitude)-\(c.longitude)", name: item.name ?? "نتيجة",
                                subtitle: item.placemark.title ?? "", kind: .landmark,
                                latitude: c.latitude, longitude: c.longitude, source: .online)
        }
    }
}
