import Foundation
import CoreLocation
import MapKit

/// شكل مطر ناعم لمستوى شدة واحد: حد خارجي وثقوب داخلية (ما يكون المطر فيها أخف).
struct RainShape: Identifiable, Equatable {
    var id: String
    var level: Int
    var rings: [[CLLocationCoordinate2D]]

    static func == (a: RainShape, b: RainShape) -> Bool { a.id == b.id }

    /// مضلع MapKit مع ثقوبه.
    var polygon: MKPolygon {
        let holes = rings.dropFirst().map { MKPolygon(coordinates: $0, count: $0.count) }
        return MKPolygon(coordinates: rings[0], count: rings[0].count, interiorPolygons: holes.isEmpty ? nil : Array(holes))
    }
}

/// ساعة واحدة من التوقعات.
struct RainFrame: Equatable {
    var time: Date
    var shapes: [RainShape]
    var maxRate: Double
}

/// توقعات الأمطار لـ48 ساعة قادمة (نموذج GFS من NOAA، دقة 0.25°، كل ساعة)، تُجهَّز على خادم GitHub
/// كل 6 ساعات أشكالًا ناعمة لأربعة مستويات شدة، ويقرؤها التطبيق ملفًا واحدًا (يعمل دون إنترنت بعد تنزيله).
@MainActor
final class RainForecastService: ObservableObject {
    static let shared = RainForecastService()
    nonisolated static let url = URL(string: "https://github.com/oalmuqbel-cpu/ShettaMaps2/releases/download/rain-forecast/rain-forecast.json")!
    nonisolated static let attribution = "توقعات نموذج GFS من NOAA (الولايات المتحدة)، كل ساعة لمدة يومين."

    @Published private(set) var frames: [RainFrame] = []
    @Published private(set) var runTime: Date?
    @Published private(set) var loading = false
    @Published private(set) var failed = false
    /// الساعة المختارة في الشريط (٠ = الساعة الحالية).
    @Published var index = 0

    private var lastCheck = Date.distantPast
    private var allFrames: [RainFrame] = []

    private init() {
        if let d = try? Data(contentsOf: Self.cacheURL), let parsed = try? Self.parse(d) {
            allFrames = parsed.frames
            runTime = parsed.run
            trimToNow()
        }
    }

    var selected: RainFrame? { frames.indices.contains(index) ? frames[index] : frames.first }

    /// الساعات القادمة فقط: تبدأ من الساعة الحالية.
    private func trimToNow() {
        let start = Date().addingTimeInterval(-30 * 60)
        let keepTime = selected?.time
        frames = allFrames.filter { $0.time >= start }
        if let t = keepTime, let i = frames.firstIndex(where: { $0.time == t }) { index = i } else { index = 0 }
    }

    /// تنزيل أحدث ملف (مرة كل ٣٠ دقيقة على الأكثر).
    func refresh(force: Bool = false) async {
        trimToNow()
        guard force || Date().timeIntervalSince(lastCheck) > 30 * 60 || allFrames.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        var req = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40)
        req.setValue("Samt/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let parsed = try? await Task.detached(priority: .userInitiated, operation: { try Self.parse(data) }).value else {
            failed = allFrames.isEmpty
            return
        }
        lastCheck = Date()
        failed = false
        try? data.write(to: Self.cacheURL, options: .atomic)
        allFrames = parsed.frames
        runTime = parsed.run
        trimToNow()
    }

    private nonisolated static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("rain-forecast.json")
    }

    /// قراءة الملف: frames[{t, max, levels[{l, p:[[ [lon,lat]... ] (حلقات) ]}]}]
    nonisolated static func parse(_ data: Data) throws -> (run: Date?, frames: [RainFrame]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["frames"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        let run = (root["run"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        var frames: [RainFrame] = []
        for f in list {
            guard let t = (f["t"] as? NSNumber)?.doubleValue else { continue }
            var shapes: [RainShape] = []
            for (li, lv) in ((f["levels"] as? [[String: Any]]) ?? []).enumerated() {
                let level = (lv["l"] as? NSNumber)?.intValue ?? li + 1
                for (pi, poly) in ((lv["p"] as? [[[[Double]]]]) ?? []).enumerated() {
                    let rings = poly.map { ring in ring.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) : nil } }
                        .filter { $0.count >= 3 }
                    guard !rings.isEmpty else { continue }
                    shapes.append(RainShape(id: "\(Int(t))-\(level)-\(pi)", level: level, rings: rings))
                }
            }
            frames.append(RainFrame(time: Date(timeIntervalSince1970: t), shapes: shapes,
                                    maxRate: (f["max"] as? NSNumber)?.doubleValue ?? 0))
        }
        return (run, frames.sorted { $0.time < $1.time })
    }
}
