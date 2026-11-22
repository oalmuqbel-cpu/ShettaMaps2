import Foundation
import CoreLocation
import CoreGraphics

/// إعدادات تنبيه السرعة المشتركة بين الهاتف وCarPlay.
enum SpeedAlertSettings {
    static let enabledKey = "speedAlertEnabled"
    static let marginKey = "speedAlertMargin"
    static let soundKey = "speedAlertSound"
    /// خيارات الهامش (كم/س). الهامش يحدد متى يصدر التنبيه فقط، ولا يغيّر الحد النظامي المعروض.
    static let marginOptions = [0, 5, 10, 15, 20]

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var sound: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
    static var margin: Int {
        let v = UserDefaults.standard.object(forKey: marginKey) as? Int ?? 5
        return marginOptions.contains(v) ? v : 5
    }
    /// الخيار التالي في القائمة (للتبديل بلمسة من شاشة السيارة).
    static func nextMargin() -> Int {
        let i = marginOptions.firstIndex(of: margin) ?? 1
        return marginOptions[(i + 1) % marginOptions.count]
    }
    static func marginText(_ m: Int) -> String { m == 0 ? "عند الحد مباشرة" : "+\(m) كم/س فوق الحد" }
}

/// منطق تنبيه تجاوز السرعة (بلا واجهة، قابل للاختبار):
/// - لا تنبيه دون حد موثوق أو سرعة حية.
/// - التنبيه بعد تجاوز (الحد + الهامش) لمدة متواصلة، مرة واحدة لكل تجاوز.
/// - ينتهي التجاوز عند النزول تحت الحد النظامي نفسه، وبعده مهلة قبل أي تنبيه جديد حتى لا يتكرر مع التذبذب.
/// - دخول طريق بحد أقل أثناء التجاوز ينبه فورًا مرة واحدة للحد الجديد.
struct OverspeedMonitor {
    enum Event: Equatable { case alert(limit: Int) }

    var margin: Double
    var sustain: TimeInterval
    var cooldown: TimeInterval

    init(margin: Double = 5, sustain: TimeInterval = 2, cooldown: TimeInterval = 30) {
        self.margin = margin; self.sustain = sustain; self.cooldown = cooldown
    }

    /// السرعة الآن فوق (الحد + الهامش) لمدة كافية.
    private(set) var isOver = false
    private var overSince: Date?
    private var lastAlertAt: Date?
    /// الحد الذي نُبّه له في التجاوز الحالي (nil = لا يوجد تجاوز قائم).
    private var alertedLimit: Int?

    mutating func update(limit: Int?, speedKmh: Double?, at now: Date) -> Event? {
        guard let limit, limit > 0, let v = speedKmh, v >= 0 else {
            // لا بيانات موثوقة: لا نعرض تجاوزًا ولا ننبه. لا نمسح التجاوز المنبَّه له حتى لا يتكرر بعد عودة الإشارة.
            isOver = false
            overSince = nil
            return nil
        }
        let threshold = Double(limit) + margin
        if v > threshold {
            if overSince == nil { overSince = now }
            guard let since = overSince, now.timeIntervalSince(since) >= sustain else { return nil }
            isOver = true
            if let previous = alertedLimit {
                // تجاوز قائم: ننبه مجددًا فقط إذا انخفض الحد (دخول طريق أبطأ)
                guard limit < previous else { return nil }
                alertedLimit = limit
                lastAlertAt = now
                return .alert(limit: limit)
            }
            if let last = lastAlertAt, now.timeIntervalSince(last) < cooldown {
                alertedLimit = limit   // يُعد تنبيهًا لهذا التجاوز دون تكرار مزعج
                return nil
            }
            alertedLimit = limit
            lastAlertAt = now
            return .alert(limit: limit)
        }
        overSince = nil
        isOver = false
        if v <= Double(limit) { alertedLimit = nil }   // انتهى التجاوز فعليًا
        return nil
    }
}

/// مطابقة الموقع مع أقرب طريق له حد مسجل، مع مراعاة اتجاه السير (قابل للاختبار).
enum SpeedLimitMatcher {
    struct Road {
        var forward: Int
        var backward: Int
        var oneway: Bool
        var name: String?
        var points: [CLLocationCoordinate2D]
    }

    /// أقرب طريق ضمن maxDistance يوافق اتجاه السير (إن عُرف). nil عند عدم وجود حد مسجل.
    static func best(at c: CLLocationCoordinate2D, course: Double?, roads: [Road],
                     maxDistance: Double = 25) -> (limit: Int, name: String?)? {
        var best: (dist: Double, limit: Int, name: String?)?
        for road in roads where road.points.count > 1 {
            for i in 0..<(road.points.count - 1) {
                let a = road.points[i], b = road.points[i + 1]
                let dist = distanceToSegment(c, a, b)
                guard dist < maxDistance else { continue }
                var limit = road.forward
                if let course {
                    let segBearing = GeoMath.bearing(from: a, to: b)
                    let diff = abs(((course - segBearing + 540).truncatingRemainder(dividingBy: 360)) - 180)
                    if diff > 135 {
                        if road.oneway { continue }   // عكس اتجاه طريق باتجاه واحد: ليس طريقنا
                        limit = road.backward
                    } else if diff > 45 {
                        continue   // طريق متقاطع وليس الذي نسير عليه
                    }
                }
                guard limit > 0 else { continue }
                if best == nil || dist < best!.dist {
                    best = (dist, limit, (road.name?.isEmpty ?? true) ? nil : road.name)
                }
            }
        }
        return best.map { ($0.limit, $0.name) }
    }

    static func distanceToSegment(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let kx = cos(p.latitude * .pi / 180) * 111_320, ky = 110_540.0
        let ax = (a.longitude - p.longitude) * kx, ay = (a.latitude - p.latitude) * ky
        let bx = (b.longitude - p.longitude) * kx, by = (b.latitude - p.latitude) * ky
        let dx = bx - ax, dy = by - ay
        let l2 = dx * dx + dy * dy
        let t = l2 == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / l2))
        return hypot(ax + t * dx, ay + t * dy)
    }
}

/// حالة حد السرعة المعروضة، للتمييز بين المعروف والمفقود وغير الموثوق.
enum SpeedLimitState: Equatable {
    /// حد مسجل للطريق الحالي واتجاه السير.
    case known(Int)
    /// الطريق بلا حد مسجل في البيانات (لا يُخمَّن).
    case noData
    /// بيانات المنطقة غير منزلة بعد.
    case notDownloaded
    /// إشارة GPS ضعيفة أو منقطعة: لا يمكن تحديد الطريق بثقة.
    case weakSignal
    /// الميزة مطفأة.
    case off

    var limit: Int? { if case .known(let l) = self { return l }; return nil }
    var note: String? {
        switch self {
        case .known, .off: return nil
        case .noData: return "لا يوجد حد مسجل لهذا الطريق"
        case .notDownloaded: return "بيانات الحدود غير منزلة لهذه المنطقة"
        case .weakSignal: return "الإشارة ضعيفة: الحد غير مؤكد"
        }
    }
}

/// قراءة سرعة حية فقط: تُرفض القراءات القديمة أو غير الدقيقة.
enum LiveSpeed {
    static let maxAge: TimeInterval = 3

    static func kmh(_ loc: CLLocation?, now: Date = Date(), recent: [CLLocation] = []) -> Double? {
        guard let loc, now.timeIntervalSince(loc.timestamp) <= maxAge, loc.speed >= 0 else { return nil }
        if loc.speedAccuracy > 5 { return nil }   // دقة السرعة أسوأ من ±18 كم/س
        // واقف: سرعة ضمن خطأ القياس، أو لم يتحرك الموقع فعليًا خلال الثواني الماضية رغم قراءة سرعة صغيرة
        if loc.speedAccuracy > 0, loc.speed <= loc.speedAccuracy { return 0 }
        if loc.speed < 15 / 3.6, isStationary(loc, recent: recent) { return 0 }
        return loc.speed * 3.6
    }

    /// لم يبتعد الموقع أكثر من 1.2 م/ث في المتوسط خلال 3 إلى 8 ثوانٍ مضت.
    static func isStationary(_ loc: CLLocation, recent: [CLLocation]) -> Bool {
        guard let ref = recent.last(where: {
            let dt = loc.timestamp.timeIntervalSince($0.timestamp)
            return dt >= 3 && dt <= 8 && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 30
        }) else { return false }
        let dt = loc.timestamp.timeIntervalSince(ref.timestamp)
        return loc.distance(from: ref) / dt < 1.2
    }
}

/// يحدد هل ترسل السيارة إزاحة السحب تراكمية (كما توثّق Apple) أم فرقًا لكل تحديث،
/// بمقارنة كل احتمال مع ما تتوقعه سرعة الإصبع، ويعيد الإزاحة الواجب تطبيقها الآن.
struct PanTranslationTracker {
    /// موجب = تراكمي، سالب = فرق لكل تحديث.
    private(set) var score: Double = 0
    var isDelta: Bool { score < -1.5 }

    mutating func reset() { score = 0 }

    mutating func step(translation t: CGPoint, previous p: CGPoint, velocity v: CGPoint, dt: TimeInterval?) -> CGPoint {
        let cumulativeStep = CGPoint(x: t.x - p.x, y: t.y - p.y)
        if let dt, dt > 0.004, dt < 0.25, hypot(v.x, v.y) > 60 {
            let expected = CGPoint(x: v.x * dt, y: v.y * dt)
            let errCum = hypot(cumulativeStep.x - expected.x, cumulativeStep.y - expected.y)
            let errDelta = hypot(t.x - expected.x, t.y - expected.y)
            if errDelta * 1.5 < errCum { score = max(-5, score - 1) }
            else if errCum * 1.5 < errDelta { score = min(5, score + 1) }
        }
        return isDelta ? t : cumulativeStep
    }
}
