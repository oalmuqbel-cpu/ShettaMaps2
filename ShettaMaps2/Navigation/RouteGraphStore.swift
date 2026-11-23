import Foundation
import CoreLocation

/// ملفات «طرق الملاحة» للمناطق: تنزيلها وحفظها واختيار الملف المناسب لحساب الطريق دون إنترنت.
@MainActor
final class RouteGraphStore: NSObject, ObservableObject {
    static let shared = RouteGraphStore()
    nonisolated static let base = "https://github.com/oalmuqbel-cpu/ShettaMaps2/releases/download/road-graph/"

    struct Pack: Codable, Identifiable, Equatable {
        var id: String
        var file: String
        var bytes: Int64
        var version: Int
    }
    struct Manifest: Codable { var version: Int; var regions: [Pack] }

    @Published private(set) var manifest: Manifest?
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var installed: [String: Int] = [:]
    @Published var lastError: String?
    static var backgroundCompletion: (() -> Void)?

    private let installedKey = "routeGraphsInstalled"
    private var loaded: [String: RouteGraph] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "com.almuqbel.ShettaMaps2.roadgraph")
        c.isDiscretionary = false
        c.sessionSendsLaunchEvents = true
        return URLSession(configuration: c, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
        if let d = UserDefaults.standard.dictionary(forKey: installedKey) as? [String: Int] { installed = d }
        _ = session
    }

    nonisolated static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Routing", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    nonisolated static func url(for id: String) -> URL { dir.appendingPathComponent("roads-\(id).samtroute") }

    func isInstalled(_ id: String) -> Bool {
        installed[id] != nil && FileManager.default.fileExists(atPath: Self.url(for: id).path)
    }
    var hasAny: Bool { installed.keys.contains { isInstalled($0) } }

    func loadManifest() async {
        var req = URLRequest(url: URL(string: Self.base + "roads-manifest.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("Samt/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        manifest = m
    }

    func download(_ id: String) {
        guard tasks[id] == nil, let p = manifest?.regions.first(where: { $0.id == id }) else { return }
        let t = session.downloadTask(with: URL(string: Self.base + p.file)!)
        t.taskDescription = id
        tasks[id] = t
        progress[id] = 0
        t.resume()
    }

    func cancel(_ id: String) { tasks[id]?.cancel(); tasks[id] = nil; progress[id] = nil }

    func delete(_ id: String) {
        loaded[id] = nil
        try? FileManager.default.removeItem(at: Self.url(for: id))
        installed[id] = nil
        UserDefaults.standard.set(installed, forKey: installedKey)
    }

    /// أصغر شبكة منزلة تغطي النقطتين.
    func graph(covering a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> RouteGraph? {
        var candidates: [(RouteGraph, Int)] = []
        for id in installed.keys where isInstalled(id) {
            let g: RouteGraph
            if let x = loaded[id] { g = x } else if let x = try? RouteGraph(url: Self.url(for: id)) { loaded[id] = x; g = x } else { continue }
            if g.covers(a), g.covers(b) { candidates.append((g, g.vertexCount)) }
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    /// منطقة تغطي النقطتين من القائمة (لاقتراح التنزيل).
    func suggestedRegion(for a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> RegionPack? {
        let regions = RegionPackService.shared.manifest?.regions ?? []
        func inside(_ c: CLLocationCoordinate2D, _ p: RegionPack) -> Bool {
            c.longitude >= p.bbox[0] && c.latitude >= p.bbox[1] && c.longitude <= p.bbox[2] && c.latitude <= p.bbox[3]
        }
        return regions.filter { inside(a, $0) && inside(b, $0) }.min { $0.bytes < $1.bytes }
    }

    fileprivate func finish(id: String, file: URL) {
        tasks[id] = nil; progress[id] = nil
        do {
            _ = try RouteGraph(url: file)   // تحقق من صحة الملف قبل اعتماده
            let dest = Self.url(for: id)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
            var v = dest
            var rv = URLResourceValues(); rv.isExcludedFromBackup = true
            try? v.setResourceValues(rv)
            loaded[id] = nil
            installed[id] = manifest?.version ?? 1
            UserDefaults.standard.set(installed, forKey: installedKey)
        } catch {
            lastError = "ملف طرق الملاحة غير صالح، حاول التنزيل مرة أخرى."
        }
    }
}

extension RouteGraphStore: URLSessionDownloadDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            RouteGraphStore.backgroundCompletion?()
            RouteGraphStore.backgroundCompletion = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let f = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated { self.progress[id] = f }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roads-\(id)-\(UUID().uuidString)")
        do { try FileManager.default.moveItem(at: location, to: tmp) } catch { return }
        let ok = (downloadTask.response as? HTTPURLResponse)?.statusCode == 200
        MainActor.assumeIsolated {
            if ok { self.finish(id: id, file: tmp) } else {
                self.lastError = "تعذّر تنزيل طرق الملاحة من الخادم."
                self.tasks[id] = nil; self.progress[id] = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        MainActor.assumeIsolated {
            self.tasks[id] = nil; self.progress[id] = nil
            if !cancelled { self.lastError = "انقطع تنزيل طرق الملاحة: \(error.localizedDescription)" }
        }
    }
}
