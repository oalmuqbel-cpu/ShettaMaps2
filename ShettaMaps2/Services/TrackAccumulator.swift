import Foundation
import CoreLocation

/// منطق تجميع نقاط المسار وحساب الإحصائيات وتصفية القراءات الرديئة. خالص وقابل للاختبار.
struct TrackAccumulator {
    struct Config {
        var maxHorizontalAccuracy: Double = 65     // نرفض القراءات الأسوأ من ذلك
        var minPointSpacing: Double = 3            // متر بين نقطتين متتاليتين
        var maxPlausibleSpeed: Double = 70         // م/ث ≈ 250 كم/س (قفزة خاطئة)
        var movingSpeedThreshold: Double = 0.5     // م/ث: أقل من ذلك يعد توقفًا
    }

    enum Rejection: Equatable { case poorAccuracy, tooClose, implausibleJump, outOfOrder }

    var config = Config()
    private(set) var points: [TrackPoint] = []
    private(set) var distance: Double = 0
    private(set) var movingSeconds: Double = 0
    private(set) var maxSpeed: Double = 0
    private(set) var segment: Int = 0
    private var needsNewSegment = false

    init(config: Config = Config(), existing: [TrackPoint] = []) {
        self.config = config
        for p in existing { _ = append(p, force: true) }
        if let last = existing.last { segment = last.segment }
    }

    /// يبدأ مقطعًا جديدًا عند الاستئناف بعد الإيقاف المؤقت.
    mutating func markPaused() { needsNewSegment = true }

    /// يضيف نقطة إن كانت مقبولة. يُرجع سبب الرفض إن رُفضت.
    @discardableResult
    mutating func append(_ p: TrackPoint, force: Bool = false) -> Rejection? {
        if !force, let acc = p.hAcc, acc > config.maxHorizontalAccuracy { return .poorAccuracy }

        if needsNewSegment, !points.isEmpty {
            segment += 1
            needsNewSegment = false
        }
        var point = p
        if !force { point.segment = segment }

        guard let last = points.last else {
            points.append(point)
            return nil
        }
        let dt = point.time.timeIntervalSince(last.time)
        if !force && dt <= 0 { return .outOfOrder }

        let d = GeoMath.distance(last.coordinate, point.coordinate)
        let sameSegment = last.segment == point.segment

        if !force && sameSegment {
            if d < config.minPointSpacing { return .tooClose }
            if dt > 0, d / dt > config.maxPlausibleSpeed { return .implausibleJump }
        }

        points.append(point)
        if sameSegment {
            distance += d
            let impliedSpeed = dt > 0 ? d / dt : 0
            if impliedSpeed >= config.movingSpeedThreshold, dt < 600 { movingSeconds += dt }
            let s = point.speed ?? impliedSpeed
            if s.isFinite, s <= config.maxPlausibleSpeed { maxSpeed = max(maxSpeed, s) }
        }
        return nil
    }

    var coordinates: [CLLocationCoordinate2D] { points.map(\.coordinate) }

    /// المقاطع منفصلة لرسم كل مقطع كخط مستقل.
    var segments: [[CLLocationCoordinate2D]] { Self.segments(of: points) }

    static func segments(of points: [TrackPoint]) -> [[CLLocationCoordinate2D]] {
        var result: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var seg = points.first?.segment ?? 0
        for p in points {
            if p.segment != seg {
                if current.count > 1 { result.append(current) }
                current = []
                seg = p.segment
            }
            current.append(p.coordinate)
        }
        if current.count > 1 { result.append(current) }
        return result
    }
}
