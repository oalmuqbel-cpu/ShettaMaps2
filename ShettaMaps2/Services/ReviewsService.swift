import Foundation

/// تقييم وتعليق على مكان عام (من الأماكن المعروفة أو مشاركات المجتمع).
struct PlaceReview: Identifiable, Equatable {
    var id: String
    var placeKey: String
    var rating: Int
    var text: String
    var author: String
    var createdAt: Date
    var reportCount: Int
}

/// التقييمات والتعليقات: تقييم واحد لكل مستخدم في كل مكان (يمكن تعديله أو حذفه)، مع بلاغ يخفي المخالف.
@MainActor
final class ReviewsService: ObservableObject {
    static let shared = ReviewsService()
    static let hideAfterReports = 3

    @Published private(set) var reviews: [String: [PlaceReview]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var lastError: String?
    @Published var reportedIDs: Set<String> {
        didSet { UserDefaults.standard.set(Array(reportedIDs), forKey: "reviews.reported") }
    }

    private init() {
        reportedIDs = Set(UserDefaults.standard.stringArray(forKey: "reviews.reported") ?? [])
    }

    /// مفتاح المكان من معرّف العلامة على الخريطة؛ nil للأماكن الخاصة.
    nonisolated static func placeKey(forPinID id: String) -> String? {
        if id.hasPrefix("g-") { return String(id.dropFirst(2)) }   // osm-n123
        if id.hasPrefix("c-") { return id }                       // c-<معرّف المشاركة>
        return nil
    }

    func visible(_ key: String) -> [PlaceReview] {
        (reviews[key] ?? []).filter { $0.reportCount < Self.hideAfterReports && !reportedIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func average(_ key: String) -> Double? {
        let list = visible(key)
        guard !list.isEmpty else { return nil }
        return Double(list.map(\.rating).reduce(0, +)) / Double(list.count)
    }

    func mine(_ key: String) -> PlaceReview? {
        guard let uid = CommunityService.shared.myUid else { return nil }
        return reviews[key]?.first { $0.author == uid }
    }

    func load(_ key: String) async {
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let query: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "reviews"]],
            "where": ["fieldFilter": ["field": ["fieldPath": "placeKey"], "op": "EQUAL", "value": ["stringValue": key]]],
            "limit": 200
        ]]
        do {
            var req = URLRequest(url: URL(string: "\(CommunityService.shared.base):runQuery?key=\(CommunityConfig.apiKey)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
            let (data, resp) = try await CommunityService.shared.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw CommunityError.server(CommunityService.message(data, status)) }
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            reviews[key] = rows.compactMap { ($0["document"] as? [String: Any]).flatMap(Self.parse) }
            lastError = nil
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = "التقييمات تحتاج اتصالًا بالإنترنت."
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// ينشئ تقييمي أو يعدله.
    func submit(key: String, placeName: String, rating: Int, text: String) async -> Bool {
        do {
            let token = try await CommunityService.shared.token()
            guard let uid = CommunityService.shared.myUid else { return false }
            let existing = mine(key)
            let fields: [String: Any] = [
                "placeKey": ["stringValue": key],
                "placeName": ["stringValue": String(placeName.prefix(60))],
                "rating": ["integerValue": "\(max(1, min(5, rating)))"],
                "text": ["stringValue": String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))],
                "author": ["stringValue": uid],
                "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())],
                "reportCount": ["integerValue": "\(existing?.reportCount ?? 0)"]
            ]
            let docID = "\(key)__\(uid)"
            var req = URLRequest(url: URL(string: "\(CommunityService.shared.base)/reviews/\(docID)")!)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
            let (data, resp) = try await CommunityService.shared.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw CommunityError.server(CommunityService.message(data, status)) }
            lastError = nil
            await load(key)
            return true
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = "إرسال التقييم يحتاج اتصالًا بالإنترنت."
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return false
    }

    func deleteMine(key: String) async {
        guard let uid = CommunityService.shared.myUid, let token = try? await CommunityService.shared.token() else { return }
        var req = URLRequest(url: URL(string: "\(CommunityService.shared.base)/reviews/\(key)__\(uid)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await CommunityService.shared.session.data(for: req)
        await load(key)
    }

    /// بلاغ عن تعليق مخالف: يُخفى عندي فورًا، ويُخفى للجميع بعد ٣ بلاغات.
    func report(_ r: PlaceReview) async {
        reportedIDs.insert(r.id)
        guard let token = try? await CommunityService.shared.token() else { return }
        let body: [String: Any] = ["writes": [[
            "transform": [
                "document": "projects/\(CommunityConfig.projectID)/databases/(default)/documents/reviews/\(r.id)",
                "fieldTransforms": [["fieldPath": "reportCount", "increment": ["integerValue": "1"]]]
            ]
        ]]]
        _ = try? await CommunityService.shared.post(URL(string: "\(CommunityService.shared.base):commit")!, body: body, auth: token)
    }

    func clearError() { lastError = nil }

    nonisolated static func parse(_ doc: [String: Any]) -> PlaceReview? {
        guard let name = doc["name"] as? String, let f = doc["fields"] as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (f[k] as? [String: Any])?["stringValue"] as? String }
        func int(_ k: String) -> Int? { ((f[k] as? [String: Any])?["integerValue"] as? String).flatMap(Int.init) }
        guard let key = str("placeKey"), let rating = int("rating"), let author = str("author") else { return nil }
        let date = ((f["createdAt"] as? [String: Any])?["timestampValue"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0) ?? GPXService.isoFractional.date(from: $0)
        } ?? Date()
        return PlaceReview(id: String(name.split(separator: "/").last ?? ""), placeKey: key, rating: rating,
                           text: str("text") ?? "", author: author, createdAt: date, reportCount: int("reportCount") ?? 0)
    }
}
