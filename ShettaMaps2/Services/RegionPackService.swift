import Foundation
import CoreLocation
import Combine

/// منطقة جاهزة للتنزيل (من ملف الوصف manifest.json في إصدار region-maps).
struct RegionPack: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var bbox: [Double]          // [غرب، جنوب، شرق، شمال]
    var file: String
    var bytes: Int64
    var sha256: String?
    var minzoom: Int
    var maxzoom: Int

    var sw: CLLocationCoordinate2D { .init(latitude: bbox[1], longitude: bbox[0]) }
    var ne: CLLocationCoordinate2D { .init(latitude: bbox[3], longitude: bbox[2]) }
}

struct RegionManifest: Codable, Equatable {
    var version: Int
    var styleZip: String
    var attribution: String?
    var regions: [RegionPack]
}

/// تنزيل خرائط السعودية كاملة أو بالمناطق الخمس مرة واحدة (ملفات MBTiles متجهية مبنية من OpenStreetMap)،
/// مع حزمة النمط (الخطوط والرموز) محليًا، فتعمل الخريطة كاملة دون إنترنت. خيار «المنطقة الظاهرة» يبقى كما هو.
@MainActor
final class RegionPackService: NSObject, ObservableObject {
    static let shared = RegionPackService()
    nonisolated static let base = "https://github.com/oalmuqbel-cpu/ShettaMaps2/releases/download/region-maps/"

    @Published private(set) var manifest: RegionManifest?
    @Published private(set) var loadingManifest = false
    @Published private(set) var manifestFailed = false
    /// تقدم التنزيل الجاري لكل منطقة (٠–١).
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var installed: [String: Int] = [:]   // المعرّف ← نسخة البيانات المنزلة
    @Published var lastError: String?

    private let installedKey = "regionPacksInstalled"
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "com.almuqbel.ShettaMaps2.regionpacks")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        c.allowsCellularAccess = true
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        if let d = UserDefaults.standard.dictionary(forKey: installedKey) as? [String: Int] { installed = d }
        _ = session   // إعادة الاتصال بالتنزيلات الجارية في الخلفية
    }

    nonisolated static var styleDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineStyle", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// المساحة الفارغة في الجهاز.
    var freeBytes: Int64 {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
    }

    func isInstalled(_ p: RegionPack) -> Bool { installed[p.id] != nil && OfflineMapManager.shared.regionTileset(id: p.id) != nil }
    func hasUpdate(_ p: RegionPack) -> Bool { (installed[p.id] ?? 0) < (manifest?.version ?? 0) && isInstalled(p) }

    func loadManifest() async {
        guard !loadingManifest else { return }
        loadingManifest = true
        defer { loadingManifest = false }
        var req = URLRequest(url: URL(string: Self.base + "manifest.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Samt/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONDecoder().decode(RegionManifest.self, from: data) else {
            manifestFailed = manifest == nil
            return
        }
        manifest = m
        manifestFailed = false
    }

    func download(_ p: RegionPack) {
        guard tasks[p.id] == nil else { return }
        guard freeBytes == 0 || freeBytes > p.bytes + 200_000_000 else {
            lastError = "المساحة الفارغة لا تكفي لتنزيل \(p.title). احذف ملفات أو منطقة أخرى ثم حاول."
            return
        }
        let t = session.downloadTask(with: URL(string: Self.base + p.file)!)
        t.taskDescription = p.id
        tasks[p.id] = t
        progress[p.id] = 0
        t.resume()
    }

    func cancel(_ p: RegionPack) {
        tasks[p.id]?.cancel()
        tasks[p.id] = nil
        progress[p.id] = nil
    }

    func delete(_ p: RegionPack) {
        OfflineMapManager.shared.removeRegionTileset(id: p.id)
        installed[p.id] = nil
        UserDefaults.standard.set(installed, forKey: installedKey)
    }

    /// حزمة النمط (style.json والخطوط والرموز)، تُنزَّل مرة واحدة لكل المناطق.
    private func ensureStylePack() async throws {
        let marker = Self.styleDir.appendingPathComponent("style.json")
        let version = manifest?.version ?? 1
        if FileManager.default.fileExists(atPath: marker.path), UserDefaults.standard.integer(forKey: "stylePackVersion") >= version { return }
        let url = URL(string: Self.base + (manifest?.styleZip ?? "samt-style.zip"))!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try StoredZip.extract(data, to: Self.styleDir)
        UserDefaults.standard.set(version, forKey: "stylePackVersion")
    }

    private func finish(id: String, file: URL) async {
        defer { tasks[id] = nil; progress[id] = nil }
        guard let p = manifest?.regions.first(where: { $0.id == id }) else { return }
        do {
            try await ensureStylePack()
            try OfflineMapManager.shared.installRegionTileset(id: p.id, title: p.title, from: file, bbox: p.bbox,
                                                              minZoom: p.minzoom, maxZoom: p.maxzoom, styleDir: Self.styleDir)
            installed[p.id] = manifest?.version ?? 1
            UserDefaults.standard.set(installed, forKey: installedKey)
            // الطبقات المختارة (الردميات، حدود السرعة...) للمنطقة نفسها
            await OfflinePackageService.shared.downloadLayers(sw: p.sw, ne: p.ne)
        } catch {
            lastError = "تعذّر تثبيت \(p.title): \(error.localizedDescription)"
        }
    }
}

extension RegionPackService: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { self.progress[id] = f }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // الملف المؤقت يُحذف بعد هذه الدالة: ننقله فورًا
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("region-\(id)-\(UUID().uuidString).mbtiles")
        do { try FileManager.default.moveItem(at: location, to: tmp) } catch { return }
        let ok = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        MainActor.assumeIsolated {
            if ok {
                Task { await self.finish(id: id, file: tmp) }
            } else {
                self.lastError = "تعذّر تنزيل المنطقة من الخادم."
                self.tasks[id] = nil; self.progress[id] = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        MainActor.assumeIsolated {
            self.tasks[id] = nil; self.progress[id] = nil
            if !cancelled { self.lastError = "انقطع تنزيل المنطقة: \(error.localizedDescription)" }
        }
    }
}

/// استخراج ملف zip مخزّن دون ضغط (store) — صيغة حزمة النمط التي يجهزها خادم البناء.
enum StoredZip {
    enum ZipError: Error { case unsupported, corrupt }

    static func extract(_ data: Data, to dir: URL) throws {
        var i = 0
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        while i + 30 <= bytes.count, u32(i) == 0x04034b50 {
            let flags = u16(i + 6), method = u16(i + 8)
            let size = u32(i + 18), nameLen = u16(i + 26), extraLen = u16(i + 28)
            guard method == 0, flags & 0x08 == 0 else { throw ZipError.unsupported }
            let nameStart = i + 30, dataStart = nameStart + nameLen + extraLen
            guard dataStart + size <= bytes.count,
                  let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) else { throw ZipError.corrupt }
            // حماية من المسارات الخارجية
            guard !name.contains(".."), !name.hasPrefix("/") else { throw ZipError.corrupt }
            let dest = dir.appendingPathComponent(name)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(bytes[dataStart..<(dataStart + size)]).write(to: dest, options: .atomic)
            }
            i = dataStart + size
        }
    }
}
