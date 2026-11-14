import Foundation
import CoreLocation
import CryptoKit
import SQLite3
import UIKit
import AudioToolbox

/// حدود السرعة المسجلة في OpenStreetMap: تنزيل خلايا 1°×1° تلقائيًا، وتحديد الطريق الذي تسير عليه،
/// وتنبيه عند تجاوز الحد. لا يُخمَّن حد لطريق لا يحمل حدًا مسجلًا.
@MainActor
final class SpeedLimitStore: ObservableObject {
    static let shared = SpeedLimitStore()
    static let releaseBase = "https://github.com/oalmuqbel-cpu/ShettaMaps2/releases/download/speed-v1"
    /// هامش التجاوز قبل التنبيه (كم/س).
    static let tolerance = 5.0

    struct Cell: Codable, Hashable {
        var file: String; var lat: Int; var lon: Int; var roads: Int; var bytes: Int; var sha256: String
        var key: String { "\(lat)_\(lon)" }
    }
    struct Manifest: Codable { var version: Int; var built: String; var cellSize: Double; var attribution: String; var cells: [Cell] }

    /// الحد للطريق الحالي (كم/س) أو nil إن لم يُعرف.
    @Published private(set) var currentLimit: Int?
    @Published private(set) var roadName: String?
    @Published private(set) var isOver = false

    private var manifest: Manifest?
    private var installed: Set<String> = []
    private var handles: [String: OpaquePointer] = [:]
    private var failedAt: [String: Date] = [:]
    private var downloading: Set<String> = []
    private var lastCheck = Date.distantPast
    private var overSince: Date?
    private var alerted = false
    private var lostAt: Date?

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
        guard enabled, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 40 else { return }
        if Date().timeIntervalSince(lastCheck) >= 1 {
            lastCheck = Date()
            updateLimit(at: loc)
        }
        checkOverspeed(loc)
    }

    private func updateLimit(at loc: CLLocation) {
        let key = Self.key(loc.coordinate)
        if !installed.contains(key) {
            if NetworkMonitor.shared.isOnline { Task { await ensureCell(key) } }
            setLimit(nil, nil)
            return
        }
        let course = loc.course >= 0 && loc.speed > 2 ? loc.course : nil
        if let (limit, name) = match(loc.coordinate, course: course, key: key) {
            lostAt = nil
            setLimit(limit, name)
        } else {
            // نبقي الحد لثوانٍ قليلة عند تقاطع أو انقطاع قصير، ثم نخفيه
            if lostAt == nil { lostAt = Date() }
            if let l = lostAt, Date().timeIntervalSince(l) > 6 { setLimit(nil, nil) }
        }
    }

    private func setLimit(_ limit: Int?, _ name: String?) {
        if currentLimit != limit { currentLimit = limit }
        if roadName != name { roadName = name }
    }

    private func checkOverspeed(_ loc: CLLocation) {
        guard let limit = currentLimit, loc.speed >= 0 else {
            if isOver { isOver = false }
            overSince = nil; alerted = false
            return
        }
        let kmh = loc.speed * 3.6
        if kmh > Double(limit) + Self.tolerance {
            if overSince == nil { overSince = Date() }
            // تنبيه بعد ثانيتين متواصلتين فوق الحد، مرة واحدة لكل تجاوز
            if let s = overSince, Date().timeIntervalSince(s) >= 2 {
                if !isOver { isOver = true }
                if !alerted {
                    alerted = true
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    AudioServicesPlaySystemSound(1315)
                }
            }
        } else if kmh < Double(limit) {
            overSince = nil
            if isOver { isOver = false }
            alerted = false
        }
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
        var best: (dist: Double, limit: Int, name: String?)?
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fwd = Int(sqlite3_column_int(stmt, 0)), bwd = Int(sqlite3_column_int(stmt, 1))
            let oneway = sqlite3_column_int(stmt, 2) == 1
            let name = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            guard let pc = sqlite3_column_text(stmt, 4) else { continue }
            let pts = PolylineCodec.decode(String(cString: pc))
            guard pts.count > 1 else { continue }
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                let dist = Self.distanceToSegment(c, a, b)
                guard dist < 25 else { continue }
                var limit = fwd
                if let course {
                    let segBearing = GeoMath.bearing(from: a, to: b)
                    let diff = abs(((course - segBearing + 540).truncatingRemainder(dividingBy: 360)) - 180)
                    if diff > 135 {
                        // نسير عكس اتجاه رسم الطريق
                        if oneway { continue }
                        limit = bwd
                    } else if diff > 45 {
                        continue  // طريق متقاطع وليس الذي نسير عليه
                    }
                }
                guard limit > 0 else { continue }
                if best == nil || dist < best!.dist { best = (dist, limit, (name?.isEmpty ?? true) ? nil : name) }
            }
        }
        return best.map { ($0.limit, $0.name) }
    }

    nonisolated static func distanceToSegment(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let kx = cos(p.latitude * .pi / 180) * 111_320, ky = 110_540.0
        let ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky
        let bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky
        let dx = bx - ax, dy = by - ay
        let l2 = dx * dx + dy * dy
        let t = l2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / l2))
        return hypot(ax + t * dx, ay + t * dy)
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
