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

    enum State: Equatable { case downloading, paused, interrupted, complete, invalid, unknown }

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
    case invalidStyleURL, tooLarge(Int), invalidMBTiles(String), vectorNeedsStyle, incompatibleStyle, styleUnreachable
    var errorDescription: String? {
        switch self {
        case .incompatibleStyle: return "مصدر الخرائط هذا غير متوافق مع التنزيل دون إنترنت. استخدم المصدر الافتراضي من إعدادات مصدر الخرائط."
        case .styleUnreachable: return "تعذّر الوصول إلى مصدر الخرائط. تأكد من الاتصال بالإنترنت ثم حاول مرة أخرى."
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

    /// النمط الافتراضي: OpenFreeMap (بيانات OpenStreetMap، مجاني بلا مفتاح).
    /// شروطه للتنزيل دون اتصال: حتى 3000 مربع أو 50 ميجابايت لكل تنزيل، و4 طلبات متوازية كحد أقصى، مع User-Agent يعرّف التطبيق.
    nonisolated static let defaultStyleURL = "https://tiles.openfreemap.org/styles/liberty"
    static let defaultStyleTileLimit = 3_000
    static let customStyleTileLimit = 120_000
    nonisolated static let userAgent = "Samt/1.0 (iOS; com.almuqbel.ShettaMaps2; offline-navigation)"
    /// نمط MapLibre التجريبي يسبب انهيار التنزيل دون اتصال في MapLibre Native (خطأ في معالجة رابط الخطوط)، لذا يُمنع.
    nonisolated static let blockedStyleHosts = ["demotiles.maplibre.org"]

    /// الحد الأقصى للمربعات حسب مصدر الخرائط الحالي.
    var maxTilesPerRegion: Int {
        styleURLString == Self.defaultStyleURL ? Self.defaultStyleTileLimit : Self.customStyleTileLimit
    }

    @Published private(set) var regions: [OfflineRegionItem] = []
    @Published private(set) var tilesets: [LocalTileset] = []
    @Published var selectedTilesetID: UUID? {
        didSet { UserDefaults.standard.set(selectedTilesetID?.uuidString, forKey: "selectedTileset") }
    }
    @Published private(set) var lastError: String?

    private var observers: [NSObjectProtocol] = []
    private var packsObservation: NSKeyValueObservation?
    private var didRestorePacks = false
    private var progressRequested: Set<ObjectIdentifier> = []
    private let tilesetsKey = "localTilesets"
    private let pausedKey = "pausedOfflinePacks"

    /// المناطق التي أوقفها المستخدم بنفسه؛ لا تُستأنف تلقائيًا عند فتح التطبيق.
    private var pausedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pausedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: pausedKey) }
    }

    var styleURLString: String {
        let s = UserDefaults.standard.string(forKey: SettingsKeys.offlineStyleURL) ?? ""
        if s.isEmpty { return Self.defaultStyleURL }
        if let host = URL(string: s)?.host, Self.blockedStyleHosts.contains(host) { return Self.defaultStyleURL }
        return s
    }

    var isUsingDefaultStyle: Bool { styleURLString == Self.defaultStyleURL && selectedTilesetID == nil }

    private init() {
        Self.configureNetwork()
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
        // MapLibre يحمّل الحزم المحفوظة بشكل غير متزامن بعد فتح التطبيق، ويعيد تحميلها أحيانًا (فتصبح الكائنات
        // القديمة غير صالحة). المعالجة تتم دائمًا لاحقًا على الخيط الرئيسي، لا داخل إشعار التغيير نفسه.
        packsObservation = MLNOfflineStorage.shared.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.restorePacksIfNeeded() } }
        }
    }

    // MARK: - الوصول الآمن للحزم
    //
    // قاعدة أساسية: أي حزمة حُذفت أو أُعيد تحميلها تصبح غير صالحة (invalid)، وأي استدعاء لـ region أو context
    // أو resume عليها يرمي استثناء يُنهي التطبيق. لذلك لا نحتفظ بكائنات الحزم، ونقرأ بياناتها مرة واحدة
    // في لقطة (PackInfo) بعد التحقق من صلاحيتها، ونعيد البحث عنها بالمعرّف قبل أي عملية.

    private struct PackInfo {
        let pack: MLNOfflinePack
        let id: String
        let name: String
        let region: MLNTilePyramidOfflineRegion
        var styleHost: String? { region.styleURL.host }
        var isBlocked: Bool { styleHost.map { OfflineMapManager.blockedStyleHosts.contains($0) } ?? false }
        var usesDefaultStyle: Bool { region.styleURL.absoluteString == OfflineMapManager.defaultStyleURL }
    }

    private static func isValid(_ pack: MLNOfflinePack) -> Bool { pack.state != .invalid }

    private func info(_ pack: MLNOfflinePack) -> PackInfo? {
        guard Self.isValid(pack), let region = pack.region as? MLNTilePyramidOfflineRegion else { return nil }
        let meta = try? JSONDecoder().decode(PackContext.self, from: pack.context)
        let fallbackID = String(format: "pack-%.5f-%.5f-%.5f-%.5f-%.0f-%.0f", region.bounds.sw.latitude, region.bounds.sw.longitude,
                                region.bounds.ne.latitude, region.bounds.ne.longitude, region.minimumZoomLevel, region.maximumZoomLevel)
        return PackInfo(pack: pack, id: meta?.id ?? fallbackID, name: meta?.name ?? "منطقة", region: region)
    }

    /// لقطة لكل الحزم الصالحة حاليًا.
    private func snapshot() -> [PackInfo] {
        (MLNOfflineStorage.shared.packs ?? []).compactMap { info($0) }
    }

    /// يعيد الحزمة الصالحة الحالية بهذا المعرّف (لا يُستخدم كائن قديم أبدًا).
    private func livePack(id: String) -> MLNOfflinePack? {
        snapshot().first { $0.id == id }?.pack
    }

    // MARK: - الاستعادة بعد فتح التطبيق

    /// حماية من حلقة الانهيار: إن انتهى التطبيق أثناء الاستئناف التلقائي في المرة السابقة، لا نستأنف تلقائيًا هذه المرة.
    private let resumeGuardKey = "offlineAutoResumeInProgress"

    /// يعيد تنفيذ خطوات ما بعد فتح التطبيق (للاختبارات).
    func runLaunchRestoreForTesting() {
        didRestorePacks = false
        restorePacksIfNeeded()
    }

    private func restorePacksIfNeeded() {
        guard MLNOfflineStorage.shared.packs != nil else { return }
        if !didRestorePacks {
            didRestorePacks = true
            let infos = snapshot()
            let blocked = infos.filter(\.isBlocked)
            let previousLaunchCrashed = UserDefaults.standard.bool(forKey: resumeGuardKey)

            if previousLaunchCrashed {
                lastError = "توقف التنزيل التلقائي للمناطق لأن التطبيق أُغلق بشكل غير متوقع أثناءه. يمكنك استئناف كل منطقة يدويًا أو حذفها."
            } else {
                let paused = pausedIDs
                // الاستئناف التلقائي فقط لمناطق المصدر الافتراضي المعروف أنه آمن
                let toResume = infos.filter { !$0.isBlocked && $0.usesDefaultStyle && $0.pack.state != .complete && !paused.contains($0.id) }
                if !toResume.isEmpty {
                    UserDefaults.standard.set(true, forKey: resumeGuardKey)
                    for i in toResume where Self.isValid(i.pack) { i.pack.resume() }
                    let key = resumeGuardKey
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { UserDefaults.standard.set(false, forKey: key) }
                }
            }
            if previousLaunchCrashed {
                UserDefaults.standard.set(false, forKey: resumeGuardKey)
            }
            // الحذف آخرًا: بعده تصبح هذه الكائنات غير صالحة فلا نلمسها
            for b in blocked { removePackSafely(b.pack) }
            if !blocked.isEmpty {
                lastError = "حُذفت \(blocked.count) منطقة نُزّلت بمصدر خرائط قديم غير متوافق. أعد تنزيلها من شاشة الخرائط المحفوظة."
            }
        }
        refreshRegions()
    }

    /// يحذف الحزم القديمة المنزّلة بنمط محظور دون تشغيلها؛ استئنافها يسبب انهيار MapLibre. يعيد عددها.
    @discardableResult
    func removeIncompatiblePacks() -> Int {
        let blocked = snapshot().filter(\.isBlocked)
        for b in blocked { removePackSafely(b.pack) }
        return blocked.count
    }

    private func removePackSafely(_ pack: MLNOfflinePack) {
        guard Self.isValid(pack) else { return }
        if pack.state == .active { pack.suspend() }
        MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error { self?.lastError = "تعذّر حذف المنطقة: \(error.localizedDescription)" }
                    self?.refreshRegions()
                }
            }
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
        let infos = snapshot().filter { !$0.isBlocked }
        for i in infos where i.pack.state == .unknown && !progressRequested.contains(ObjectIdentifier(i.pack)) {
            // بعد إعادة فتح التطبيق تكون حالة الحزمة وتقدمها غير معروفين حتى نطلبهما
            progressRequested.insert(ObjectIdentifier(i.pack))
            i.pack.requestProgress()
        }
        let paused = pausedIDs
        regions = infos.map { i in
            let p = i.pack.progress
            let state: OfflineRegionItem.State
            switch i.pack.state {
            case .active: state = .downloading
            case .inactive: state = paused.contains(i.id) ? .paused : .interrupted
            case .complete: state = .complete
            case .invalid: state = .invalid
            default: state = .unknown
            }
            return OfflineRegionItem(id: i.id, name: i.name,
                                     sw: i.region.bounds.sw, ne: i.region.bounds.ne,
                                     minZoom: i.region.minimumZoomLevel, maxZoom: i.region.maximumZoomLevel,
                                     styleURL: i.region.styleURL.absoluteString,
                                     completed: p.countOfResourcesCompleted, expected: p.countOfResourcesExpected,
                                     bytes: p.countOfBytesCompleted, state: state)
        }
    }

    private struct PackContext: Codable { var id: String; var name: String }

    /// قاعدة MapLibre الافتراضية: أي رابط خطوط يبدأ بها يُعالَج بتعبير نمطي معطوب فينهار التنزيل.
    nonisolated static let crashingGlyphsPrefix = "https://demotiles.maplibre.org"

    /// يتحقق من ملف النمط قبل التنزيل: يجب أن يكون JSON صالحًا ولا يستخدم خطوط demotiles.
    nonisolated static func validateStyleForOffline(_ data: Data) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["sources"] != nil else { throw OfflineMapError.invalidStyleURL }
        if let glyphs = obj["glyphs"] as? String, glyphs.hasPrefix(crashingGlyphsPrefix) {
            throw OfflineMapError.incompatibleStyle
        }
        if let sprite = obj["sprite"] as? String, sprite.hasPrefix(crashingGlyphsPrefix) {
            throw OfflineMapError.incompatibleStyle
        }
    }

    func download(name: String, sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                  minZoom: Int, maxZoom: Int) async throws {
        guard let style = URL(string: styleURLString), style.scheme?.hasPrefix("http") == true else {
            throw OfflineMapError.invalidStyleURL
        }
        let estimate = GeoMath.estimatedTileCount(sw: sw, ne: ne, minZoom: minZoom, maxZoom: maxZoom)
        guard estimate <= maxTilesPerRegion else { throw OfflineMapError.tooLarge(estimate) }
        if let host = style.host, Self.blockedStyleHosts.contains(host) { throw OfflineMapError.incompatibleStyle }

        // فحص النمط قبل إعطائه لـ MapLibre
        var request = URLRequest(url: style, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let styleData: Data
        do { styleData = try await URLSession.shared.data(for: request).0 } catch { throw OfflineMapError.styleUnreachable }
        try Self.validateStyleForOffline(styleData)

        // حدود صالحة دائمًا (خطوط العرض والطول ضمن المدى)
        let safeSW = CLLocationCoordinate2D(latitude: max(-85, min(85, sw.latitude)), longitude: max(-180, min(180, sw.longitude)))
        let safeNE = CLLocationCoordinate2D(latitude: max(-85, min(85, ne.latitude)), longitude: max(-180, min(180, ne.longitude)))
        let bounds = MLNCoordinateBounds(sw: safeSW, ne: safeNE)
        let region = MLNTilePyramidOfflineRegion(styleURL: style, bounds: bounds,
                                                 fromZoomLevel: Double(minZoom), toZoomLevel: Double(maxZoom))
        let ctx = PackContext(id: UUID().uuidString, name: name.isEmpty ? "منطقة" : name)
        let data = (try? JSONEncoder().encode(ctx)) ?? Data()
        MLNOfflineStorage.shared.addPack(for: region, withContext: data) { [weak self] pack, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let error {
                        self?.lastError = "تعذّر بدء التنزيل: \(error.localizedDescription)"
                        return
                    }
                    if let pack, Self.isValid(pack) { pack.resume() }
                    self?.refreshRegions()
                }
            }
        }
    }

    func toggle(_ item: OfflineRegionItem) {
        guard let i = snapshot().first(where: { $0.id == item.id }), !i.isBlocked else { refreshRegions(); return }
        if i.pack.state == .active {
            i.pack.suspend()
            pausedIDs.insert(item.id)
        } else if i.pack.state != .complete {
            pausedIDs.remove(item.id)
            i.pack.resume()
        }
        refreshRegions()
    }

    func delete(_ item: OfflineRegionItem) {
        pausedIDs.remove(item.id)
        regions.removeAll { $0.id == item.id }   // إخفاء فوري
        if let pack = livePack(id: item.id) { removePackSafely(pack) } else { refreshRegions() }
    }

    /// حذف كل المناطق المنزلة.
    func deleteAll() {
        let ids = snapshot().map(\.id)
        regions = []
        pausedIDs = []
        // نعيد البحث عن كل حزمة قبل حذفها، لأن حذف واحدة قد يعيد تحميل القائمة
        for id in ids { if let pack = livePack(id: id) { removePackSafely(pack) } }
    }

    /// يعرّف التطبيق لخوادم الخرائط ويحدّ الاتصالات المتوازية بأربعة (شروط OpenFreeMap).
    private static func configureNetwork() {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
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

    func fileSize(of t: LocalTileset) -> Int64 {
        let url = tilesDirectory.appendingPathComponent(t.fileName)
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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
