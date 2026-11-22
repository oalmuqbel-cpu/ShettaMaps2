import Foundation
import CoreLocation
import CryptoKit
import SQLite3
import UIKit
import AudioToolbox
import Combine

/// حدود السرعة المسجلة في OpenStreetMap: تنزيل خلايا 1°×1° تلقائيًا، وتحديد الطريق الذي تسير عليه،
/// وتنبيه عند تجاوز الحد. لا يُخمَّن حد لطريق لا يحمل حدًا مسجلًا.
@MainActor
final class SpeedLimitStore: ObservableObject {
    static let shared = SpeedLimitStore()
    static let releaseBase = "https://github.com/oalmuqbel-cpu/ShettaMaps2/releases/download/speed-v1"

    struct Cell: Codable, Hashable {
        var file: String; var lat: Int; var lon: Int; var roads: Int; var bytes: Int; var sha256: String
        var key: String { "\(lat)_\(lon)" }
    }
    struct Manifest: Codable { var version: Int; var built: String; var cellSize: Double; var attribution: String; var cells: [Cell] }

    /// حالة الحد للطريق الحالي (معروف، غير مسجل، غير منزل، إشارة ضعيفة).
    @Published private(set) var state: SpeedLimitState = .off
    @Published private(set) var roadName: String?
    /// السرعة فوق (الحد + هامش التنبيه).
    @Published private(set) var isOver = false
    /// يصدر الحد عند كل تنبيه تجاوز (تستخدمه CarPlay لعرض تنبيه ملاحي).
    let alerts = PassthroughSubject<Int, Never>()

    /// الحد للطريق الحالي (كم/س) أو nil إن لم يُعرف بثقة.
    var currentLimit: Int? { state.limit }

    private var manifest: Manifest?
    private var installed: Set<String> = []
    private var handles: [String: OpaquePointer] = [:]
    private var failedAt: [String: Date] = [:]
    private var downloading: Set<String> = []
    private var lastCheck = Date.distantPast
    private var lastFix: CLLocation?
    private var lostAt: Date?
    private var monitor = OverspeedMonitor()
    private var staleTimer: Timer?

    private var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeedLimits", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var m = d; try? m.setResourceValues(v)
        return d
    }

    private init() {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) {
            manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        installed = Set(files.filter { $0.hasPrefix("speed_") && $0.hasSuffix(".sqlite") }
            .map { $0.replacingOccurrences(of: "speed_", with: "").replacingOccurrences(of: ".sqlite", with: "") })
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.showSpeed) as? Bool ?? true
    }

    nonisolated static func key(_ c: CLLocationCoordinate2D) -> String {
        "\(Int(floor(c.latitude)))_\(Int(floor(c.longitude)))"
    }

    // MARK: - المتابعة أثناء القيادة

    /// يُستدعى مع كل تحديث للموقع.
    func observe(_ loc: CLLocation) {
        guard enabled else { setState(.off, nil); evaluate(nil); return }
        startStaleTimer()
        guard loc.horizontalAccuracy >= 0 else { return }
        lastFix = loc
        if loc.horizontalAccuracy > 25 {
            // لا نحدد الطريق بإشارة ضعيفة؛ نبقي الحد السابق ثوانيَ قليلة ثم نعلن أنه غير مؤكد
            if lostAt == nil { lostAt = Date() }
            if let l = lostAt, Date().timeIntervalSince(l) > 6 { setState(.weakSignal, nil) }
        } else if Date().timeIntervalSince(lastCheck) >= 1 {
            lastCheck = Date()
            updateLimit(at: loc)
        }
        evaluate(LiveSpeed.kmh(loc, recent: LocationManager.shared.recentLocations))
    }

    private func updateLimit(at loc: CLLocation) {
        let key = Self.key(loc.coordinate)
        if !installed.contains(key) {
            if NetworkMonitor.shared.isOnline { Task { await ensureCell(key) } }
            setState(.notDownloaded, nil)
            return
        }
        let course = loc.course >= 0 && loc.speed > 2 ? loc.course : nil
        if let (limit, name) = match(loc.coordinate, course: course, key: key) {
            lostAt = nil
            setState(.known(limit), name)
        } else {
            // نبقي الحد لثوانٍ قليلة عند تقاطع أو انقطاع قصير، ثم نعلن أن الطريق بلا حد مسجل
            if lostAt == nil { lostAt = Date() }
            if let l = lostAt, Date().timeIntervalSince(l) > 6 { setState(.noData, nil) }
        }
    }

    private func setState(_ s: SpeedLimitState, _ name: String?) {
        if state != s { state = s }
        if roadName != name { roadName = name }
    }

    /// انقطاع GPS: لا تبقى سرعة قديمة ولا تجاوز معروض.
    private func startStaleTimer() {
        guard staleTimer == nil else { return }
        staleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let fix = self.lastFix else { return }
                let age = Date().timeIntervalSince(fix.timestamp)
                if age > LiveSpeed.maxAge { self.evaluate(nil) }
                if age > 10, self.state.limit != nil { self.setState(.weakSignal, nil) }
            }
        }
    }

    private func evaluate(_ kmh: Double?) {
        monitor.margin = Double(SpeedAlertSettings.margin)
        let alertsOn = enabled && SpeedAlertSettings.enabled
        let event = monitor.update(limit: alertsOn ? state.limit : nil, speedKmh: kmh, at: Date())
        if isOver != monitor.isOver { isOver = monitor.isOver }
        guard case .alert(let limit) = event else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if SpeedAlertSettings.sound { VoicePrompter.shared.speak("تجاوزت حد السرعة \(limit)", tone: true) }
        alerts.send(limit)
    }

    // MARK: - المطابقة مع الطريق

    /// أقرب طريق له حد ضمن ٢٥ م، ويوافق اتجاه السير (إن عُرف).
    private func match(_ c: CLLocationCoordinate2D, course: Double?, key: String) -> (Int, String?)? {
        guard let db = handle(key) else { return nil }
        let d = 0.0004
        let sql = """
        SELECT r.fwd, r.bwd, r.oneway, r.name, r.poly FROM roads_idx i JOIN roads r ON r.id = i.id
        WHERE i.maxLat >= ?1 AND i.minLat <= ?2 AND i.maxLon >= ?3 AND i.minLon <= ?4 LIMIT 40
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, c.latitude - d); sqlite3_bind_double(stmt, 2, c.latitude + d)
        sqlite3_bind_double(stmt, 3, c.longitude - d); sqlite3_bind_double(stmt, 4, c.longitude + d)
        var roads: [SpeedLimitMatcher.Road] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pc = sqlite3_column_text(stmt, 4) else { continue }
            roads.append(.init(forward: Int(sqlite3_column_int(stmt, 0)), backward: Int(sqlite3_column_int(stmt, 1)),
                               oneway: sqlite3_column_int(stmt, 2) == 1,
                               name: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                               points: PolylineCodec.decode(String(cString: pc))))
        }
        return SpeedLimitMatcher.best(at: c, course: course, roads: roads).map { ($0.limit, $0.name) }
    }

    // MARK: - البيانات

    private func ensureCell(_ key: String) async {
        guard !downloading.contains(key) else { return }
        if let f = failedAt[key], Date().timeIntervalSince(f) < 900 { return }
        downloading.insert(key)
        defer { downloading.remove(key) }
        do {
            if manifest == nil {
                let (data, resp) = try await URLSession.shared.data(from: URL(string: "\(Self.releaseBase)/manifest.json")!)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                manifest = try JSONDecoder().decode(Manifest.self, from: data)
                try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            }
            guard let cell = manifest?.cells.first(where: { $0.key == key }) else {
                failedAt[key] = Date()   // لا توجد طرق بحدود مسجلة في هذه الخلية
                return
            }
            let (data, resp) = try await URLSession.shared.data(from: URL(string: "\(Self.releaseBase)/\(cell.file)")!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == cell.sha256 else { throw URLError(.cannotDecodeContentData) }
            let raw = try (data as NSData).decompressed(using: .zlib) as Data
            try raw.write(to: dir.appendingPathComponent("speed_\(key).sqlite"), options: .atomic)
            if let h = handles.removeValue(forKey: key) { sqlite3_close(h) }
            installed.insert(key)
        } catch {
            failedAt[key] = Date()
        }
    }

    /// تنزيل حدود السرعة لمنطقة (مع تنزيل الخرائط دون إنترنت).
    func download(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async {
        guard ne.latitude >= sw.latitude, ne.longitude >= sw.longitude, ne.latitude - sw.latitude < 15 else { return }
        for la in Int(floor(sw.latitude))...Int(floor(ne.latitude)) {
            for lo in Int(floor(sw.longitude))...Int(floor(ne.longitude)) where !installed.contains("\(la)_\(lo)") {
                await ensureCell("\(la)_\(lo)")
            }
        }
    }

    var installedBytes: Int64 {
        installed.reduce(Int64(0)) { sum, k in
            sum + Int64((try? dir.appendingPathComponent("speed_\(k).sqlite").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func handle(_ key: String) -> OpaquePointer? {
        if let h = handles[key] { return h }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dir.appendingPathComponent("speed_\(key).sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        handles[key] = db
        return db
    }
}
