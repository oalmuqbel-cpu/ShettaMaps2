import Foundation
import CoreLocation
import UserNotifications

/// الرحلة الآمنة: يحدّث التطبيق آخر موقع معروف كلما توفر الإنترنت، ويتابعه من أرسلت له الرابط.
/// إذا تجاوزت المدة المحددة دون تحديث، تعرض صفحة المتابعة تنبيهًا واضحًا مع آخر موقع معروف.
/// لا يرسل التطبيق أي رسالة بنفسه: Apple لا تسمح بإرسال الرسائل دون ضغط المستخدم، ودون شبكة لا يمكن الإرسال أصلًا.
@MainActor
final class SafeTripManager: ObservableObject {
    static let shared = SafeTripManager()
    nonisolated static let pageBase = "https://oalmuqbel-cpu.github.io/ShettaMaps2/safe/"

    struct State: Codable, Equatable {
        var token: String
        var name: String
        var contact: String
        var hours: Int
        var startedAt: Date
        var lastUploadAt: Date?
        var lastUploadLat: Double?
        var lastUploadLon: Double?
        /// من أضفتهم بمعرّف سَمْت ليتابعوك من تطبيقهم.
        var watchers: [SamtContact]?
    }

    @Published private(set) var state: State? {
        didSet { save() }
    }
    @Published private(set) var lastError: String?
    @Published private(set) var isUploading = false

    var isActive: Bool { state != nil }
    var link: URL? { state.flatMap { URL(string: Self.pageBase + "?t=" + $0.token) } }

    private var pendingLocation: CLLocation?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "safeTrip.state") {
            state = try? JSONDecoder().decode(State.self, from: d)
        }
    }

    private func save() {
        if let s = state, let d = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(d, forKey: "safeTrip.state")
        } else {
            UserDefaults.standard.removeObject(forKey: "safeTrip.state")
        }
    }

    /// صيغة العدد العربية للساعات.
    nonisolated static func hoursText(_ n: Int) -> String {
        switch n {
        case 1: return "ساعة"
        case 2: return "ساعتين"
        case 3...10: return "\(n) ساعات"
        default: return "\(n) ساعة"
        }
    }

    /// «منذ» بصيغة عربية: دقائق أو ساعات ودقائق أو أيام.
    nonisolated static func agoText(_ seconds: TimeInterval) -> String {
        let m = max(0, Int(seconds / 60))
        func count(_ n: Int, _ one: String, _ two: String, _ few: String) -> String {
            n == 1 ? one : n == 2 ? two : (3...10).contains(n) ? "\(n) \(few)" : "\(n) \(one)"
        }
        if m < 1 { return "أقل من دقيقة" }
        if m < 60 { return count(m, "دقيقة", "دقيقتين", "دقائق") }
        let h = m / 60, r = m % 60
        if h < 48 { return hoursText(h) + (r > 0 ? " و" + count(r, "دقيقة", "دقيقتين", "دقائق") : "") }
        return count(h / 24, "يوم", "يومين", "أيام")
    }

    nonisolated static func makeToken() -> String {
        let chars = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var out = ""
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<24 { out.append(chars[Int(rng.next() % UInt64(chars.count))]) }
        return out
    }

    /// يبدأ رحلة آمنة ويعيد نص الرسالة المقترح إرسالها لجهة الاتصال.
    @discardableResult
    func start(name: String, contact: String, hours: Int, watchers: [SamtContact] = [], location: CLLocation?) -> String {
        let s = State(token: Self.makeToken(), name: String(name.trimmingCharacters(in: .whitespaces).prefix(40)),
                      contact: contact, hours: max(1, min(72, hours)), startedAt: Date(), watchers: Array(watchers.prefix(10)))
        state = s
        lastError = nil
        scheduleReminder()
        if let location { pendingLocation = location; Task { await upload(force: true) } }
        return message
    }

    /// نص الرسالة لجهة الاتصال.
    /// تعديل المتابعين أثناء الرحلة.
    func setWatchers(_ list: [SamtContact]) {
        guard var s = state else { return }
        s.watchers = Array(list.prefix(10))
        state = s
        Task { await upload(force: true) }
    }

    var message: String {
        guard let s = state, let link else { return "" }
        let who = s.name.isEmpty ? "أنا" : s.name
        return """
        \(who) في رحلة برية، وهذا رابط متابعة آخر موقع معروف (يتحدث كلما توفر الإنترنت):
        \(link.absoluteString)
        إذا لم يتحدث الموقع خلال \(Self.hoursText(s.hours))، حاول التواصل، وإن تعذر فتواصل مع الطوارئ 911 أو فريق إنجاد للبحث والإنقاذ 920018911.
        """
    }

    /// تحديث الموقع: فوري عند أول اتصال بعد انقطاع، ثم كل ٥ دقائق أو عند الابتعاد أكثر من كيلومتر.
    func observe(_ loc: CLLocation) {
        guard let s = state, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 500 else { return }
        pendingLocation = loc
        let moved: Double = {
            guard let la = s.lastUploadLat, let lo = s.lastUploadLon else { return .infinity }
            return GeoMath.distance(.init(latitude: la, longitude: lo), loc.coordinate)
        }()
        let age = s.lastUploadAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 300 || moved > 1000 else { return }
        guard NetworkMonitor.shared.isOnline else { return }
        Task { await upload(force: false) }
    }

    /// عند عودة الاتصال يُرفع آخر موقع مباشرة.
    func networkBecameAvailable() {
        guard isActive else { return }
        Task { await upload(force: true) }
    }

    func upload(force: Bool, active: Bool = true) async {
        guard var s = state, !isUploading, let loc = pendingLocation ?? LocationManager.shared.location else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let token = try await CommunityService.shared.token()
            guard let uid = CommunityService.shared.myUid else { return }
            let iso = ISO8601DateFormatter()
            var fields: [String: Any] = [
                "owner": ["stringValue": uid],
                "name": ["stringValue": s.name],
                "hours": ["integerValue": "\(s.hours)"],
                "startedAt": ["timestampValue": iso.string(from: s.startedAt)],
                "updatedAt": ["timestampValue": iso.string(from: loc.timestamp)],
                "lat": ["doubleValue": loc.coordinate.latitude],
                "lon": ["doubleValue": loc.coordinate.longitude],
                "acc": ["doubleValue": max(0, loc.horizontalAccuracy)],
                "active": ["booleanValue": active]
            ]
            if !active { fields["endedAt"] = ["timestampValue": iso.string(from: Date())] }
            let uids = (s.watchers ?? []).map(\.uid)
            fields["watchers"] = ["arrayValue": uids.isEmpty ? [:] : ["values": uids.map { ["stringValue": $0] }]]
            if let code = FollowService.shared.myCode { fields["code"] = ["stringValue": code] }
            var req = URLRequest(url: URL(string: "\(CommunityService.shared.base)/safetrips/\(s.token)")!)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
            let (data, resp) = try await CommunityService.shared.session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw CommunityError.server(CommunityService.message(data, code)) }
            s.lastUploadAt = Date()
            s.lastUploadLat = loc.coordinate.latitude
            s.lastUploadLon = loc.coordinate.longitude
            if active { state = s }
            lastError = nil
            scheduleReminder()
        } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            // دون اتصال: يُعاد المحاولة عند عودة الشبكة
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// إنهاء الرحلة: تظهر في صفحة المتابعة أنك وصلت بالسلامة.
    func end() async {
        guard state != nil else { return }
        await upload(force: true, active: false)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["samt-safetrip"])
        state = nil
    }

    /// تذكير قبل انتهاء المهلة بساعة إن لم يتحدث الموقع، حتى تنهي الرحلة أو تتصل بجهة الاتصال.
    private func scheduleReminder() {
        guard let s = state else { return }
        let base = s.lastUploadAt ?? s.startedAt
        let fire = base.addingTimeInterval(Double(s.hours) * 3600 - 3600)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["samt-safetrip"])
        guard fire > Date().addingTimeInterval(60) else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "الرحلة الآمنة"
            c.body = "بقيت ساعة على انتهاء المهلة دون تحديث لموقعك. إذا وصلت فأنهِ الرحلة، أو طمئن جهة الاتصال إن توفرت شبكة."
            c.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            center.add(UNNotificationRequest(identifier: "samt-safetrip", content: c, trigger: trigger))
        }
    }
}
