import Foundation
import CoreLocation
import Combine

enum NavigationStatus: Equatable {
    case idle
    case active
    case arrived
}

/// لقطة موحّدة لحالة الملاحة تستهلكها واجهة الآيفون/الآيباد وواجهة CarPlay معًا،
/// فيرى السائق في السيارة الوجهة والتقدم نفسيهما الظاهرين في الهاتف.
struct NavigationSnapshot: Equatable {
    var status: NavigationStatus = .idle
    var plan: NavigationPlan?
    var progress: NavigationProgress?
    var instruction: String = ""
    var roadRoute: RoadRoute?
    var roadStepIndex: Int = 0
    var notice: String?
    /// يزيد مع كل تغيير في الخطة لتعرف CarPlay متى تعيد إنشاء رحلة جديدة.
    var planRevision: Int = 0

    var isNavigating: Bool { status != .idle }
    var currentRoadStep: RoadStep? {
        guard let r = roadRoute, roadStepIndex < r.steps.count else { return nil }
        return r.steps[roadStepIndex]
    }
}

/// مدير الملاحة المشترك (مصدر الحقيقة الوحيد) بين الآيفون وCarPlay داخل نفس العملية.
@MainActor
final class SharedNavigationState: ObservableObject {
    static let shared = SharedNavigationState()

    @Published private(set) var snapshot = NavigationSnapshot()

    private weak var location: LocationManager?
    private var subscription: AnyCancellable?
    private var lastRouteRequest = Date.distantPast
    private var routingTask: Task<Void, Never>?
    private let storeKey = "activeNavigationPlan"
    private static let backgroundReason = "navigation"

    private init() {}

    func attach(location: LocationManager) {
        self.location = location
        subscription = location.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] loc in self?.update(with: loc) }
        restorePersistedPlan()
    }

    var plan: NavigationPlan? { snapshot.plan }

    // MARK: - التحكم

    func start(_ plan: NavigationPlan) {
        var s = NavigationSnapshot()
        s.status = .active
        s.plan = plan
        s.planRevision = snapshot.planRevision + 1
        if plan.mode == .direct {
            s.notice = "إرشاد بخط مباشر: يوضح الاتجاه والمسافة فقط، وليس طريقًا مضمونًا للقيادة. انتبه للتضاريس."
        }
        snapshot = s
        persist(plan, targetIndex: 0)
        location?.requestFullAccuracyIfNeeded()
        location?.beginBackgroundUpdates(reason: Self.backgroundReason)
        if let loc = location?.location { update(with: loc) }
        if plan.mode == .road { requestRoadRoute(force: true) }
    }

    /// يبدأ الملاحة إلى نقطة واحدة من الموقع الحالي.
    func navigate(to destination: Waypoint, mode: GuidanceMode = .direct, tripID: UUID? = nil) {
        let origin = location?.location.map { Waypoint(name: "موقعي", coordinate: $0.coordinate) }
        start(NavigationPlan(origin: origin, waypoints: [], destination: destination, mode: mode, tripID: tripID))
    }

    func stop() {
        routingTask?.cancel()
        let rev = snapshot.planRevision + 1
        snapshot = NavigationSnapshot()
        snapshot.planRevision = rev
        UserDefaults.standard.removeObject(forKey: storeKey)
        location?.endBackgroundUpdates(reason: Self.backgroundReason)
    }

    func skipToNextTarget() {
        guard let plan = snapshot.plan, let p = snapshot.progress else { return }
        guard p.targetIndex + 1 < plan.targets.count else { return }
        setTarget(p.targetIndex + 1)
    }

    func setMode(_ mode: GuidanceMode) {
        guard var plan = snapshot.plan, plan.mode != mode else { return }
        plan.mode = mode
        start(plan)
    }

    // MARK: - التحديث

    private func setTarget(_ index: Int) {
        guard let plan = snapshot.plan, let loc = location?.location else { return }
        snapshot.roadRoute = nil
        snapshot.roadStepIndex = 0
        let p = NavigationEngine.progress(plan: plan, targetIndex: index, current: loc.coordinate,
                                          heading: location?.currentHeadingDegrees, speed: speed(of: loc))
        snapshot.progress = p
        snapshot.instruction = NavigationEngine.instruction(for: p)
        snapshot.status = .active
        persist(plan, targetIndex: index)
        if plan.mode == .road { requestRoadRoute(force: true) }
    }

    private func update(with loc: CLLocation) {
        guard let plan = snapshot.plan, snapshot.status != .idle else { return }
        let index = snapshot.progress?.targetIndex ?? persistedTargetIndex()
        var p = NavigationEngine.progress(plan: plan, targetIndex: index, current: loc.coordinate,
                                          heading: location?.currentHeadingDegrees, speed: speed(of: loc))
        if NavigationEngine.hasArrived(p, accuracy: loc.horizontalAccuracy) {
            if p.isFinalTarget {
                snapshot.progress = p
                snapshot.status = .arrived
                snapshot.instruction = "وصلت إلى \(p.target.name)"
                return
            } else {
                setTarget(index + 1)
                return
            }
        }
        if snapshot.status == .arrived, p.distanceToTarget > NavigationEngine.arrivalRadius * 3 {
            snapshot.status = .active
        }
        // تعليمات الطريق إن وجدت
        if let route = snapshot.roadRoute {
            advanceRoadStep(route: route, current: loc.coordinate)
            if let step = snapshot.currentRoadStep {
                snapshot.instruction = step.instruction
            } else {
                snapshot.instruction = NavigationEngine.instruction(for: p)
            }
            if offRoute(route, loc.coordinate) { requestRoadRoute(force: false) }
            if let s = speed(of: loc), s > 2 {
                p.estimatedSeconds = p.remainingDistance / s
            } else {
                p.estimatedSeconds = route.expectedTravelTime
            }
        } else {
            snapshot.instruction = NavigationEngine.instruction(for: p)
        }
        snapshot.progress = p
    }

    private func speed(of loc: CLLocation) -> Double? { loc.speed >= 0 ? loc.speed : nil }

    private func advanceRoadStep(route: RoadRoute, current: CLLocationCoordinate2D) {
        let i = RoadRoutingService.currentStepIndex(steps: route.steps, from: snapshot.roadStepIndex, at: current)
        if i != snapshot.roadStepIndex { snapshot.roadStepIndex = i }
    }

    private func offRoute(_ route: RoadRoute, _ c: CLLocationCoordinate2D) -> Bool {
        // أقرب مسافة إلى أي قطعة من خط الطريق أبعد من 150 م
        let pts = route.coordinates
        guard pts.count > 1 else { return false }
        let stride = max(1, pts.count / 600)
        var i = 0
        while i < pts.count - 1 {
            let j = min(pts.count - 1, i + stride)
            if RoadRoutingService.segmentDistance(c, pts[i], pts[j]) < 150 { return false }
            i = j
        }
        return true
    }

    private func requestRoadRoute(force: Bool) {
        guard let from = location?.location?.coordinate, let target = snapshot.progress?.target ?? snapshot.plan?.targets.first else { return }
        guard force || Date().timeIntervalSince(lastRouteRequest) > 30 else { return }
        lastRouteRequest = Date()
        routingTask?.cancel()
        let revision = snapshot.planRevision
        routingTask = Task { [weak self] in
            do {
                let route = try await RoadRoutingService.route(from: from, to: target.coordinate)
                guard let self, !Task.isCancelled, self.snapshot.planRevision == revision else { return }
                self.snapshot.roadRoute = route
                self.snapshot.roadStepIndex = self.location?.location.map {
                    RoadRoutingService.currentStepIndex(steps: route.steps, from: 0, at: $0.coordinate)
                } ?? 0
                self.snapshot.notice = nil
            } catch {
                guard let self, !Task.isCancelled, self.snapshot.planRevision == revision else { return }
                #if DEBUG
                // لقطات الشاشة على المحاكي فقط: خدمة اتجاهات Apple غير متاحة هناك، فيُستخدم مسار نموذجي
                if ProcessInfo.processInfo.arguments.contains("-DemoRoad") {
                    let sample = RoadRoutingService.sampleRoute()
                    self.snapshot.roadRoute = sample
                    self.snapshot.roadStepIndex = self.location?.location.map {
                        RoadRoutingService.currentStepIndex(steps: sample.steps, from: 0, at: $0.coordinate)
                    } ?? 0
                    self.snapshot.notice = nil
                    return
                }
                #endif
                self.snapshot.roadRoute = nil
                self.snapshot.notice = error.localizedDescription
            }
        }
    }

    // MARK: - الاستمرارية بعد إعادة التشغيل

    private struct Persisted: Codable { var plan: NavigationPlan; var targetIndex: Int }

    private func persist(_ plan: NavigationPlan, targetIndex: Int) {
        if let data = try? JSONEncoder().encode(Persisted(plan: plan, targetIndex: targetIndex)) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func persistedTargetIndex() -> Int {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return 0 }
        return p.targetIndex
    }

    private func restorePersistedPlan() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        var s = NavigationSnapshot()
        s.status = .active
        s.plan = p.plan
        s.planRevision = 1
        s.notice = "تمت استعادة الملاحة النشطة من الجلسة السابقة."
        snapshot = s
        location?.beginBackgroundUpdates(reason: Self.backgroundReason)
        if p.plan.mode == .road { requestRoadRoute(force: true) }
    }
}
