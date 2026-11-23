import UIKit
import CarPlay
import MapKit
import Combine
import SwiftData

/// يبني قوالب CarPlay الرسمية (CPMapTemplate وCPListTemplate) ويزامن جلسة الملاحة مع الحالة المشتركة على الهاتف.
@MainActor
final class CarPlayTemplateManager: NSObject {
    let interfaceController: CPInterfaceController
    let mapViewController: CarPlayMapViewController
    let mapTemplate = CPMapTemplate()
    let env = AppEnvironment.shared

    private var session: CPNavigationSession?
    private var sessionRevision: Int?
    private var currentTrip: CPTrip?
    private var lastInstruction = ""
    private var lastEstimateUpdate = Date.distantPast
    private var lastWeakAlert = Date.distantPast
    private var arrivedAlertShown = false
    private var barShowsNavigation: Bool?
    /// الوجهة المعروضة للمعاينة على الخريطة قبل بدء الملاحة.
    var previewWaypoint: Waypoint?
    /// طرق السيارة المحسوبة للمعاينة الحالية، ووجهتها.
    var previewRoutes: [RoadRoute] = []
    var routesFor: Waypoint?
    /// قوائم مفتوحة تُحدَّث في مكانها.
    weak var layersTemplate: CPListTemplate?
    weak var regionsTemplate: CPListTemplate?
    weak var moreTemplate: CPListTemplate?
    weak var kindsTemplate: CPListTemplate?
    var cancellables = Set<AnyCancellable>()

    init(interfaceController: CPInterfaceController, window: CPWindow) {
        self.interfaceController = interfaceController
        self.mapViewController = CarPlayMapViewController(role: .main)
        super.init()
        window.rootViewController = mapViewController

        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false
        mapTemplate.hidesButtonsWithNavigationBar = false
        mapTemplate.guidanceBackgroundColor = UIColor(red: 0.33, green: 0.21, blue: 0.11, alpha: 1)
        mapTemplate.tripEstimateStyle = .dark
        configureButtons()

        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)
        bind()
        env.location.setAutomotive(true)
        env.location.beginBackgroundUpdates(reason: "carplay")
        #if DEBUG
        // لقطات شاشة آلية: فتح قائمة محددة بعد الاتصال
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-CarPlayScreen"), i + 1 < args.count {
            let screen = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.debugOpen(screen) }
        }
        #endif
    }

    #if DEBUG
    private func debugOpen(_ screen: String) {
        switch screen {
        case "layers": showLayers()
        case "more": showMore()
        case "destinations": showDestinations()
        case "nearby": showNearbyKinds()
        case "rawdah": showNearby(.rawdah)
        case "regions": showRegions()
        case "preview":
            if let e = SearchService.shared.nearest(.rawdah, to: env.location.location?.coordinate
                ?? CLLocationCoordinate2D(latitude: 25.38, longitude: 47.25), count: 1).first?.0 {
                preview(Waypoint(name: e.name, coordinate: .init(latitude: e.lat, longitude: e.lon)))
            }
        case "pan":
            mapViewController.beginPan()
            mapViewController.updatePan(CGPoint(x: 220, y: 0), velocity: .zero)
        default: break
        }
    }
    #endif

    func disconnect() {
        // الجلسة على CarPlay تنتهي، لكن حالة الملاحة على الهاتف تبقى كما هي
        cancellables.removeAll()
        session?.cancelTrip()
        session = nil
        sessionRevision = nil
        env.location.setAutomotive(false)
        env.location.endBackgroundUpdates(reason: "carplay")
    }

    // MARK: - الأزرار

    private var isPanning = false

    private func configureButtons() {
        updateMapButtons()
        updateBarButtons()
    }

    /// أزرار الخريطة. في وضع التحريك تُخفي السيارة بعض الأزرار، فنبقي التكبير والتصغير وزر الخروج فقط
    /// حتى لا يختفي زر التكبير بعد استخدام الأسهم.
    func updateMapButtons() {
        let zoomIn = CPMapButton { [weak self] _ in self?.mapViewController.zoom(in: true) }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")
        let zoomOut = CPMapButton { [weak self] _ in self?.mapViewController.zoom(in: false) }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")
        if isPanning {
            let done = CPMapButton { [weak self] _ in self?.mapTemplate.dismissPanningInterface(animated: true) }
            done.image = UIImage(systemName: "checkmark")
            mapTemplate.mapButtons = [zoomIn, zoomOut, done]
        } else {
            let recenter = CPMapButton { [weak self] _ in self?.mapViewController.recenter() }
            recenter.image = UIImage(systemName: "location.fill")
            let pan = CPMapButton { [weak self] _ in self?.mapTemplate.showPanningInterface(animated: true) }
            pan.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            mapTemplate.mapButtons = [recenter, zoomIn, zoomOut, pan]
        }
    }

    /// أزرار الشريط العلوي: بحد أقصى زران في كل جهة (قيد CarPlay).
    func updateBarButtons() {
        let destinations = CPBarButton(title: "الوجهات") { [weak self] _ in self?.showDestinations() }
        let search = CPBarButton(title: "بحث") { [weak self] _ in self?.showSearch() }
        let layers = CPBarButton(title: "الطبقات") { [weak self] _ in self?.showLayers() }
        let more = CPBarButton(title: "المزيد") { [weak self] _ in self?.showMore() }

        if previewWaypoint != nil {
            let cancel = CPBarButton(title: "إلغاء") { [weak self] _ in self?.cancelPreview() }
            mapTemplate.leadingNavigationBarButtons = [destinations, search]
            mapTemplate.trailingNavigationBarButtons = [cancel]
        } else if env.navigation.snapshot.isNavigating {
            let end = CPBarButton(title: "إنهاء") { [weak self] _ in self?.confirmEndNavigation() }
            mapTemplate.leadingNavigationBarButtons = [destinations, layers]
            mapTemplate.trailingNavigationBarButtons = [end, more]
        } else {
            mapTemplate.leadingNavigationBarButtons = [destinations, search]
            mapTemplate.trailingNavigationBarButtons = [layers, more]
        }
    }

    // MARK: - المزامنة

    private func bind() {
        env.navigation.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in self?.sync(snap) }
            .store(in: &cancellables)

        env.location.locationPublisher
            .throttle(for: .seconds(15), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.checkGPSQuality() }
            .store(in: &cancellables)

        // تنبيه تجاوز السرعة: تنبيه ملاحي قصير من قوالب CarPlay (لا يُرسم شيء فوق الخريطة)
        SpeedLimitStore.shared.alerts
            .receive(on: RunLoop.main)
            .sink { [weak self] limit in self?.presentSpeedAlert(limit) }
            .store(in: &cancellables)

        // تقدم تنزيل الخرائط يظهر مباشرة في القوائم المفتوحة
        env.offlineMaps.$regions
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.reloadRegions()
                self?.reloadLayers()
            }
            .store(in: &cancellables)
    }

    private func sync(_ snap: NavigationSnapshot) {
        // بدأت ملاحة (من الهاتف مثلًا) أثناء معاينة وجهة: تُلغى المعاينة
        if snap.isNavigating, previewWaypoint != nil {
            mapTemplate.hideTripPreviews()
            previewWaypoint = nil
            mapViewController.showPreview(nil)
            barShowsNavigation = nil
        }
        if barShowsNavigation != snap.isNavigating {
            barShowsNavigation = snap.isNavigating
            updateBarButtons()
        }
        guard snap.isNavigating, let plan = snap.plan else {
            if let session {
                session.finishTrip()
                self.session = nil
                sessionRevision = nil
                currentTrip = nil
                mapTemplate.hideTripPreviews()
            }
            arrivedAlertShown = false
            return
        }
        // بدء جلسة جديدة عند تغير الخطة (أو عند إعادة اتصال CarPlay أثناء ملاحة نشطة)
        if session == nil || sessionRevision != snap.planRevision {
            session?.cancelTrip()
            let trip = makeTrip(plan)
            currentTrip = trip
            session = mapTemplate.startNavigationSession(for: trip)
            sessionRevision = snap.planRevision
            lastInstruction = ""
            arrivedAlertShown = false
            CarPlayConnectionMonitor.shared.log("بدء جلسة ملاحة إلى \(plan.destination.name)")
            if plan.mode == .direct { presentDirectLineNotice() }
        }
        guard let session else { return }

        if snap.status == .arrived {
            if !arrivedAlertShown {
                arrivedAlertShown = true
                let m = makeManeuver(text: "وصلت إلى \(plan.destination.name)", detail: nil, symbol: Self.turnImage(nil), distance: 0)
                session.upcomingManeuvers = [m]
                presentAlert(title: "وصلت إلى الوجهة", subtitle: plan.destination.name, duration: 8)
            }
            return
        }

        guard let p = snap.progress else {
            if lastInstruction.isEmpty {
                session.pauseTrip(for: .loading, description: "بانتظار إشارة GPS")
                lastInstruction = "-"
            }
            return
        }

        // نص قصير يُقرأ بلمحة؛ تنبيه «الخط المباشر ليس طريقًا مضمونًا» يظهر مرة عند بدء الملاحة
        let detail: String? = snap.roadRoute == nil ? Fmt.bearing(p.bearingToTarget) : nil
        let stepDistance: Double
        let relative: Double?
        if let step = snap.currentRoadStep, let here = env.location.location?.coordinate {
            stepDistance = GeoMath.distance(here, step.endCoordinate)
            relative = env.location.currentHeadingDegrees.map { GeoMath.angleDelta(from: $0, to: GeoMath.bearing(from: here, to: step.endCoordinate)) }
        } else {
            stepDistance = p.distanceToTarget
            relative = p.relativeBearing
        }

        let key = "\(snap.instruction)|\(p.targetIndex)|\(snap.roadStepIndex)|\(Int((relative ?? 0) / 20))"
        if key != lastInstruction {
            lastInstruction = key
            if let route = snap.roadRoute, let step = snap.currentRoadStep {
                // توجيه منعطف بمنعطف: المناورة الحالية والتي تليها
                var list = [makeManeuver(text: step.instruction, detail: nil, symbol: Self.turnImage(step.turnAngle), distance: stepDistance)]
                let ni = snap.roadStepIndex + 1
                if ni < route.steps.count {
                    let n = route.steps[ni]
                    list.append(makeManeuver(text: n.instruction, detail: nil, symbol: Self.turnImage(n.turnAngle), distance: n.distance))
                }
                session.upcomingManeuvers = list
            } else {
                session.upcomingManeuvers = [makeManeuver(text: snap.instruction, detail: detail,
                                                          symbol: Self.arrowImage(relative: relative ?? 0), distance: stepDistance)]
            }
        }
        if Date().timeIntervalSince(lastEstimateUpdate) > 1, let maneuver = session.upcomingManeuvers.first {
            lastEstimateUpdate = Date()
            let step = CPTravelEstimates(distanceRemaining: Self.measure(stepDistance),
                                         timeRemaining: 0)
            session.updateEstimates(step, for: maneuver)
            if let trip = currentTrip {
                let total = CPTravelEstimates(distanceRemaining: Self.measure(p.remainingDistance),
                                              timeRemaining: p.estimatedSeconds ?? 0)
                mapTemplate.update(total, for: trip, with: .default)
            }
        }
    }

    func makeTrip(_ plan: NavigationPlan) -> CPTrip {
        let originCoord = env.location.location?.coordinate ?? plan.origin?.coordinate ?? plan.destination.coordinate
        let origin = MKMapItem(placemark: MKPlacemark(coordinate: originCoord))
        origin.name = "موقعي"
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: plan.destination.coordinate))
        dest.name = plan.destination.name
        let distance = Fmt.distance(GeoMath.distance(originCoord, plan.destination.coordinate))
        let summary = plan.mode == .direct ? "خط مباشر \(distance)" : "عبر الطرق المعروفة"
        let info = plan.mode == .direct ? ["إرشاد جغرافي وليس طريقًا مضمونًا"] : ["تعليمات الطرق عند توفرها"]
        let choice = CPRouteChoice(summaryVariants: [summary], additionalInformationVariants: info, selectionSummaryVariants: [summary])
        return CPTrip(origin: origin, destination: dest, routeChoices: [choice])
    }

    private func makeManeuver(text: String, detail: String?, symbol: UIImage, distance: Double) -> CPManeuver {
        let m = CPManeuver()
        var variants = [text]
        if let detail { variants = [text, text + " · " + detail] }
        m.instructionVariants = variants
        m.symbolImage = symbol
        m.initialTravelEstimates = CPTravelEstimates(distanceRemaining: Self.measure(distance),
                                                     timeRemaining: 0)
        return m
    }

    /// المسافة بوحدة مناسبة للقراءة السريعة: كم بعد الكيلومتر الأول، ومتر مقرّب قبله.
    static func measure(_ m: Double) -> Measurement<UnitLength> {
        if m >= 1000 {
            let km = m / 1000
            return Measurement(value: km < 10 ? (km * 10).rounded() / 10 : km.rounded(), unit: .kilometers)
        }
        return Measurement(value: max(0, (m / 10).rounded() * 10), unit: .meters)
    }

    /// رمز المناورة على الطريق حسب زاوية الانعطاف (موجبة لليمين)، وعلم الوصول عند nil.
    static func turnImage(_ angle: Double?) -> UIImage {
        let name: String
        switch angle {
        case nil: name = "flag.checkered"
        case let a? where abs(a) < 20: name = "arrow.up"
        case let a? where abs(a) < 60: name = a > 0 ? "arrow.up.right" : "arrow.up.left"
        case let a? where abs(a) < 150: name = a > 0 ? "arrow.turn.up.right" : "arrow.turn.up.left"
        case let a?: name = a > 0 ? "arrow.uturn.right" : "arrow.uturn.left"
        }
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)
        let img = UIImage(systemName: name, withConfiguration: config) ?? UIImage(systemName: "arrow.up", withConfiguration: config)!
        return img.withTintColor(.white, renderingMode: .alwaysOriginal)
    }

    /// سهم يدور حسب الاتجاه النسبي للهدف (للإرشاد بالخط المباشر).
    static func arrowImage(relative: Double) -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let config = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)
        let symbol = UIImage(systemName: "arrow.up", withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            guard let symbol else { return }
            let cg = ctx.cgContext
            cg.translateBy(x: size.width / 2, y: size.height / 2)
            cg.rotate(by: CGFloat(relative * .pi / 180))
            let s = symbol.size
            symbol.draw(in: CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height))
        }
    }

    // MARK: - التنبيهات

    private func presentDirectLineNotice() {
        presentAlert(title: "إرشاد بخط مباشر",
                     subtitle: "يوضح الاتجاه والمسافة فقط وليس طريقًا مضمونًا. انتبه للتضاريس.",
                     duration: 8)
    }

    private func presentSpeedAlert(_ limit: Int) {
        // يستبدل أي تنبيه سرعة سابق ولا يحتاج لمسة: يختفي تلقائيًا
        if mapTemplate.currentNavigationAlert != nil { mapTemplate.dismissNavigationAlert(animated: false) { _ in } }
        let img = UIImage(systemName: "gauge.with.dots.needle.67percent",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .bold))?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        let alert = CPNavigationAlert(titleVariants: ["تجاوزت حد السرعة \(limit)", "الحد \(limit)"],
                                      subtitleVariants: ["الحد النظامي لهذا الطريق \(limit) كم/س"],
                                      image: img, primaryAction: CPAlertAction(title: "حسنًا", style: .cancel) { _ in },
                                      secondaryAction: nil, duration: 5)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    func presentAlert(title: String, subtitle: String, duration: TimeInterval) {
        guard mapTemplate.currentNavigationAlert == nil else { return }
        let ok = CPAlertAction(title: "حسنًا", style: .default) { _ in }
        let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: [subtitle], image: nil,
                                      primaryAction: ok, secondaryAction: nil, duration: duration)
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func checkGPSQuality() {
        guard env.navigation.snapshot.isNavigating || env.recorder.isActive else { return }
        guard env.location.gpsQuality == .weak, Date().timeIntervalSince(lastWeakAlert) > 120 else { return }
        lastWeakAlert = Date()
        presentAlert(title: "دقة GPS ضعيفة", subtitle: "قد تكون المسافة والاتجاه غير دقيقة حاليًا.", duration: 6)
    }

    func confirmEndNavigation() {
        let end = CPAlertAction(title: "إنهاء الملاحة", style: .destructive) { [weak self] _ in
            self?.env.navigation.stop()
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        let cancel = CPAlertAction(title: "متابعة", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: ["إنهاء الملاحة؟"], actions: [end, cancel]),
                                            animated: true, completion: nil)
    }

}

// MARK: - CPMapTemplateDelegate

extension CarPlayTemplateManager: CPMapTemplateDelegate {
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated { mapViewController.pan(direction) }
    }

    // السحب باللمس على شاشات السيارات التي تدعمه
    nonisolated func mapTemplateDidBeginPanGesture(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated { mapViewController.beginPan() }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdatePanGestureWithTranslation translation: CGPoint, velocity: CGPoint) {
        MainActor.assumeIsolated { mapViewController.updatePan(translation, velocity: velocity) }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        MainActor.assumeIsolated { mapViewController.endPan(velocity: velocity) }
    }

    // الضغط المستمر على أسهم التحريك
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panBeganWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated { mapViewController.beginContinuousPan(direction) }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panEndedWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated { mapViewController.endContinuousPan() }
    }

    // التكبير والتصغير بإصبعين (iOS 26 وما بعده، في السيارات التي تدعم اللمس المتعدد).
    // التدوير بإصبعين غير مفعّل عمدًا: يربك السائق، والخريطة تدور مع اتجاه السير تلقائيًا.
    @available(iOS 26.0, *)
    nonisolated func mapTemplateDidBeginZoomGesture(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated { mapViewController.beginZoom() }
    }

    @available(iOS 26.0, *)
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, didUpdateZoomGestureWithCenter center: CGPoint, scale: CGFloat, velocity: CGFloat) {
        MainActor.assumeIsolated { mapViewController.updateZoom(scale: scale) }
    }

    @available(iOS 26.0, *)
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, didEndZoomGestureWithVelocity velocity: CGFloat) {
        MainActor.assumeIsolated { mapViewController.endZoom() }
    }

    nonisolated func mapTemplateDidShowPanningInterface(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated { isPanning = true; updateMapButtons() }
    }

    nonisolated func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated { isPanning = false; updateMapButtons() }
    }

    nonisolated func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated {
            session = nil
            env.navigation.stop()
        }
    }

    /// عند اختيار طريق في المعاينة: نرسمه على خريطة السيارة.
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            let info = routeChoice.userInfo as? String ?? ""
            if info.hasPrefix("road:"), let i = Int(info.dropFirst(5)), previewRoutes.indices.contains(i) {
                mapViewController.showPreviewRoute(previewRoutes[i].coordinates)
            } else {
                mapViewController.showPreviewRoute(nil)
            }
        }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            mapTemplate.hideTripPreviews()
            let c = trip.destination.placemark.coordinate
            let w = previewWaypoint ?? Waypoint(name: trip.destination.name ?? "الوجهة", coordinate: c)
            let info = routeChoice.userInfo as? String ?? ""
            previewWaypoint = nil
            mapViewController.showPreview(nil)
            if info.hasPrefix("road:"), let i = Int(info.dropFirst(5)), previewRoutes.indices.contains(i) {
                let origin = env.location.location.map { Waypoint(name: "موقعي", coordinate: $0.coordinate) }
                env.navigation.start(NavigationPlan(origin: origin, waypoints: [], destination: w, mode: .road),
                                     presetRoute: previewRoutes[i])
            } else {
                env.navigation.navigate(to: w, mode: GuidanceMode(rawValue: info) ?? .direct)
            }
            previewRoutes = []
            updateBarButtons()
        }
    }
}
