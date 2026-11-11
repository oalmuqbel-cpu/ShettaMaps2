import Foundation
import CoreLocation
import MapLibre
import SQLite3

/// منطقة خرائط منزّلة عبر حزم MapLibre دون اتصال.
struct OfflineRegionItem: Identifiable, Equatable {
    var id: String
    var name: String
    var sw: CLLocationCoordinate2D
    var ne: CLLocationCoordinate2D
    var minZoom: Double
    var maxZoom: Double
    var styleURL: String
    var completed: UInt64
    var expected: UInt64
    var bytes: UInt64
    var state: State

    enum State: Equatable { case downloading, paused, complete, invalid, unknown }

    var fraction: Double { expected > 0 ? min(1, Double(completed) / Double(expected)) : 0 }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.completed == b.completed && a.state == b.state && a.bytes == b.bytes && a.name == b.name
    }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        (sw.latitude...ne.latitude).contains(c.latitude) && (sw.longitude...ne.longitude).contains(c.longitude)
    }
}

/// ملف مربعات محلي (MBTiles) مستورد من المستخدم.
struct LocalTileset: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var fileName: String
    var format: String          // png / jpg / webp / pbf
    var minZoom: Int
    var maxZoom: Int
    var swLat: Double, swLon: Double, neLat: Double, neLon: Double
    var attribution: String

    var isRaster: Bool { format != "pbf" }

    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        (swLat...neLat).contains(c.latitude) && (swLon...neLon).contains(c.longitude)
    }
}

enum OfflineMapError: LocalizedError {
    case invalidStyleURL, tooLarge(Int), invalidMBTiles(String), vectorNeedsStyle
    var errorDescription: String? {
        switch self {
        case .invalidStyleURL: return "رابط نمط الخريطة غير صالح. راجعه في الإعدادات."
        case .tooLarge(let n): return "المنطقة كبيرة جدًا (\(n) مربع تقريبًا). صغّر المنطقة أو خفّض أعلى مستوى تكبير."
        case .invalidMBTiles(let m): return "تعذّر قراءة ملف MBTiles: \(m)"
        case .vectorNeedsStyle: return "ملف MBTiles متجهي يحتاج إلى ملف نمط (style.json) مخصص. استخدم ملفًا نقطيًا (PNG/JPG) أو أضف النمط وفق الدليل."
        }
    }
}

/// إدارة الخرائط دون إنترنت باستخدام MapLibre Native (رخصة BSD).
///
/// ملاحظة مهمة: MapLibre محرك عرض فقط. بيانات الخرائط يجب أن تأتي من مصدر يسمح ترخيصه بالتخزين
/// دون اتصال (خادم مربعات خاص بك، أو مزوّد تجاري يمنح هذا الحق، أو ملفات MBTiles من بيانات مفتوحة مثل OpenStreetMap بموجب ODbL).
@MainActor
final class OfflineMapManager: ObservableObject {
    static let shared = OfflineMapManager()

    /// نمط تجريبي مجاني من MapLibre — تفاصيله محدودة جدًا (حدود الدول)، للاختبار فقط.
    static let demoStyleURL = "https://demotiles.maplibre.org/style.json"
    static let maxTilesPerRegion = 120_000

    @Published private(set) var regions: [OfflineRegionItem] = []
    @Published private(set) var tilesets: [LocalTileset] = []
    @Published var selectedTilesetID: UUID? {
        didSet { UserDefaults.standard.set(selectedTilesetID?.uuidString, forKey: "selectedTileset") }
    }
    @Published private(set) var lastError: String?

    private var observers: [NSObjectProtocol] = []
    private let tilesetsKey = "localTilesets"

    var styleURLString: String {
        let s = UserDefaults.standard.string(forKey: SettingsKeys.offlineStyleURL) ?? ""
        return s.isEmpty ? Self.demoStyleURL : s
    }

    var isUsingDemoStyle: Bool { styleURLString == Self.demoStyleURL && selectedTilesetID == nil }

    private init() {
        loadTilesets()
        if let s = UserDefaults.standard.string(forKey: "selectedTileset"), let id = UUID(uuidString: s),
           tilesets.contains(where: { $0.id == id }) {
            selectedTilesetID = id
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRegions() }
        })
        observers.append(center.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] note in
            let message = (note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError)?.localizedDescription
            MainActor.assumeIsolated {
                self?.lastError = "خطأ في تنزيل الخريطة: \(message ?? "غير معروف")"
                self?.refreshRegions()
            }
        })
        // تحميل الحزم المحفوظة يتم بشكل غير متزامن داخل MapLibre
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.refreshRegions() }
        }
    }

    // MARK: - النمط النشط

    /// رابط النمط المستخدم لعرض الخريطة دون إنترنت (ملف محلي أو رابط حزم).
    var activeStyleURL: URL? {
        if let id = selectedTilesetID, let t = tilesets.first(where: { $0.id == id }) {
            return styleFileURL(for: t)
        }
        return URL(string: styleURLString)
    }

    // MARK: - حزم التنزيل

    func refreshRegions() {
        let packs = MLNOfflineStorage.shared.packs ?? []
        regions = packs.compactMap { item(from: $0) }
    }

    private func item(from pack: MLNOfflinePack) -> OfflineRegionItem? {
        guard let region = pack.region as? MLNTilePyramidOfflineRegion else { return nil }
        let meta = (try? JSONDecoder().decode(PackContext.self, from: pack.context))
            ?? PackContext(id: UUID().uuidString, name: "منطقة")
        let p = pack.progress
        let state: OfflineRegionItem.State
        switch pack.state {
        case .active: state = .downloading
        case .inactive: state = .paused
        case .complete: state = .complete
        case .invalid: state = .invalid
        default: state = .unknown
        }
        return OfflineRegionItem(id: meta.id, name: meta.name,
                                 sw: region.bounds.sw, ne: region.bounds.ne,
                                 minZoom: region.minimumZoomLevel, maxZoom: region.maximumZoomLevel,
                                 styleURL: region.styleURL.absoluteString,
                                 completed: p.countOfResourcesCompleted, expected: p.countOfResourcesExpected,
                                 bytes: p.countOfBytesCompleted, state: state)
    }

    private struct PackContext: Codable { var id: String; var name: String }

    func download(name: String, sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                  minZoom: Int, maxZoom: Int) throws {
        guard let style = URL(string: styleURLString), style.scheme?.hasPrefix("http") == true else {
            throw OfflineMapError.invalidStyleURL
        }
        let estimate = GeoMath.estimatedTileCount(sw: sw, ne: ne, minZoom: minZoom, maxZoom: maxZoom)
        guard estimate <= Self.maxTilesPerRegion else { throw OfflineMapError.tooLarge(estimate) }

        let bounds = MLNCoordinateBounds(sw: sw, ne: ne)
        let region = MLNTilePyramidOfflineRegion(styleURL: style, bounds: bounds,
                                                 fromZoomLevel: Double(minZoom), toZoomLevel: Double(maxZoom))
        let ctx = PackContext(id: UUID().uuidString, name: name.isEmpty ? "منطقة" : name)
        let data = (try? JSONEncoder().encode(ctx)) ?? Data()
        MLNOfflineStorage.shared.addPack(for: region, withContext: data) { [weak self] pack, error in
            MainActor.assumeIsolated {
                if let error {
                    self?.lastError = "تعذّر بدء التنزيل: \(error.localizedDescription)"
                    return
                }
                pack?.resume()
                self?.refreshRegions()
            }
        }
    }

    func toggle(_ item: OfflineRegionItem) {
        guard let pack = pack(for: item) else { return }
        if pack.state == .active { pack.suspend() } else { pack.resume() }
        refreshRegions()
    }

    func delete(_ item: OfflineRegionItem) {
        guard let pack = pack(for: item) else { return }
        MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
            MainActor.assumeIsolated {
                if let error { self?.lastError = error.localizedDescription }
                self?.refreshRegions()
            }
        }
    }

    private func pack(for item: OfflineRegionItem) -> MLNOfflinePack? {
        (MLNOfflineStorage.shared.packs ?? []).first {
            (try? JSONDecoder().decode(PackContext.self, from: $0.context))?.id == item.id
        }
    }

    // MARK: - ملفات MBTiles المحلية

    private var tilesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OfflineMaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true // ملفات كبيرة: لا تُنسخ احتياطيًا إلى iCloud
        var mutable = dir
        try? mutable.setResourceValues(values)
        return dir
    }

    func importMBTiles(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let fileName = "\(UUID().uuidString).mbtiles"
        let dest = tilesDirectory.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: source, to: dest)

        do {
            let meta = try readMetadata(dest)
            let format = (meta["format"] ?? "png").lowercased()
            if format == "pbf" { throw OfflineMapError.vectorNeedsStyle }
            let b = (meta["bounds"] ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let bounds = b.count == 4 ? b : [-180, -85, 180, 85]
            let t = LocalTileset(name: meta["name"] ?? source.deletingPathExtension().lastPathComponent,
                                 fileName: fileName, format: format,
                                 minZoom: Int(meta["minzoom"] ?? "") ?? 0,
                                 maxZoom: Int(meta["maxzoom"] ?? "") ?? 14,
                                 swLat: bounds[1], swLon: bounds[0], neLat: bounds[3], neLon: bounds[2],
                                 attribution: meta["attribution"] ?? "")
            try writeRasterStyle(for: t)
            tilesets.append(t)
            saveTilesets()
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    func deleteTileset(_ t: LocalTileset) {
        try? FileManager.default.removeItem(at: tilesDirectory.appendingPathComponent(t.fileName))
        if let style = styleFileURL(for: t) { try? FileManager.default.removeItem(at: style) }
        tilesets.removeAll { $0.id == t.id }
        if selectedTilesetID == t.id { selectedTilesetID = nil }
        saveTilesets()
    }

    private func styleFileURL(for t: LocalTileset) -> URL? {
        tilesDirectory.appendingPathComponent("\(t.id.uuidString)-style.json")
    }

    /// ينشئ نمطًا نقطيًا يشير إلى ملف MBTiles محليًا عبر مخطط mbtiles:// المدعوم في MapLibre Native.
    private func writeRasterStyle(for t: LocalTileset) throws {
        let path = tilesDirectory.appendingPathComponent(t.fileName).path
        let style: [String: Any] = [
            "version": 8,
            "name": t.name,
            "sources": [
                "local": [
                    "type": "raster",
                    "url": "mbtiles://\(path)",
                    "tileSize": 256,
                    "attribution": t.attribution
                ]
            ],
            "layers": [
                ["id": "background", "type": "background", "paint": ["background-color": "#EFE3CF"]],
                ["id": "local-raster", "type": "raster", "source": "local"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: style, options: [.prettyPrinted])
        guard let url = styleFileURL(for: t) else { return }
        try data.write(to: url, options: .atomic)
    }

    private func readMetadata(_ url: URL) throws -> [String: String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw OfflineMapError.invalidMBTiles("لا يمكن فتح قاعدة البيانات")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name, value FROM metadata", -1, &stmt, nil) == SQLITE_OK else {
            throw OfflineMapError.invalidMBTiles("جدول metadata غير موجود")
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                result[String(cString: k)] = String(cString: v)
            }
        }
        return result
    }

    private func loadTilesets() {
        guard let data = UserDefaults.standard.data(forKey: tilesetsKey),
              let list = try? JSONDecoder().decode([LocalTileset].self, from: data) else { return }
        tilesets = list.filter { FileManager.default.fileExists(atPath: tilesDirectory.appendingPathComponent($0.fileName).path) }
    }

    private func saveTilesets() {
        if let data = try? JSONEncoder().encode(tilesets) {
            UserDefaults.standard.set(data, forKey: tilesetsKey)
        }
    }

    // MARK: - التغطية

    /// هل تتوفر خريطة دون إنترنت تغطي هذه النقطة؟
    func hasOfflineCoverage(at c: CLLocationCoordinate2D) -> Bool {
        regions.contains { $0.state == .complete && $0.contains(c) } || tilesets.contains { $0.contains(c) }
    }

    func reportStyleError(_ error: Error) {
        lastError = "تعذّر تحميل نمط الخريطة دون إنترنت. تأكد من تنزيل المنطقة أو من صحة رابط النمط. (\(error.localizedDescription))"
    }

    func clearError() { lastError = nil }

    var totalDownloadedBytes: UInt64 { regions.reduce(0) { $0 + $1.bytes } }
}
