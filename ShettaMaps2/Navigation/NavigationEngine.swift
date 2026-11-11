import Foundation
import CoreLocation

/// نوع الإرشاد.
enum GuidanceMode: String, Codable, Equatable {
    /// خط مباشر (إرشاد جغرافي بالاتجاه والمسافة، ليس طريقًا مضمونًا للقيادة).
    case direct
    /// طريق من بيانات Apple Maps عند توفر الإنترنت وتوفر طرق معروفة.
    case road
}

/// خطة ملاحة: نقطة انطلاق اختيارية، نقاط مرور، ووجهة نهائية.
struct NavigationPlan: Codable, Equatable {
    var origin: Waypoint?
    var waypoints: [Waypoint]
    var destination: Waypoint
    var mode: GuidanceMode = .direct
    var tripID: UUID?

    /// الأهداف بالترتيب (نقاط المرور ثم الوجهة).
    var targets: [Waypoint] { waypoints + [destination] }

    /// كل نقاط الخطة بالترتيب لرسم الخطوط المباشرة.
    var allPoints: [Waypoint] { (origin.map { [$0] } ?? []) + targets }
}

struct LegInfo: Equatable {
    var from: Waypoint
    var to: Waypoint
    var distance: Double
    var bearing: Double
}

struct NavigationProgress: Equatable {
    var targetIndex: Int
    var target: Waypoint
    var distanceToTarget: Double
    var bearingToTarget: Double
    /// المسافة المباشرة المتبقية حتى الوجهة النهائية مرورًا ببقية النقاط.
    var remainingDistance: Double
    /// الفرق بين اتجاه الهدف واتجاه الجهاز/السيارة (موجب = يمين).
    var relativeBearing: Double?
    var estimatedSeconds: TimeInterval?
    var isFinalTarget: Bool
}

/// منطق الملاحة الخالص: لا يعتمد على واجهات أو حالة عامة، لتسهيل الاختبار.
enum NavigationEngine {
    static let arrivalRadius: Double = 35 // متر

    static func legs(for plan: NavigationPlan) -> [LegInfo] {
        let pts = plan.allPoints
        guard pts.count > 1 else { return [] }
        return (1..<pts.count).map { i in
            let a = pts[i - 1], b = pts[i]
            return LegInfo(from: a, to: b,
                           distance: GeoMath.distance(a.coordinate, b.coordinate),
                           bearing: GeoMath.bearing(from: a.coordinate, to: b.coordinate))
        }
    }

    static func totalDistance(for plan: NavigationPlan) -> Double {
        legs(for: plan).reduce(0) { $0 + $1.distance }
    }

    static func progress(plan: NavigationPlan, targetIndex: Int, current: CLLocationCoordinate2D,
                         heading: Double?, speed: Double?) -> NavigationProgress {
        let targets = plan.targets
        let idx = min(max(targetIndex, 0), targets.count - 1)
        let target = targets[idx]
        let d = GeoMath.distance(current, target.coordinate)
        let b = GeoMath.bearing(from: current, to: target.coordinate)
        var remaining = d
        if idx + 1 < targets.count {
            for i in (idx + 1)..<targets.count {
                remaining += GeoMath.distance(targets[i - 1].coordinate, targets[i].coordinate)
            }
        }
        let rel = heading.map { GeoMath.angleDelta(from: $0, to: b) }
        var eta: TimeInterval?
        if let s = speed, s > 2 { eta = remaining / s }
        return NavigationProgress(targetIndex: idx, target: target, distanceToTarget: d, bearingToTarget: b,
                                  remainingDistance: remaining, relativeBearing: rel,
                                  estimatedSeconds: eta, isFinalTarget: idx == targets.count - 1)
    }

    static func hasArrived(_ p: NavigationProgress, accuracy: Double?) -> Bool {
        // نوسّع نصف قطر الوصول قليلًا عند ضعف الدقة
        let radius = max(arrivalRadius, min((accuracy ?? 0) * 1.2, 80))
        return p.distanceToTarget <= radius
    }

    /// تعليمة نصية قصيرة للعرض وCarPlay.
    static func instruction(for p: NavigationProgress) -> String {
        guard let rel = p.relativeBearing else {
            return "اتجه \(GeoMath.cardinalName(p.bearingToTarget)) نحو \(p.target.name)"
        }
        switch abs(rel) {
        case ..<15: return "استمر للأمام نحو \(p.target.name)"
        case ..<60: return rel > 0 ? "انحرف يمينًا نحو \(p.target.name)" : "انحرف يسارًا نحو \(p.target.name)"
        case ..<150: return rel > 0 ? "اتجه يمينًا نحو \(p.target.name)" : "اتجه يسارًا نحو \(p.target.name)"
        default: return "استدر للخلف نحو \(p.target.name)"
        }
    }
}
