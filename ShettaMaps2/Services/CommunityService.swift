import Foundation
import CoreLocation
import Security

/// إعدادات خدمة المشاركة المجتمعية (Firebase). مفتاح Web API في Firebase ليس سرًا؛
/// الحماية تتم عبر قواعد الأمان في Firestore (docs/firestore.rules).
enum CommunityConfig {
    static let apiKey = ""
    static let projectID = ""
    static var isConfigured: Bool { !apiKey.isEmpty && !projectID.isEmpty }
    /// حدود الخليج العربي التقريبية المقبولة للمشاركات.
    static let latRange = 12.0...33.0
    static let lonRange = 34.0...60.0
    /// المشاركة تُخفى تلقائيًا بعد هذا العدد من البلاغات.
    static let hideAfterReports = 3
}

/// مكان شاركه أحد المستخدمين علنًا.
struct CommunityPlace: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: PlaceKind
    var lat: Double
    var lon: Double
    var notes: String
    var authorUid: String
    var createdAt: Date
    var reportCount: Int

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var waypoint: Waypoint { Waypoint(name: name, coordinate: coordinate) }
}

enum CommunityError: LocalizedError {
    case notConfigured, outsideRegion, invalidName, offline, server(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "خدمة المشاركة غير مفعّلة بعد."
        case .outsideRegion: return "المشاركة العامة متاحة للأماكن داخل دول الخليج العربي فقط."
        case .invalidName: return "اسم المكان يجب أن يكون بين حرفين و60 حرفًا."
        case .offline: return "لا يوجد اتصال بالإنترنت. حُفظ المكان على جهازك، وتمكنك مشاركته لاحقًا."
        case .server(let m): return "تعذّر الاتصال بخدمة المشاركة: \(m)"
        }
    }
}

/// المشاركة المجتمعية للأماكن البرية: مصادقة مجهولة الهوية، رفع، جلب حسب المنطقة، إبلاغ، وحذف.
/// لا يُرسل أي اسم أو بريد أو رقم جوال؛ يُخزَّن مع المكان معرّف عشوائي للجهاز فقط لتمكين صاحبه من حذفه.
@MainActor
final class CommunityService: ObservableObject {
    static let shared = CommunityService()

    @Published private(set) var places: [CommunityPlace] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false
    @Published var hiddenAuthors: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenAuthors), forKey: "community.hiddenAuthors") }
    }
    @Published var reportedIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(reportedIDs), forKey: "community.reported") }
    }
    @Published var termsAccepted: Bool {
        didSet { UserDefaults.standard.set(termsAccepted, forKey: "community.termsAccepted") }
    }

    private var idToken: String?
    private var tokenExpiry = Date.distantPast
    private var lastFetchBox: (Double, Double, Double, Double)?
    private var lastFetch = Date.distantPast
    private let session: URLSession

    var isEnabled: Bool { CommunityConfig.isConfigured }
    var myUid: String? { Keychain.get("community.uid") }

    /// المشاركات الظاهرة بعد استبعاد المحجوبين والمبلغ عنها.
    var visiblePlaces: [CommunityPlace] {
        places.filter { $0.reportCount < CommunityConfig.hideAfterReports && !hiddenAuthors.contains($0.authorUid)
            && !reportedIDs.contains($0.id) }
    }

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        hiddenAuthors = Set(UserDefaults.standard.stringArray(forKey: "community.hiddenAuthors") ?? [])
        reportedIDs = Set(UserDefaults.standard.stringArray(forKey: "community.reported") ?? [])
        termsAccepted = UserDefaults.standard.bool(forKey: "community.termsAccepted")
        places = Self.loadCache()
    }

    // MARK: - المصادقة المجهولة

    private func token() async throws -> String {
        guard isEnabled else { throw CommunityError.notConfigured }
        if let t = idToken, Date() < tokenExpiry { return t }
        if let refresh = Keychain.get("community.refresh") {
            if let t = try? await refreshToken(refresh) { return t }
        }
        // حساب مجهول جديد
        let url = URL(string: "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(CommunityConfig.apiKey)")!
        let json = try await post(url, body: ["returnSecureToken": true], auth: nil)
        guard let t = json["idToken"] as? String, let refresh = json["refreshToken"] as? String,
              let uid = json["localId"] as? String else { throw CommunityError.server("استجابة مصادقة غير متوقعة") }
        Keychain.set(refresh, for: "community.refresh")
        Keychain.set(uid, for: "community.uid")
        setToken(t, expiresIn: json["expiresIn"])
        return t
    }

    private func refreshToken(_ refresh: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://securetoken.googleapis.com/v1/token?key=\(CommunityConfig.apiKey)")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=refresh_token&refresh_token=\(refresh)".data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = json["id_token"] as? String else { throw CommunityError.server("انتهت جلسة المشاركة") }
        if let uid = json["user_id"] as? String { Keychain.set(uid, for: "community.uid") }
        setToken(t, expiresIn: json["expires_in"])
        return t
    }

    private func setToken(_ t: String, expiresIn: Any?) {
        idToken = t
        let secs = Double("\(expiresIn ?? "3600")") ?? 3600
        tokenExpiry = Date().addingTimeInterval(secs - 120)
    }

    // MARK: - العمليات

    private var base: String { "https://firestore.googleapis.com/v1/projects/\(CommunityConfig.projectID)/databases/(default)/documents" }

    /// ينشر مكانًا علنًا ويعيد معرّفه.
    func publish(name: String, kind: PlaceKind, coordinate c: CLLocationCoordinate2D, notes: String) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...60).contains(trimmed.count) else { throw CommunityError.invalidName }
        guard CommunityConfig.latRange.contains(c.latitude), CommunityConfig.lonRange.contains(c.longitude) else {
            throw CommunityError.outsideRegion
        }
        let t = try await token()
        guard let uid = myUid else { throw CommunityError.server("لا يوجد معرّف") }
        let id = UUID().uuidString
        let safeKind: PlaceKind = [.all, .saved].contains(kind) ? .landmark : kind
        let fields: [String: Any] = [
            "name": ["stringValue": trimmed],
            "kind": ["stringValue": safeKind.rawValue],
            "lat": ["doubleValue": c.latitude],
            "lon": ["doubleValue": c.longitude],
            "notes": ["stringValue": String(notes.prefix(300))],
            "authorUid": ["stringValue": uid],
            "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
            "reportCount": ["integerValue": "0"]
        ]
        _ = try await post(URL(string: "\(base)/places?documentId=\(id)")!, body: ["fields": fields], auth: t)
        let place = CommunityPlace(id: id, name: trimmed, kind: safeKind, lat: c.latitude, lon: c.longitude,
                                   notes: String(notes.prefix(300)), authorUid: uid, createdAt: Date(), reportCount: 0)
        places.removeAll { $0.id == id }
        places.append(place)
        saveCache()
        return id
    }

    /// يحذف مشاركة يملكها المستخدم.
    func unpublish(id: String) async throws {
        let t = try await token()
        var req = URLRequest(url: URL(string: "\(base)/places/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 404 else { throw CommunityError.server(Self.message(data, code)) }
        places.removeAll { $0.id == id }
        saveCache()
    }

    /// يبلغ عن مشاركة مخالفة ويخفيها عن هذا المستخدم فورًا.
    func report(_ place: CommunityPlace) async {
        reportedIDs.insert(place.id)
        guard let t = try? await token() else { return }
        let body: [String: Any] = ["writes": [[
            "transform": [
                "document": "projects/\(CommunityConfig.projectID)/databases/(default)/documents/places/\(place.id)",
                "fieldTransforms": [["fieldPath": "reportCount", "increment": ["integerValue": "1"]]]
            ]
        ]]]
        _ = try? await post(URL(string: "\(base):commit")!, body: body, auth: t)
    }

    /// حجب جميع مشاركات مستخدم معيّن على هذا الجهاز.
    func hideAuthor(of place: CommunityPlace) { hiddenAuthors.insert(place.authorUid) }

    /// يجلب المشاركات ضمن منطقة (حسب خط العرض، ثم تصفية خط الطول محليًا).
    func refresh(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, force: Bool = false) async {
        guard isEnabled else { return }
        let box = (sw.latitude, sw.longitude, ne.latitude, ne.longitude)
        if !force, let last = lastFetchBox, Date().timeIntervalSince(lastFetch) < 60,
           box.0 >= last.0, box.1 >= last.1, box.2 <= last.2, box.3 <= last.3 { return }
        // نوسع المنطقة قليلًا لتقليل الطلبات عند التحريك
        let padLat = max(0.2, (ne.latitude - sw.latitude) * 0.5)
        let padLon = max(0.2, (ne.longitude - sw.longitude) * 0.5)
        let q = (sw.latitude - padLat, sw.longitude - padLon, ne.latitude + padLat, ne.longitude + padLon)
        isLoading = true
        defer { isLoading = false }
        let query: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "places"]],
            "where": ["compositeFilter": ["op": "AND", "filters": [
                ["fieldFilter": ["field": ["fieldPath": "lat"], "op": "GREATER_THAN_OR_EQUAL", "value": ["doubleValue": q.0]]],
                ["fieldFilter": ["field": ["fieldPath": "lat"], "op": "LESS_THAN_OR_EQUAL", "value": ["doubleValue": q.2]]]
            ]]],
            "limit": 500
        ]]
        do {
            var req = URLRequest(url: URL(string: "\(base):runQuery?key=\(CommunityConfig.apiKey)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw CommunityError.server(Self.message(data, code)) }
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let fetched = rows.compactMap { ($0["document"] as? [String: Any]).flatMap(Self.parse) }
                .filter { (q.1...q.3).contains($0.lon) }
            // دمج مع ما هو خارج المنطقة من المخزن
            places = places.filter { !((q.0...q.2).contains($0.lat) && (q.1...q.3).contains($0.lon)) } + fetched
            lastFetchBox = q
            lastFetch = Date()
            lastError = nil
            saveCache()
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = nil // دون اتصال: نستخدم المخزن المحلي بصمت
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func places(in sw: CLLocationCoordinate2D, _ ne: CLLocationCoordinate2D) -> [CommunityPlace] {
        visiblePlaces.filter { (sw.latitude...ne.latitude).contains($0.lat) && (sw.longitude...ne.longitude).contains($0.lon) }
    }

    func search(_ query: String, near: CLLocationCoordinate2D?) -> [SearchResult] {
        let key = SearchService.searchKey(query)
        var list = visiblePlaces.filter { key.isEmpty || SearchService.searchKey($0.name).contains(key) }
        if let near { list.sort { GeoMath.distance(near, $0.coordinate) < GeoMath.distance(near, $1.coordinate) } }
        return list.prefix(100).map {
            SearchResult(id: "c-\($0.id)", name: $0.name, subtitle: "مشاركة مجتمعية · \($0.kind.title)", kind: $0.kind,
                         latitude: $0.lat, longitude: $0.lon, source: .community)
        }
    }

    func place(forResultID id: String) -> CommunityPlace? {
        guard id.hasPrefix("c-") else { return nil }
        let pid = String(id.dropFirst(2))
        return places.first { $0.id == pid }
    }

    // MARK: - أدوات

    private func post(_ url: URL, body: [String: Any], auth: String?) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw CommunityError.server(Self.message(data, code)) }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            throw CommunityError.offline
        }
    }

    private static func message(_ data: Data, _ code: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any], let m = err["message"] as? String { return "\(code) \(m)" }
        return "رمز \(code)"
    }

    nonisolated static func parse(_ doc: [String: Any]) -> CommunityPlace? {
        guard let name = doc["name"] as? String, let f = doc["fields"] as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (f[k] as? [String: Any])?["stringValue"] as? String }
        func num(_ k: String) -> Double? {
            let v = f[k] as? [String: Any]
            if let d = v?["doubleValue"] as? Double { return d }
            if let s = v?["integerValue"] as? String { return Double(s) }
            if let i = v?["integerValue"] as? Int { return Double(i) }
            return nil
        }
        guard let title = str("name"), let lat = num("lat"), let lon = num("lon") else { return nil }
        let id = String(name.split(separator: "/").last ?? "")
        let date = ((f["createdAt"] as? [String: Any])?["timestampValue"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0) ?? GPXService.isoFractional.date(from: $0)
        } ?? Date()
        return CommunityPlace(id: id, name: title, kind: PlaceKind(rawValue: str("kind") ?? "") ?? .landmark,
                              lat: lat, lon: lon, notes: str("notes") ?? "", authorUid: str("authorUid") ?? "",
                              createdAt: date, reportCount: Int(num("reportCount") ?? 0))
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("community-cache.json")
    }

    private static func loadCache() -> [CommunityPlace] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([CommunityPlace].self, from: data)) ?? []
    }

    private func saveCache() {
        let list = Array(places.suffix(5000))
        if let data = try? JSONEncoder().encode(list) {
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }
}

/// تخزين بسيط في سلسلة المفاتيح (Keychain) لرمز الجلسة المجهولة.
enum Keychain {
    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                   kSecAttrService as String: "com.almuqbel.ShettaMaps2"]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                kSecAttrService as String: "com.almuqbel.ShettaMaps2",
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
