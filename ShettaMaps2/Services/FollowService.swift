import Foundation
import CoreLocation
import UserNotifications
import BackgroundTasks

/// شخص محفوظ يمكن إضافته متابعًا للرحلة الآمنة (بمعرّف سَمْت).
struct SamtContact: Codable, Identifiable, Hashable {
    var code: String
    var uid: String
    var name: String
    var id: String { code }
}

/// رحلة آمنة لشخص أتابعه (أضافني بمعرّفي).
struct FollowedTrip: Identifiable, Equatable {
    var id: String          // رمز الرحلة
    var name: String
    var hours: Int
    var startedAt: Date
    var updatedAt: Date
    var lat: Double
    var lon: Double
    var acc: Double
    var active: Bool
    var endedAt: Date?

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var deadline: Date { updatedAt.addingTimeInterval(Double(hours) * 3600) }
    var isLate: Bool { active && Date() > deadline }
    var displayName: String { name.isEmpty ? "مسافر" : name }
}

/// معرّف سَمْت وقائمة جهات المتابعة ومتابعة الآخرين، مع تنبيه محلي على جوال المتابع
/// إذا تجاوزت الرحلة المدة دون تحديث (دون خادم: التطبيق نفسه يجدول التنبيه).
@MainActor
final class FollowService: ObservableObject {
    static let shared = FollowService()
    nonisolated static let refreshTaskID = "com.almuqbel.ShettaMaps2.follow-refresh"

    @Published private(set) var myCode: String?
    @Published private(set) var contacts: [SamtContact] = [] {
        didSet { if let d = try? JSONEncoder().encode(contacts) { UserDefaults.standard.set(d, forKey: "follow.contacts") } }
    }
    @Published private(set) var trips: [FollowedTrip] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastRefresh: Date?

    private var refreshing = false

    private init() {
        myCode = Keychain.get("samt.code") ?? UserDefaults.standard.string(forKey: "samt.code")
        if let d = UserDefaults.standard.data(forKey: "follow.contacts"),
           let list = try? JSONDecoder().decode([SamtContact].self, from: d) { contacts = list }
    }

    var lateTrips: [FollowedTrip] { trips.filter(\.isLate) }
    var activeTrips: [FollowedTrip] { trips.filter(\.active) }

    nonisolated static func normalize(_ code: String) -> String {
        let allowed = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(code.uppercased().filter { allowed.contains($0) }.prefix(8))
    }

    nonisolated static func pretty(_ code: String) -> String {
        code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }

    // MARK: - معرّفي

    /// ينشئ معرّفًا قصيرًا فريدًا ويسجله (يحتاج إنترنت مرة واحدة).
    func ensureMyCode() async {
        if myCode != nil { return }
        do {
            let token = try await CommunityService.shared.token()
            guard let uid = CommunityService.shared.myUid else { return }
            let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            for _ in 0..<5 {
                var rng = SystemRandomNumberGenerator()
                let code = String((0..<8).map { _ in chars[Int(rng.next() % UInt64(chars.count))] })
                let body: [String: Any] = ["fields": [
                    "uid": ["stringValue": uid],
                    "createdAt": ["timestampValue": ISO8601DateFormatter().string(from: Date())]
                ]]
                var req = URLRequest(url: URL(string: "\(CommunityService.shared.base)/codes?documentId=\(code)")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, resp) = try await CommunityService.shared.session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) {
                    Keychain.set(code, for: "samt.code")
                    UserDefaults.standard.set(code, forKey: "samt.code")
                    myCode = code
                    lastError = nil
                    return
                }
                if status != 409 { throw CommunityError.server(CommunityService.message(data, status)) }
            }
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = "يحتاج إنشاء المعرّف اتصالًا بالإنترنت مرة واحدة."
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - جهات المتابعة

    /// يضيف شخصًا بمعرّفه بعد التحقق منه.
    func addContact(code raw: String, name: String) async -> Bool {
        let code = Self.normalize(raw)
        guard code.count == 8 else { lastError = "المعرّف يتكون من 8 خانات."; return false }
        guard code != myCode else { lastError = "هذا معرّفك أنت."; return false }
        do {
            var req = URLRequest(url: URL(string: "\(CommunityService.shared.base)/codes/\(code)?key=\(CommunityConfig.apiKey)")!)
            req.httpMethod = "GET"
            let (data, resp) = try await CommunityService.shared.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { lastError = "لا يوجد مستخدم بهذا المعرّف. تأكد من كتابته كما يظهر في تطبيقه."; return false }
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let f = json["fields"] as? [String: Any],
                  let uid = (f["uid"] as? [String: Any])?["stringValue"] as? String else {
                throw CommunityError.server(CommunityService.message(data, status))
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            contacts.removeAll { $0.code == code }
            contacts.append(SamtContact(code: code, uid: uid, name: trimmed.isEmpty ? Self.pretty(code) : String(trimmed.prefix(30))))
            lastError = nil
            return true
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            lastError = "إضافة شخص تحتاج اتصالًا بالإنترنت للتحقق من معرّفه."
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        return false
    }

    func removeContact(_ c: SamtContact) { contacts.removeAll { $0.code == c.code } }

    func clearError() { lastError = nil }

    // MARK: - متابعة الآخرين

    /// يجلب رحلات من أضافوني متابعًا، ويجدول تنبيه التأخر لكل رحلة نشطة.
    func refresh() async {
        guard !refreshing, CommunityService.shared.isEnabled else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let token = try await CommunityService.shared.token()
            guard let uid = CommunityService.shared.myUid else { return }
            let query: [String: Any] = ["structuredQuery": [
                "from": [["collectionId": "safetrips"]],
                "where": ["fieldFilter": ["field": ["fieldPath": "watchers"], "op": "ARRAY_CONTAINS", "value": ["stringValue": uid]]],
                "limit": 50
            ]]
            var req = URLRequest(url: URL(string: "\(CommunityService.shared.base):runQuery")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
            let (data, resp) = try await CommunityService.shared.session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw CommunityError.server(CommunityService.message(data, status)) }
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let cutoff = Date().addingTimeInterval(-3 * 86_400)
            let fresh = rows.compactMap { ($0["document"] as? [String: Any]).flatMap(Self.parse) }
                .filter { $0.active || ($0.endedAt ?? $0.updatedAt) > cutoff }
                .sorted { ($0.active ? 0 : 1, -$0.updatedAt.timeIntervalSince1970) < ($1.active ? 0 : 1, -$1.updatedAt.timeIntervalSince1970) }
            notifyChanges(old: trips, new: fresh)
            trips = fresh
            lastRefresh = Date()
            lastError = nil
            scheduleLateAlerts()
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            // دون اتصال: تبقى آخر بيانات وتنبيهات مجدولة كما هي
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// إشعارات فورية عند بدء رحلة جديدة أو انتهائها بسلام.
    private func notifyChanges(old: [FollowedTrip], new: [FollowedTrip]) {
        guard lastRefresh != nil else { return }  // لا إشعارات عند أول جلب بعد التشغيل
        for t in new {
            let before = old.first { $0.id == t.id }
            if before == nil, t.active {
                post(id: "follow-start-\(t.id)", title: "رحلة آمنة",
                     body: "\(t.displayName) بدأ رحلة وأضافك متابعًا. ستصلك ملاحظة إذا تأخر تحديث موقعه أكثر من \(SafeTripManager.hoursText(t.hours)).")
            } else if let b = before, b.active, !t.active {
                post(id: "follow-end-\(t.id)", title: "وصل بالسلامة", body: "\(t.displayName) أنهى رحلته الآمنة.")
            }
        }
    }

    /// تنبيه محلي على هذا الجوال عند انتهاء المدة دون تحديث؛ يُعاد جدولته مع كل تحديث جديد.
    private func scheduleLateAlerts() {
        let center = UNUserNotificationCenter.current()
        let prefix = "follow-late-"
        center.getPendingNotificationRequests { reqs in
            let stale = reqs.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        for t in trips where t.active {
            let id = prefix + t.id
            let body = "\(t.displayName) لم يتحدث موقعه منذ \(SafeTripManager.hoursText(t.hours)). آخر موقع معروف محفوظ في «أتابعهم»: حاول التواصل معه، وإن تعذر فتواصل مع الطوارئ 911 أو فريق إنجاد 920018911."
            if t.deadline > Date().addingTimeInterval(5) {
                post(id: id, title: "تأخر تحديث رحلة \(t.displayName)", body: body, at: t.deadline)
            }
        }
    }

    private func post(id: String, title: String, body: String, at date: Date? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: max(5, $0.timeIntervalSinceNow), repeats: false) }
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
        }
    }

    nonisolated static func parse(_ doc: [String: Any]) -> FollowedTrip? {
        guard let name = doc["name"] as? String, let f = doc["fields"] as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (f[k] as? [String: Any])?["stringValue"] as? String }
        func num(_ k: String) -> Double? {
            let v = f[k] as? [String: Any]
            if let d = v?["doubleValue"] as? Double { return d }
            if let s = v?["integerValue"] as? String { return Double(s) }
            return nil
        }
        func date(_ k: String) -> Date? {
            ((f[k] as? [String: Any])?["timestampValue"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0) ?? GPXService.isoFractional.date(from: $0)
            }
        }
        guard let lat = num("lat"), let lon = num("lon"), let updated = date("updatedAt") else { return nil }
        let active = ((f["active"] as? [String: Any])?["booleanValue"] as? Bool) ?? false
        return FollowedTrip(id: String(name.split(separator: "/").last ?? ""), name: str("name") ?? "",
                            hours: Int(num("hours") ?? 6), startedAt: date("startedAt") ?? updated, updatedAt: updated,
                            lat: lat, lon: lon, acc: num("acc") ?? 0, active: active, endedAt: date("endedAt"))
    }

    #if DEBUG
    /// بيانات عرض للقطات الشاشة فقط.
    func injectDemo(around c: CLLocationCoordinate2D) {
        let now = Date()
        trips = [
            FollowedTrip(id: "demo-late", name: "محمد", hours: 6, startedAt: now.addingTimeInterval(-9 * 3600),
                         updatedAt: now.addingTimeInterval(-7 * 3600), lat: c.latitude + 0.05, lon: c.longitude + 0.06,
                         acc: 10, active: true, endedAt: nil),
            FollowedTrip(id: "demo-ok", name: "عبدالله", hours: 9, startedAt: now.addingTimeInterval(-3 * 3600),
                         updatedAt: now.addingTimeInterval(-40 * 60), lat: c.latitude - 0.03, lon: c.longitude + 0.02,
                         acc: 8, active: true, endedAt: nil)
        ]
        lastRefresh = now
    }
    #endif

    // MARK: - التحديث في الخلفية

    nonisolated static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            scheduleBackgroundRefresh()
            let work = Task { @MainActor in
                await FollowService.shared.refresh()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// يطلب من النظام تحديثًا في الخلفية (التوقيت يحدده iOS).
    nonisolated static func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
