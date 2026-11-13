import Foundation
import CoreLocation

/// مسار شاركه أحد المستخدمين مع المجتمع.
struct CommunityTrack: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var notes: String
    var authorUid: String
    var createdAt: Date
    var reportCount: Int
    var distance: Double
    var polyline: String
    var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    var coordinates: [CLLocationCoordinate2D] { PolylineCodec.decode(polyline) }
    var start: CLLocationCoordinate2D? { coordinates.first }
    func intersects(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> Bool {
        !(maxLat < sw.latitude || minLat > ne.latitude || maxLon < sw.longitude || minLon > ne.longitude)
    }
}

enum CommunityTrackLimits {
    static let maxPoints = 1_500
    static let privacyTrimMeters = 400.0
    static let maxNotes = 500
    static let maxPolylineChars = 60_000
}

/// مخزن مسارات المجتمع (مستقل عن الأماكن حتى لا يثقل جلب الأماكن).
@MainActor
final class CommunityTrackStore: ObservableObject {
    static let shared = CommunityTrackStore()
    @Published private(set) var tracks: [CommunityTrack] = []
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false
    private var lastFetch = Date.distantPast
    private var lastBox: (Double, Double, Double, Double)?
    private let community = CommunityService.shared
    private var decodedCache: [String: [CLLocationCoordinate2D]] = [:]

    /// إحداثيات المسار مع ذاكرة مؤقتة لتجنب فك الترميز في كل رسم.
    func coordinates(of t: CommunityTrack) -> [CLLocationCoordinate2D] {
        if let c = decodedCache[t.id] { return c }
        let c = t.coordinates
        if decodedCache.count > 300 { decodedCache.removeAll() }
        decodedCache[t.id] = c
        return c
    }

    private init() { tracks = Self.loadCache() }

    var visibleTracks: [CommunityTrack] {
        tracks.filter { $0.reportCount < CommunityConfig.hideAfterReports && !community.hiddenAuthors.contains($0.authorUid)
            && !community.reportedIDs.contains($0.id) }
    }

    func tracks(in sw: CLLocationCoordinate2D, _ ne: CLLocationCoordinate2D) -> [CommunityTrack] {
        visibleTracks.filter { $0.intersects(sw: sw, ne: ne) }
    }

    /// يجهّز المسار للنشر: إزالة أول وآخر 400 م، ثم تبسيطه.
    nonisolated static func prepare(_ coords: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let trimmed = PolylineCodec.trimEnds(coords, meters: CommunityTrackLimits.privacyTrimMeters)
        return PolylineCodec.simplify(trimmed, maxPoints: CommunityTrackLimits.maxPoints)
    }

    func publish(name: String, notes: String, coordinates: [CLLocationCoordinate2D]) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...60).contains(trimmed.count) else { throw CommunityError.invalidName }
        let pts = Self.prepare(coordinates)
        guard pts.count >= 2 else { throw CommunityError.server("المسار قصير جدًا للمشاركة بعد إخفاء بدايته ونهايته") }
        guard let box = GeoMath.boundingBox(pts),
              CommunityConfig.latRange.contains(box.sw.latitude), CommunityConfig.latRange.contains(box.ne.latitude),
              CommunityConfig.lonRange.contains(box.sw.longitude), CommunityConfig.lonRange.contains(box.ne.longitude) else {
            throw CommunityError.outsideRegion
        }
        let poly = PolylineCodec.encode(pts)
        guard poly.count <= CommunityTrackLimits.maxPolylineChars else { throw CommunityError.server("المسار طويل جدًا") }
        var dist = 0.0
        for i in 1..<pts.count { dist += GeoMath.distance(pts[i - 1], pts[i]) }
        let t = try await community.token()
        guard let uid = community.myUid else { throw CommunityError.server("لا يوجد معرّف") }
        let id = UUID().uuidString
        let note = String(notes.prefix(CommunityTrackLimits.maxNotes))
        let fields: [String: Any] = [
            "name": ["stringValue": trimmed],
            "notes": ["stringValue": note],
            "authorUid": ["stringValue": uid],
            "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
            "reportCount": ["integerValue": "0"],
            "distance": ["doubleValue": dist],
            "polyline": ["stringValue": poly],
            "minLat": ["doubleValue": box.sw.latitude], "maxLat": ["doubleValue": box.ne.latitude],
            "minLon": ["doubleValue": box.sw.longitude], "maxLon": ["doubleValue": box.ne.longitude]
        ]
        _ = try await community.post(URL(string: "\(community.base)/tracks?documentId=\(id)")!, body: ["fields": fields], auth: t)
        let track = CommunityTrack(id: id, name: trimmed, notes: note, authorUid: uid, createdAt: Date(), reportCount: 0,
                                   distance: dist, polyline: poly, minLat: box.sw.latitude, maxLat: box.ne.latitude,
                                   minLon: box.sw.longitude, maxLon: box.ne.longitude)
        tracks.removeAll { $0.id == id }
        tracks.append(track)
        saveCache()
        return id
    }

    func unpublish(id: String) async throws {
        let t = try await community.token()
        var req = URLRequest(url: URL(string: "\(community.base)/tracks/\(id)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await community.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 404 else { throw CommunityError.server(CommunityService.message(data, code)) }
        tracks.removeAll { $0.id == id }
        saveCache()
    }

    func report(_ track: CommunityTrack) async {
        community.reportedIDs.insert(track.id)
        guard let t = try? await community.token() else { return }
        let body: [String: Any] = ["writes": [[
            "transform": [
                "document": "projects/\(CommunityConfig.projectID)/databases/(default)/documents/tracks/\(track.id)",
                "fieldTransforms": [["fieldPath": "reportCount", "increment": ["integerValue": "1"]]]
            ]
        ]]]
        _ = try? await community.post(URL(string: "\(community.base):commit")!, body: body, auth: t)
    }

    /// يجلب المسارات التي تتقاطع مع المنطقة: استعلام على minLat ثم تصفية محلية.
    func refresh(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, force: Bool = false) async {
        guard community.isEnabled else { return }
        let padLat = max(0.3, (ne.latitude - sw.latitude) * 0.5), padLon = max(0.3, (ne.longitude - sw.longitude) * 0.5)
        let q = (sw.latitude - padLat, sw.longitude - padLon, ne.latitude + padLat, ne.longitude + padLon)
        if !force, let l = lastBox, Date().timeIntervalSince(lastFetch) < 90,
           sw.latitude >= l.0, sw.longitude >= l.1, ne.latitude <= l.2, ne.longitude <= l.3 { return }
        isLoading = true
        defer { isLoading = false }
        // مسار يتقاطع مع المنطقة يبدأ جنوب حدها الشمالي، ولا يزيد امتداده عادة عن درجتين
        let query: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "tracks"]],
            "where": ["compositeFilter": ["op": "AND", "filters": [
                ["fieldFilter": ["field": ["fieldPath": "minLat"], "op": "GREATER_THAN_OR_EQUAL", "value": ["doubleValue": q.0 - 2]]],
                ["fieldFilter": ["field": ["fieldPath": "minLat"], "op": "LESS_THAN_OR_EQUAL", "value": ["doubleValue": q.2]]]
            ]]],
            "limit": 200
        ]]
        do {
            var req = URLRequest(url: URL(string: "\(community.base):runQuery?key=\(CommunityConfig.apiKey)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
            let (data, resp) = try await community.session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw CommunityError.server(CommunityService.message(data, code)) }
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let swq = CLLocationCoordinate2D(latitude: q.0, longitude: q.1), neq = CLLocationCoordinate2D(latitude: q.2, longitude: q.3)
            let fetched = rows.compactMap { ($0["document"] as? [String: Any]).flatMap(Self.parse) }
                .filter { $0.intersects(sw: swq, ne: neq) }
            let ids = Set(fetched.map(\.id))
            tracks = tracks.filter { !ids.contains($0.id) && !$0.intersects(sw: swq, ne: neq) } + fetched
            lastBox = q
            lastFetch = Date()
            lastError = nil
            saveCache()
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = nil
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    nonisolated static func parse(_ doc: [String: Any]) -> CommunityTrack? {
        guard let name = doc["name"] as? String, let f = doc["fields"] as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (f[k] as? [String: Any])?["stringValue"] as? String }
        func num(_ k: String) -> Double? {
            let v = f[k] as? [String: Any]
            if let d = v?["doubleValue"] as? Double { return d }
            if let s = v?["integerValue"] as? String { return Double(s) }
            return nil
        }
        guard let title = str("name"), let poly = str("polyline"), let a = num("minLat"), let b = num("maxLat"),
              let c = num("minLon"), let d = num("maxLon") else { return nil }
        let date = ((f["createdAt"] as? [String: Any])?["timestampValue"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0) ?? GPXService.isoFractional.date(from: $0)
        } ?? Date()
        return CommunityTrack(id: String(name.split(separator: "/").last ?? ""), name: title, notes: str("notes") ?? "",
                              authorUid: str("authorUid") ?? "", createdAt: date, reportCount: Int(num("reportCount") ?? 0),
                              distance: num("distance") ?? 0, polyline: poly, minLat: a, maxLat: b, minLon: c, maxLon: d)
    }

    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("community-tracks-cache.json")
    }
    private static func loadCache() -> [CommunityTrack] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([CommunityTrack].self, from: data)) ?? []
    }
    private func saveCache() {
        if let data = try? JSONEncoder().encode(Array(tracks.suffix(1000))) {
            try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }
}
