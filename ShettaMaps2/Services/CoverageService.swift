import Foundation
import SwiftUI
import CoreLocation
import CoreTelephony
import Network

/// حالة الشبكة في مربع من الخريطة.
enum CoverageLevel: String, CaseIterable, Codable {
    /// إنترنت عبر شبكة الجوال.
    case data
    /// إشارة اتصال ورسائل دون إنترنت.
    case voice
    /// لا توجد شبكة.
    case none

    var title: String {
        switch self {
        case .data: return "فيه إنترنت"
        case .voice: return "اتصال ورسائل فقط"
        case .none: return "ما فيه شبكة"
        }
    }
    var uiColor: UIColor {
        switch self {
        case .data: return UIColor(red: 0.16, green: 0.62, blue: 0.30, alpha: 1)
        case .voice: return UIColor(red: 0.95, green: 0.65, blue: 0.10, alpha: 1)
        case .none: return UIColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 1)
        }
    }
    var color: Color { Color(uiColor: uiColor) }
    var icon: String {
        switch self {
        case .data: return "antenna.radiowaves.left.and.right"
        case .voice: return "phone"
        case .none: return "antenna.radiowaves.left.and.right.slash"
        }
    }
    /// للترتيب عند دمج عدة قياسات: الأفضل أولًا.
    var rank: Int { self == .data ? 2 : (self == .voice ? 1 : 0) }
}

/// شركات الاتصال في المملكة مع روابط خرائط التغطية الرسمية.
enum Carrier: String, CaseIterable, Identifiable, Codable {
    case stc, mobily, zain, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stc: return "STC"
        case .mobily: return "موبايلي"
        case .zain: return "زين"
        case .other: return "أخرى"
        }
    }
    /// صفحة خريطة التغطية الرسمية للشركة.
    var coverageURL: URL? {
        switch self {
        case .stc: return URL(string: "https://www.stc.com.sa/content/stc/sa/en/personal/support/contact-us/business-offices-coverage-maps.html#coveragemaps")
        case .mobily: return URL(string: "https://www.mobily.com.sa/wps/portal/web/coverage-check")
        case .zain: return URL(string: "https://sa.zain.com/en/coverage-map")
        case .other: return nil
        }
    }
    static let regulatorURL = URL(string: "https://www.cst.gov.sa/ar/services/Coverage-Maps")!
    static var mine: Carrier? {
        Carrier(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.coverageCarrier) ?? "")
    }
}

/// مربع تغطية (قرابة ٥٥٠ م) بعد دمج القياسات والبلاغات.
struct CoverageCell: Identifiable, Equatable {
    var id: String
    var lat: Double
    var lon: Double
    var level: CoverageLevel
    var carrier: Carrier
    var count: Int
    var latest: Date
    var radio: String?
    var hasManualReport: Bool

    var corners: [CLLocationCoordinate2D] {
        let s = CoverageService.cellSize
        return [.init(latitude: lat, longitude: lon), .init(latitude: lat + s, longitude: lon),
                .init(latitude: lat + s, longitude: lon + s), .init(latitude: lat, longitude: lon + s)]
    }
    var center: CLLocationCoordinate2D {
        .init(latitude: lat + CoverageService.cellSize / 2, longitude: lon + CoverageService.cellSize / 2)
    }
}

/// قياس واحد (تلقائي أو بلاغ يدوي) قبل الدمج.
struct CoverageSample: Codable, Equatable {
    var cell: String
    var lat: Double
    var lon: Double
    var carrier: Carrier
    var level: CoverageLevel
    var radio: String?
    var source: String   // auto أو manual
    var at: Date
}

/// خريطة تغطية الشبكة من قياسات المستخدمين الفعلية وبلاغاتهم. المشاركة اختيارية ومجهولة:
/// يُرسل المربع وحالة الشبكة ونوعها والشركة فقط، دون الموقع الدقيق أو المسار أو أي هوية.
@MainActor
final class CoverageService: ObservableObject {
    static let shared = CoverageService()
    nonisolated static let cellSize = 0.005

    @Published private(set) var cells: [String: CoverageCell] = [:]
    @Published private(set) var lastMeasured: (CoverageLevel, String?, Date)?
    @Published private(set) var pendingCount = 0

    private var samples: [CoverageSample] = []   // بانتظار الرفع
    private var fetched: [CoverageSample] = []   // من الخادم ومن قياساتي
    private let telephony = CTTelephonyNetworkInfo()
    private let monitor = NWPathMonitor()
    private var cellularOK = false
    private var wifi = false
    private var lastSampleCell: String?
    private var lastSampleTime = Date.distantPast
    private var lastFetchBox: (Double, Double, Double, Double)?
    private var lastFetch = Date.distantPast
    private var uploading = false

    var contributes: Bool { UserDefaults.standard.bool(forKey: SettingsKeys.coverageContribute) }

    private init() {
        samples = Self.load(Self.pendingURL)
        fetched = Self.load(Self.cacheURL)
        pendingCount = samples.count
        rebuild()
        monitor.pathUpdateHandler = { [weak self] path in
            let cell = path.status == .satisfied && path.usesInterfaceType(.cellular)
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                self?.cellularOK = cell
                self?.wifi = wifi
                if path.status == .satisfied { await self?.uploadPending() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ShettaMaps2.coverage"))
    }

    nonisolated static func cellKey(_ c: CLLocationCoordinate2D) -> (String, Double, Double) {
        let la = (c.latitude / cellSize).rounded(.down) * cellSize
        let lo = (c.longitude / cellSize).rounded(.down) * cellSize
        return (String(format: "%.3f_%.3f", la, lo), la, lo)
    }

    /// تقنية الشبكة الحالية من نظام iOS (لا يكشف اسم الشركة ولا قوة الإشارة).
    private var radioTech: String? {
        guard let tech = telephony.serviceCurrentRadioAccessTechnology?.values.first else { return nil }
        switch tech {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA: return "5G"
        case CTRadioAccessTechnologyLTE: return "4G"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x: return "2G"
        default: return "3G"
        }
    }

    /// يُستدعى مع تحديثات الموقع: قياس كل دقيقتين أو عند دخول مربع جديد.
    func observe(_ loc: CLLocation) {
        guard contributes, let carrier = Carrier.mine, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 100,
              CommunityConfig.latRange.contains(loc.coordinate.latitude),
              CommunityConfig.lonRange.contains(loc.coordinate.longitude) else { return }
        // على شبكة Wi-Fi لا نعرف حال شبكة الجوال بدقة
        guard !wifi else { return }
        let (key, la, lo) = Self.cellKey(loc.coordinate)
        guard key != lastSampleCell || Date().timeIntervalSince(lastSampleTime) > 120 else { return }
        let radio = radioTech
        let level: CoverageLevel = cellularOK ? .data : (radio != nil ? .voice : .none)
        lastSampleCell = key
        lastSampleTime = Date()
        lastMeasured = (level, radio, Date())
        add(CoverageSample(cell: key, lat: la, lon: lo, carrier: carrier, level: level, radio: radio, source: "auto", at: Date()))
    }

    /// بلاغ يدوي من المستخدم عن مكانه الحالي.
    func report(_ level: CoverageLevel, at c: CLLocationCoordinate2D, carrier: Carrier) {
        let (key, la, lo) = Self.cellKey(c)
        add(CoverageSample(cell: key, lat: la, lon: lo, carrier: carrier, level: level,
                           radio: level == .data ? radioTech : nil, source: "manual", at: Date()))
        Task { await uploadPending() }
    }

    private func add(_ s: CoverageSample) {
        // نحتفظ بأحدث قياس لكل مربع وشركة
        samples.removeAll { $0.cell == s.cell && $0.carrier == s.carrier }
        samples.append(s)
        fetched.removeAll { $0.cell == s.cell && $0.carrier == s.carrier && $0.source == "mine" }
        var mine = s; mine.source = s.source == "manual" ? "manual" : "mine"
        fetched.append(mine)
        pendingCount = samples.count
        Self.save(samples, to: Self.pendingURL)
        rebuild()
    }

    // MARK: - الرفع والجلب

    func uploadPending() async {
        guard !uploading, !samples.isEmpty, CommunityService.shared.isEnabled else { return }
        uploading = true
        defer { uploading = false }
        guard let token = try? await CommunityService.shared.token(), let uid = CommunityService.shared.myUid else { return }
        let base = CommunityService.shared.base
        for s in samples.prefix(100) {
            let id = "\(s.cell)_\(s.carrier.rawValue)_\(uid)"
            var fields: [String: Any] = [
                "cell": ["stringValue": s.cell],
                "lat": ["doubleValue": s.lat],
                "lon": ["doubleValue": s.lon],
                "carrier": ["stringValue": s.carrier.rawValue],
                "level": ["stringValue": s.level.rawValue],
                "source": ["stringValue": s.source == "manual" ? "manual" : "auto"],
                "author": ["stringValue": uid],
                "at": ["timestampValue": ISO8601DateFormatter().string(from: s.at)]
            ]
            fields["radio"] = ["stringValue": s.radio ?? ""]
            var req = URLRequest(url: URL(string: "\(base)/coverage/\(id)")!)
            req.httpMethod = "PATCH"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["fields": fields])
            guard let (_, resp) = try? await CommunityService.shared.session.data(for: req) else { return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // نزيل القياس عند النجاح أو عند رفضه نهائيًا (حتى لا يتكرر)
            if (200..<300).contains(code) || code == 400 || code == 403 {
                samples.removeAll { $0 == s }
            }
        }
        pendingCount = samples.count
        Self.save(samples, to: Self.pendingURL)
    }

    /// جلب قياسات الآخرين ضمن المنطقة الظاهرة.
    func refresh(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async {
        #if DEBUG
        if GuideScreens.requested != nil { return }  // لقطات الشاشة تستخدم بيانات عرض ثابتة
        #endif
        guard CommunityService.shared.isEnabled else { return }
        let box = (sw.latitude, sw.longitude, ne.latitude, ne.longitude)
        if let last = lastFetchBox, Date().timeIntervalSince(lastFetch) < 90,
           box.0 >= last.0, box.1 >= last.1, box.2 <= last.2, box.3 <= last.3 { return }
        let pad = max(0.05, (ne.latitude - sw.latitude) * 0.3)
        let q = (sw.latitude - pad, sw.longitude - pad, ne.latitude + pad, ne.longitude + pad)
        let query: [String: Any] = ["structuredQuery": [
            "from": [["collectionId": "coverage"]],
            "where": ["compositeFilter": ["op": "AND", "filters": [
                ["fieldFilter": ["field": ["fieldPath": "lat"], "op": "GREATER_THAN_OR_EQUAL", "value": ["doubleValue": q.0]]],
                ["fieldFilter": ["field": ["fieldPath": "lat"], "op": "LESS_THAN_OR_EQUAL", "value": ["doubleValue": q.2]]]
            ]]],
            "limit": 2000
        ]]
        do {
            var req = URLRequest(url: URL(string: "\(CommunityService.shared.base):runQuery?key=\(CommunityConfig.apiKey)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: query)
            let (data, resp) = try await CommunityService.shared.session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let rows = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let got = rows.compactMap { ($0["document"] as? [String: Any]).flatMap(Self.parse) }
                .filter { (q.1...q.3).contains($0.lon) }
            // نستبدل ما في المنطقة بالجديد مع إبقاء قياساتي المحلية
            fetched = fetched.filter { $0.source == "mine" || $0.source == "manual"
                || !((q.0...q.2).contains($0.lat) && (q.1...q.3).contains($0.lon)) } + got
            if fetched.count > 20_000 { fetched = Array(fetched.suffix(20_000)) }
            lastFetchBox = q
            lastFetch = Date()
            Self.save(fetched, to: Self.cacheURL)
            rebuild()
        } catch {
            // دون اتصال: نستخدم المخزن المحلي
        }
    }

    #if DEBUG
    /// بيانات عرض للقطات الشاشة فقط (لا تُرفع).
    func injectDemo(around c: CLLocationCoordinate2D) {
        let levels: [CoverageLevel] = [.data, .data, .voice, .none, .data, .voice, .none, .none, .data]
        for dx in -4...4 {
            for dy in -3...3 {
                let p = CLLocationCoordinate2D(latitude: c.latitude + Double(dy) * Self.cellSize,
                                               longitude: c.longitude + Double(dx) * Self.cellSize)
                let (key, la, lo) = Self.cellKey(p)
                let l = levels[abs(dx * 3 + dy) % levels.count]
                fetched.append(CoverageSample(cell: key, lat: la, lon: lo, carrier: .stc, level: l, radio: l == .data ? "4G" : nil,
                                              source: "auto", at: Date()))
            }
        }
        rebuild()
    }
    #endif

    // MARK: - الدمج والعرض

    /// المربعات الظاهرة، لشركتي فقط أو لكل الشركات (أفضل حالة مسجلة في المربع).
    func visibleCells(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, carrier: Carrier?) -> [CoverageCell] {
        cells.values.filter {
            (carrier == nil || $0.carrier == carrier) && $0.lat + Self.cellSize >= sw.latitude && $0.lat <= ne.latitude
                && $0.lon + Self.cellSize >= sw.longitude && $0.lon <= ne.longitude
        }
        .sorted { $0.latest > $1.latest }
        .prefix(1500).map { $0 }
    }

    func cells(at c: CLLocationCoordinate2D) -> [CoverageCell] {
        let (key, _, _) = Self.cellKey(c)
        return cells.values.filter { $0.id.hasPrefix(key + "|") }
    }

    private func rebuild() {
        var out: [String: CoverageCell] = [:]
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        for s in fetched where s.at > cutoff {
            let id = "\(s.cell)|\(s.carrier.rawValue)"
            if var c = out[id] {
                c.count += 1
                // الأحدث يحدد الحالة، والبلاغ اليدوي الأحدث له الأولوية
                if s.at > c.latest { c.latest = s.at; c.level = s.level; c.radio = s.radio ?? c.radio }
                if s.source == "manual" { c.hasManualReport = true }
                out[id] = c
            } else {
                out[id] = CoverageCell(id: id, lat: s.lat, lon: s.lon, level: s.level, carrier: s.carrier, count: 1,
                                       latest: s.at, radio: s.radio, hasManualReport: s.source == "manual")
            }
        }
        cells = out
    }

    nonisolated static func parse(_ doc: [String: Any]) -> CoverageSample? {
        guard let f = doc["fields"] as? [String: Any] else { return nil }
        func str(_ k: String) -> String? { (f[k] as? [String: Any])?["stringValue"] as? String }
        func num(_ k: String) -> Double? { ((f[k] as? [String: Any])?["doubleValue"] as? Double) }
        guard let cell = str("cell"), let lat = num("lat"), let lon = num("lon"),
              let carrier = Carrier(rawValue: str("carrier") ?? ""), let level = CoverageLevel(rawValue: str("level") ?? "") else { return nil }
        let at = ((f["at"] as? [String: Any])?["timestampValue"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0) ?? GPXService.isoFractional.date(from: $0)
        } ?? Date()
        let radio = str("radio").flatMap { $0.isEmpty ? nil : $0 }
        return CoverageSample(cell: cell, lat: lat, lon: lon, carrier: carrier, level: level, radio: radio,
                              source: str("source") ?? "auto", at: at)
    }

    private nonisolated static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private nonisolated static var pendingURL: URL { dir.appendingPathComponent("coverage-pending.json") }
    private nonisolated static var cacheURL: URL { dir.appendingPathComponent("coverage-cache.json") }

    private static func load(_ url: URL) -> [CoverageSample] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CoverageSample].self, from: d)) ?? []
    }

    private static func save(_ list: [CoverageSample], to url: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: url, options: .atomic) }
    }
}
