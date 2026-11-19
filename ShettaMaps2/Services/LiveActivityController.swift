import Foundation
import ActivityKit
import Combine

/// يعرض الملاحة الحالية نشاطًا مباشرًا على شاشة القفل والجزيرة الديناميكية، ويحدّثه باعتدال
/// (كل ٥٠ م أو ٢٠ ثانية) حفاظًا على البطارية وحدود النظام.
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()
    static let enabledKey = "liveActivityEnabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var activity: Activity<NavigationActivityAttributes>?
    private var cancellable: AnyCancellable?
    private var lastState: NavigationActivityAttributes.ContentState?
    private var lastAt = Date.distantPast
    private var revision = -1

    private init() {}

    func start() {
        guard cancellable == nil else { return }
        // نشاط متبقٍ من تشغيل سابق
        activity = Activity<NavigationActivityAttributes>.activities.first
        cancellable = SharedNavigationState.shared.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handle($0) }
    }

    private func handle(_ s: NavigationSnapshot) {
        guard Self.enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { end(); return }
        guard s.isNavigating, let plan = s.plan, let p = s.progress else { end(); return }
        let state = NavigationActivityAttributes.ContentState(
            remaining: p.remainingDistance, toTarget: p.distanceToTarget, targetName: p.target.name,
            arrowDegrees: p.relativeBearing ?? p.bearingToTarget, relative: p.relativeBearing != nil,
            cardinal: GeoMath.cardinalName(p.bearingToTarget),
            eta: p.estimatedSeconds.map { Date().addingTimeInterval($0) }, arrived: s.status == .arrived)

        if activity == nil || revision != s.planRevision {
            revision = s.planRevision
            end()
            do {
                activity = try Activity.request(attributes: .init(destination: plan.destination.name),
                                                content: .init(state: state, staleDate: Date().addingTimeInterval(600)))
                lastState = state; lastAt = Date()
            } catch {
                appLog.error("Live Activity: \(error.localizedDescription)")
            }
            return
        }
        guard let last = lastState else { return }
        let moved = abs(last.remaining - state.remaining)
        let turned = abs(GeoMath.angleDelta(from: last.arrowDegrees, to: state.arrowDegrees))
        guard state.arrived != last.arrived || state.targetName != last.targetName || moved >= 50 || turned >= 20
                || Date().timeIntervalSince(lastAt) >= 20 else { return }
        lastState = state; lastAt = Date()
        let a = activity
        Task { await a?.update(.init(state: state, staleDate: Date().addingTimeInterval(600))) }
    }

    private func end() {
        guard let a = activity else { return }
        activity = nil; lastState = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
