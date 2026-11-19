import Foundation
import UIKit
import CoreLocation

/// «المطر الآن»: معدل هطول المطر الفعلي من القمر الصناعي Meteosat-9 فوق المحيط الهندي (45.5° شرقًا)،
/// منتج H SAF H63 من EUMETSAT، صورة كل ١٥ دقيقة وتتأخر قرابة ٣٥ دقيقة. يغطي السعودية والخليج كاملة.
/// البيانات مفتوحة (CC BY 4.0) بشرط ذكر المصدر. الصورة الملونة تُحوَّل إلى مربعات بشدة المطر
/// لتُرسم بنفس طبقة الأمطار في كل الخرائط (الهاتف، دون إنترنت، CarPlay).
@MainActor
final class RainNowService: ObservableObject {
    static let shared = RainNowService()

    /// عرض المطر الفعلي من الأقمار (true) أو توقعات النموذج (false).
    static let modeKey = "rainNowMode"
    static var observedMode: Bool { UserDefaults.standard.object(forKey: modeKey) as? Bool ?? true }

    static let attribution = "يحتوي على بيانات EUMETSAT (Meteosat، H SAF H63)"
    static let base = "https://view.eumetsat.int/geoserver"
    static let layer = "msg_iodc:h63"
    static let step: TimeInterval = 15 * 60
    static let frameCount = 8   // آخر ساعتين

    @Published private(set) var frames: [Date] = []
    /// الصورة المختارة في شريط الوقت (الأخيرة افتراضيًا).
    @Published var index: Int = 0 { didSet { if oldValue != index { Task { await loadSelected() } } } }
    @Published private(set) var cells: [RainCell] = []
    @Published private(set) var loading = false
    @Published private(set) var failed = false

    private var latestCheckedAt = Date.distantPast
    private var box: (Double, Double, Double, Double)?
    private var cache: [String: [RainCell]] = [:]
    private var inflight: Set<String> = []
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    var selectedTime: Date? { frames.indices.contains(index) ? frames[index] : nil }
    var isLatest: Bool { index == frames.count - 1 }

    /// يُستدعى عند تحريك الخريطة أو كل بضع دقائق.
    func refresh(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async {
        box = Self.requestBox(sw: sw, ne: ne)
        if Date().timeIntervalSince(latestCheckedAt) > 5 * 60 || frames.isEmpty {
            await updateFrames()
        }
        await loadSelected()
    }

    /// آخر صورة متاحة من الخادم (وقت البعد الزمني في وصف الطبقة).
    private func updateFrames() async {
        let url = URL(string: "\(Self.base)/msg_iodc/h63/ows?service=WMS&request=GetCapabilities&version=1.3.0")!
        var latest: Date?
        if let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
           let xml = String(data: data, encoding: .utf8) {
            latest = Self.latestTime(inCapabilities: xml)
        }
        // احتياط: الصور تتأخر قرابة ٣٥ دقيقة، فنأخذ ما قبل ٤٥ دقيقة مقربًا لربع ساعة
        let end = latest ?? Self.roundDown(Date().addingTimeInterval(-45 * 60))
        latestCheckedAt = Date()
        let wasLatest = frames.isEmpty || isLatest
        let newFrames = (0..<Self.frameCount).reversed().map { end.addingTimeInterval(-Double($0) * Self.step) }
        if newFrames != frames {
            frames = newFrames
            if wasLatest { index = frames.count - 1 }
        }
    }

    private func loadSelected() async {
        guard let t = selectedTime, let b = box else { return }
        let key = "\(Int(t.timeIntervalSince1970))|\(b)"
        if let c = cache[key] { cells = c; failed = false; return }
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        loading = true
        defer { loading = false; inflight.remove(key) }
        let (w, h) = Self.pixels(for: b)
        let iso = ISO8601DateFormatter().string(from: t)
        // WMS 1.3.0 مع EPSG:4326: ترتيب الحدود خط عرض ثم خط طول
        let s = "\(Self.base)/wms?service=WMS&version=1.3.0&request=GetMap&layers=\(Self.layer)&styles=&crs=EPSG:4326"
            + "&bbox=\(b.0),\(b.1),\(b.2),\(b.3)&width=\(w)&height=\(h)&format=image/png&transparent=true&time=\(iso)"
        guard let url = URL(string: s),
              let (data, resp) = try? await session.data(from: url), (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data)?.cgImage else { failed = true; return }
        let decoded = Self.cells(from: img, box: b)
        failed = false
        if cache.count > 40 { cache.removeAll() }
        cache[key] = decoded
        // لا نستبدل إن تغيّر الاختيار أثناء التحميل
        if selectedTime == t { cells = decoded }
    }

    // MARK: - أدوات (مختبرة)

    /// المنطقة المطلوبة: الظاهرة مع هامش، محصورة في الجزيرة العربية وما حولها، ومقربة حتى يُعاد استخدام المخزن.
    nonisolated static func requestBox(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) -> (Double, Double, Double, Double) {
        let padLat = max(0.3, (ne.latitude - sw.latitude) * 0.25), padLon = max(0.3, (ne.longitude - sw.longitude) * 0.25)
        func r(_ v: Double, _ up: Bool) -> Double { (up ? (v * 4).rounded(.up) : (v * 4).rounded(.down)) / 4 }
        let minLat = max(10, r(sw.latitude - padLat, false)), maxLat = min(36, r(ne.latitude + padLat, true))
        let minLon = max(32, r(sw.longitude - padLon, false)), maxLon = min(62, r(ne.longitude + padLon, true))
        return (minLat, minLon, max(minLat + 0.25, maxLat), max(minLon + 0.25, maxLon))
    }

    /// أبعاد الصورة: دقة القمر قرابة ٤ كم (0.04°)، وحد أقصى ٢٢٠ نقطة في كل اتجاه.
    nonisolated static func pixels(for b: (Double, Double, Double, Double)) -> (Int, Int) {
        let spanLat = b.2 - b.0, spanLon = b.3 - b.1
        let deg = max(0.04, max(spanLat, spanLon) / 220)
        return (max(8, Int((spanLon / deg).rounded())), max(8, Int((spanLat / deg).rounded())))
    }

    nonisolated static func roundDown(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / step).rounded(.down) * step)
    }

    /// آخر وقت في وصف البعد الزمني: «البداية/النهاية/PT15M».
    nonisolated static func latestTime(inCapabilities xml: String) -> Date? {
        guard let r = xml.range(of: "<Dimension name=\"time\""),
              let close = xml[r.upperBound...].range(of: ">"),
              let end = xml[close.upperBound...].range(of: "</Dimension>") else { return nil }
        let value = xml[close.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let last = value.split(separator: ",").last.map(String.init) ?? value
        let parts = last.split(separator: "/").map(String.init)
        let candidate = parts.count >= 2 ? parts[1] : parts.first ?? ""
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: candidate) ?? ISO8601DateFormatter().date(from: candidate)
    }

    /// ألوان مفتاح المنتج (من صورة المفتاح الرسمية) مع شدة تقريبية بالملم/ساعة لكل لون.
    nonisolated static let palette: [(r: Double, g: Double, b: Double, mm: Double)] = [
        (255, 255, 204, 0.15), (227, 244, 192, 0.6), (198, 232, 179, 1.2), (162, 218, 183, 2),
        (126, 204, 186, 3.5), (96, 194, 191, 5), (65, 183, 196, 7.5), (47, 164, 194, 11),
        (29, 145, 191, 16), (32, 120, 180, 24), (34, 94, 168, 40), (12, 44, 133, 60)
    ]

    /// أقرب لون في المفتاح ← الشدة بالملم/ساعة.
    nonisolated static func intensity(r: Double, g: Double, b: Double) -> Double {
        var best = palette[0], bestD = Double.greatestFiniteMagnitude
        for p in palette {
            let d = (p.r - r) * (p.r - r) + (p.g - g) * (p.g - g) + (p.b - b) * (p.b - b)
            if d < bestD { bestD = d; best = p }
        }
        return best.mm
    }

    /// يحوّل صورة المنتج إلى مربعات: كل صف تُجمع نقاطه المتجاورة بنفس الشدة في مستطيل واحد (عدد أقل من الأشكال).
    nonisolated static func cells(from img: CGImage, box b: (Double, Double, Double, Double)) -> [RainCell] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let dLat = (b.2 - b.0) / Double(h), dLon = (b.3 - b.1) / Double(w)
        var out: [RainCell] = []
        for y in 0..<h {
            // الصف الأول في الذاكرة هو أعلى الصورة (الشمال)
            let latCenter = b.2 - (Double(y) + 0.5) * dLat
            var runStart = -1, runLevel = 0, runMM = 0.0
            func flush(_ endX: Int) {
                guard runStart >= 0, runLevel > 0 else { return }
                let x0 = b.1 + Double(runStart) * dLon, x1 = b.1 + Double(endX) * dLon
                out.append(RainCell(id: "rn-\(y)-\(runStart)", lat: latCenter, lon: (x0 + x1) / 2, size: dLat,
                                    hourly: [runMM], cloud: [], width: x1 - x0))
            }
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = Double(buf[i + 3])
                var level = 0, mm = 0.0
                if a >= 60 {
                    // إلغاء الضرب المسبق بالشفافية لاستعادة اللون الأصلي
                    let k = 255 / a
                    mm = intensity(r: Double(buf[i]) * k, g: Double(buf[i + 1]) * k, b: Double(buf[i + 2]) * k)
                    level = RainScale.level(mm)
                }
                if level != runLevel {
                    flush(x)
                    runStart = level > 0 ? x : -1
                    runLevel = level
                    runMM = mm
                } else if level > 0 {
                    runMM = max(runMM, mm)
                }
            }
            flush(w)
            if out.count > 6000 { break }
        }
        return out
    }
}
