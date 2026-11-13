import Foundation
import CoreLocation
import CryptoKit
import SQLite3

/// طريق ترابي أو ردمية من بيانات سَمْت (OpenStreetMap + Microsoft Road Detections).
struct DirtRoad: Identifiable, Hashable {
    enum Kind: String { case track = "osm_track", unpaved = "osm_unpaved", detected = "ms_detected" }
    var id: String
    var kind: Kind
    var name: String
    var coordinates: [CLLocationCoordinate2D]

    static func == (a: DirtRoad, b: DirtRoad) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// النص المكتوب على الطريق.
    var label: String {
        if !name.isEmpty { return name }
        switch kind {
        case .track: return "ردمية"
        case .unpaved: return "طريق ترابي"
        case .detected: return "طريق مرصود (غير مؤكد)"
        }
    }

    var length: Double {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0, $1.1) }
    }
}

/// إدارة بيانات الردميات: تنزيل خلايا 2°×2° حسب المنطقة، التحقق منها، والاستعلام بالحدود الظاهرة.
@MainActor
final class DirtRoadsStore: ObservableObject {
    static let shared = DirtRoadsStore()
    static let releaseBase = "https://github.com/oalmuqbel-cpu/ShettaMaps2/releases/download/dirtroads-v1"

    struct Cell: Codable, Hashable {
        var file: String; var lat: Int; var lon: Int; var roads: Int; var bytes: Int; var sha256: String
        var osm: Int?; var detected: Int?
        var key: String { "\(lat)_\(lon)" }
    }
    struct Manifest: Codable { var version: Int; var built: String; var cellSize: Double; var attribution: String; var cells: [Cell] }

    @Published private(set) var manifest: Manifest?
    @Published private(set) var installed: Set<String> = []
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var lastError: String?
    @Published private(set) var revision = 0

    private var handles: [String: OpaquePointer] = [:]
    private var failedAt: [String: Date] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        return URLSession(configuration: c)
    }()

    private var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DirtRoads", isDirectory: true)
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
        installed = Set(files.filter { $0.hasPrefix("dirt_") && $0.hasSuffix(".sqlite") }
            .map { $0.replacingOccurrences(of: "dirt_", with: "").replacingOccurrences(of: ".sqlite", with: "") })
    }

    var installedBytes: Int64 {
        installed.reduce(Int64(0)) { sum, key in
            sum + Int64((try? dir.appendingPathComponent("dirt_\(key).sqlite").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - الخلايا

    static func cellKeys(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, size: Double = 2) -> [String] {
        let la0 = Int((floor(sw.latitude / size) * size)), la1 = Int((floor(ne.latitude / size) * size))
        let lo0 = Int((floor(sw.longitude / size) * size)), lo1 = Int((floor(ne.longitude / size) * size))
        guard la1 >= la0, lo1 >= lo0, (la1 - la0) <= 12, (lo1 - lo0) <= 12 else { return [] }
        var keys: [String] = []
        for la in stride(from: la0, through: la1, by: Int(size)) {
            for lo in stride(from: lo0, through: lo1, by: Int(size)) { keys.append("\(la)_\(lo)") }
        }
        return keys
    }

    func loadManifest(force: Bool = false) async {
        if manifest != nil && !force { return }
        do {
            let (data, resp) = try await session.data(from: URL(string: "\(Self.releaseBase)/manifest.json")!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let m = try JSONDecoder().decode(Manifest.self, from: data)
            manifest = m
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
            lastError = nil
        } catch {
            lastError = "تعذّر جلب فهرس الردميات. تأكد من الاتصال بالإنترنت."
        }
    }

    /// الخلايا المتاحة (في الفهرس) التي تغطي منطقة.
    func cells(covering sw: CLLocationCoordinate2D, _ ne: CLLocationCoordinate2D) -> [Cell] {
        guard let m = manifest else { return [] }
        let keys = Set(Self.cellKeys(sw: sw, ne: ne, size: m.cellSize))
        return m.cells.filter { keys.contains($0.key) }
    }

    /// تنزيل خلايا منطقة. auto: تنزيل تلقائي أثناء التصفح (يتجاهل الفشل الحديث).
    func download(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, auto: Bool = false) async {
        await loadManifest()
        for cell in cells(covering: sw, ne) where !installed.contains(cell.key) && !downloading.contains(cell.key) {
            if auto, let f = failedAt[cell.key], Date().timeIntervalSince(f) < 600 { continue }
            await download(cell)
        }
    }

    private func download(_ cell: Cell) async {
        downloading.insert(cell.key)
        defer { downloading.remove(cell.key) }
        do {
            let (data, resp) = try await session.data(from: URL(string: "\(Self.releaseBase)/\(cell.file)")!)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == cell.sha256 else { throw URLError(.cannotDecodeContentData) }
            let raw = try (data as NSData).decompressed(using: .zlib) as Data
            let url = dir.appendingPathComponent("dirt_\(cell.key).sqlite")
            try raw.write(to: url, options: .atomic)
            closeHandle(cell.key)
            installed.insert(cell.key)
            revision += 1
            lastError = nil
        } catch {
            failedAt[cell.key] = Date()
            lastError = "تعذّر تنزيل الردميات لهذه المنطقة. حاول لاحقًا."
        }
    }

    func delete(key: String) {
        closeHandle(key)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("dirt_\(key).sqlite"))
        installed.remove(key)
        revision += 1
    }

    func deleteAll() { installed.forEach(delete) }

    // MARK: - الاستعلام

    private func handle(_ key: String) -> OpaquePointer? {
        if let h = handles[key] { return h }
        var db: OpaquePointer?
        let path = dir.appendingPathComponent("dirt_\(key).sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        handles[key] = db
        return db
    }

    private func closeHandle(_ key: String) {
        if let h = handles.removeValue(forKey: key) { sqlite3_close(h) }
    }

    /// الطرق داخل الحدود المعطاة. includeDetected: إظهار الطرق المرصودة من الأقمار الصناعية.
    func roads(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D, limit: Int, includeDetected: Bool) -> [DirtRoad] {
        var out: [DirtRoad] = []
        let sql = """
        SELECT r.id, r.kind, r.name, r.poly FROM roads_idx i JOIN roads r ON r.id = i.id
        WHERE i.maxLat >= ?1 AND i.minLat <= ?2 AND i.maxLon >= ?3 AND i.minLon <= ?4
        \(includeDetected ? "" : "AND r.kind != 'ms_detected'")
        ORDER BY (r.name != '') DESC, (i.maxLat - i.minLat) + (i.maxLon - i.minLon) DESC
        LIMIT ?5
        """
        // خلايا مجاورة أيضًا، لأن الطريق يُخزن في خلية منتصفه
        let keys = Self.cellKeys(sw: .init(latitude: sw.latitude - 1, longitude: sw.longitude - 1),
                                 ne: .init(latitude: ne.latitude + 1, longitude: ne.longitude + 1)).filter(installed.contains)
        for key in keys {
            guard out.count < limit, let db = handle(key) else { continue }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, sw.latitude); sqlite3_bind_double(stmt, 2, ne.latitude)
            sqlite3_bind_double(stmt, 3, sw.longitude); sqlite3_bind_double(stmt, 4, ne.longitude)
            sqlite3_bind_int(stmt, 5, Int32(limit - out.count))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let kind = DirtRoad.Kind(rawValue: String(cString: sqlite3_column_text(stmt, 1))) ?? .track
                let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                guard let polyC = sqlite3_column_text(stmt, 3) else { continue }
                let coords = PolylineCodec.decode(String(cString: polyC))
                guard coords.count > 1 else { continue }
                out.append(DirtRoad(id: "\(key)-\(id)", kind: kind, name: name, coordinates: coords))
            }
        }
        return out
    }
}
