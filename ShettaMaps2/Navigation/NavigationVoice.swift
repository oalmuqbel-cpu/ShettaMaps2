import Foundation
import CoreLocation
import Combine

/// يقرر متى تُقال التعليمات الصوتية أثناء الملاحة (منطق مستقل قابل للاختبار).
struct VoiceGuidancePlanner {
    /// عتبات التنبيه قبل المنعطف (متر): تنبيه مبكر ثم تنبيه عند الاقتراب.
    static let roadEarly: Double = 600
    static let roadNear: Double = 150
    /// عتبات التنبيه للخط المباشر.
    static let directThresholds: [Double] = [5_000, 1_000, 200]

    private var revision = -1
    private var spoken: Set<String> = []
    private var lastRoute: RoadRoute?
    private var arrivedSpoken = false

    /// يعيد الجمل الواجب قولها لهذه اللقطة (عادة صفر أو جملة واحدة).
    mutating func phrases(for snap: NavigationSnapshot, here: CLLocationCoordinate2D?) -> [String] {
        guard snap.isNavigating, let plan = snap.plan else {
            revision = snap.planRevision; spoken = []; lastRoute = nil; arrivedSpoken = false
            return []
        }
        var out: [String] = []
        if snap.planRevision != revision {
            revision = snap.planRevision
            spoken = []; lastRoute = nil; arrivedSpoken = false
            if let here {
                out.append(VoicePhrases.start(plan.destination.name, GeoMath.distance(here, plan.destination.coordinate)))
            }
        }
        if snap.status == .arrived {
            if !arrivedSpoken, let t = snap.progress?.target {
                arrivedSpoken = true
                out.append(VoicePhrases.arrived(t.name))
            }
            return out
        }
        arrivedSpoken = false
        guard let here else { return out }

        if let route = snap.roadRoute, let step = snap.currentRoadStep {
            if let last = lastRoute, last != route, !out.contains(where: { $0.hasPrefix("بدأت") }) {
                out.append("تم تحديث المسار")
            }
            lastRoute = route
            let d = GeoMath.distance(here, step.endCoordinate)
            let k = "\(snap.roadStepIndex)|\(step.instruction)"
            if d <= Self.roadNear {
                if !spoken.contains(k + "|near") {
                    spoken.insert(k + "|near"); spoken.insert(k + "|early")
                    out.append(step.instruction)
                }
            } else if d <= Self.roadEarly, step.distance > Self.roadNear * 2 {
                if !spoken.contains(k + "|early") {
                    spoken.insert(k + "|early")
                    out.append(VoicePhrases.ahead(d, step.instruction))
                }
            }
        } else if let p = snap.progress {
            for t in Self.directThresholds where p.distanceToTarget <= t && p.distanceToTarget > t * 0.5 {
                let k = "direct|\(p.targetIndex)|\(Int(t))"
                if !spoken.contains(k) {
                    // عتبة واحدة فقط لكل اقتراب (لا نقول ٥ كم ثم ١ كم في اللحظة نفسها)
                    for o in Self.directThresholds where o >= t { spoken.insert("direct|\(p.targetIndex)|\(Int(o))") }
                    let side = p.relativeBearing.map { Self.side($0) } ?? ""
                    out.append("\(p.target.name) بعد \(VoicePhrases.distance(p.distanceToTarget))\(side)")
                }
                break
            }
        }
        return out
    }

    static func side(_ relative: Double) -> String {
        let a = abs(relative)
        if a < 25 { return "، أمامك" }
        if a > 150 { return "، خلفك" }
        return relative > 0 ? "، على يمينك" : "، على يسارك"
    }
}

/// يربط حالة الملاحة بالتعليمات الصوتية للهاتف وCarPlay معًا.
@MainActor
final class NavigationVoice {
    static let shared = NavigationVoice()
    private var planner = VoiceGuidancePlanner()
    private var cancellable: AnyCancellable?

    func start() {
        guard cancellable == nil else { return }
        cancellable = SharedNavigationState.shared.$snapshot
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] snap in self?.handle(snap) }
    }

    private func handle(_ snap: NavigationSnapshot) {
        let lines = planner.phrases(for: snap, here: LocationManager.shared.location?.coordinate)
        guard VoicePrompter.enabled, let line = lines.last else { return }
        VoicePrompter.shared.speak(line)
    }
}
