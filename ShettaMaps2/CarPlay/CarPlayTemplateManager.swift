import UIKit
import CarPlay
import MapKit
import Combine
import SwiftData

/// يبني قوالب CarPlay الرسمية (CPMapTemplate وCPListTemplate) ويزامن جلسة الملاحة مع الحالة المشتركة على الهاتف.
@MainActor
final class CarPlayTemplateManager: NSObject {
    private let interfaceController: CPInterfaceController
    private let mapViewController: CarPlayMapViewController
    private let mapTemplate = CPMapTemplate()
    private let env = AppEnvironment.shared

    private var session: CPNavigationSession?
    private var sessionRevision: Int?
    private var currentTrip: CPTrip?
    private var lastInstruction = ""
    private var lastEstimateUpdate = Date.distantPast
    private var lastWeakAlert = Date.distantPast
    private var arrivedAlertShown = false
    private var barShowsNavigation: Bool?
    private var cancellables = Set<AnyCancellable>()

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
    }

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

    private func configureButtons() {
        let zoomIn = CPMapButton { [weak self] _ in self?.mapViewController.zoom(in: true) }
        zoomIn.image = UIImage(systemName: "plus.magnifyingglass")
        let zoomOut = CPMapButton { [weak self] _ in self?.mapViewController.zoom(in: false) }
        zoomOut.image = UIImage(systemName: "minus.magnifyingglass")
        let recenter = CPMapButton { [weak self] _ in self?.mapViewController.recenter() }
        recenter.image = UIImage(systemName: "location.fill")
        let pan = CPMapButton { [weak self] _ in self?.mapTemplate.showPanningInterface(animated: true) }
        pan.image = UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        mapTemplate.mapButtons = [recenter, zoomIn, zoomOut, pan]
        updateBarButtons()
    }

    private func updateBarButtons() {
        let destinations = CPBarButton(title: "الوجهات") { [weak self] _ in self?.showDestinations() }
        let options = CPBarButton(title: "خيارات") { [weak self] _ in self?.showOptions() }
        mapTemplate.leadingNavigationBarButtons = [destinations]

        if env.navigation.snapshot.isNavigating {
            let end = CPBarButton(title: "إنهاء") { [weak self] _ in self?.confirmEndNavigation() }
            let overview = CPBarButton(title: "المسار") { [weak self] _ in self?.mapViewController.showWholeRoute() }
            mapTemplate.trailingNavigationBarButtons = [end, overview]
        } else {
            mapTemplate.trailingNavigationBarButtons = [options]
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
    }

    private func sync(_ snap: NavigationSnapshot) {
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

        let detail: String? = snap.roadRoute == nil ? "خط مباشر — \(Fmt.bearing(p.bearingToTarget)) — ليس طريقًا مضمونًا" : nil
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
            let step = CPTravelEstimates(distanceRemaining: Measurement(value: stepDistance, unit: UnitLength.meters),
                                         timeRemaining: 0)
            session.updateEstimates(step, for: maneuver)
            if let trip = currentTrip {
                let total = CPTravelEstimates(distanceRemaining: Measurement(value: p.remainingDistance, unit: UnitLength.meters),
                                              timeRemaining: p.estimatedSeconds ?? 0)
                mapTemplate.update(total, for: trip, with: .default)
            }
        }
    }

    private func makeTrip(_ plan: NavigationPlan) -> CPTrip {
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
        if let detail { variants = [text + " — " + detail, text] }
        m.instructionVariants = variants
        m.symbolImage = symbol
        m.initialTravelEstimates = CPTravelEstimates(distanceRemaining: Measurement(value: distance, unit: UnitLength.meters),
                                                     timeRemaining: 0)
        return m
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

    private func presentAlert(title: String, subtitle: String, duration: TimeInterval) {
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

    private func confirmEndNavigation() {
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

    // MARK: - القوائم

    private func showDestinations() {
        let ctx = env.container.mainContext
        let places = (try? ctx.fetch(FetchDescriptor<SavedPlace>())) ?? []
        let here = env.location.location?.coordinate
        let limit = max(4, CPListTemplate.maximumItemCount - 6)

        var sections: [CPListSection] = []

        // الرحلة النشطة
        var tripItems: [CPListItem] = []
        if let trip = env.trips.activeTrip {
            if let start = trip.startCoordinate {
                let item = CPListItem(text: "العودة إلى نقطة البداية",
                                      detailText: here.map { Fmt.distance(GeoMath.distance($0, start)) },
                                      image: UIImage(systemName: "arrow.uturn.backward.circle"))
                item.handler = { [weak self] _, done in
                    self?.env.trips.returnToStart(of: trip)
                    self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
                    done()
                }
                tripItems.append(item)
            }
            if !trip.stops.isEmpty || trip.destination != nil {
                let item = CPListItem(text: "الملاحة عبر نقاط التوقف", detailText: "\(trip.stops.count) توقف",
                                      image: UIImage(systemName: "point.3.connected.trianglepath.dotted"))
                item.handler = { [weak self] _, done in
                    self?.env.trips.navigateTrip(trip)
                    self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
                    done()
                }
                tripItems.append(item)
            }
        }
        if !tripItems.isEmpty { sections.append(CPListSection(items: tripItems, header: "الرحلة النشطة", sectionIndexTitle: nil)) }

        let favorites = places.filter(\.isFavorite)
        if !favorites.isEmpty {
            sections.append(CPListSection(items: Array(sortByDistance(favorites, here).prefix(6)).map { listItem(for: $0, here: here) },
                                          header: "المفضلة", sectionIndexTitle: nil))
        }
        let others = places.filter { !$0.isFavorite }
        if !others.isEmpty {
            sections.append(CPListSection(items: Array(sortByDistance(others, here).prefix(limit)).map { listItem(for: $0, here: here) },
                                          header: "الأقرب من المواقع المحفوظة", sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            let empty = CPListItem(text: "لا توجد مواقع محفوظة", detailText: "احفظ المواقع من الهاتف لتظهر هنا")
            sections.append(CPListSection(items: [empty]))
        }

        let list = CPListTemplate(title: "الوجهات", sections: sections)
        list.emptyViewTitleVariants = ["لا توجد وجهات"]
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func sortByDistance(_ list: [SavedPlace], _ here: CLLocationCoordinate2D?) -> [SavedPlace] {
        guard let here else { return list.sorted { $0.name < $1.name } }
        return list.sorted { GeoMath.distance(here, $0.coordinate) < GeoMath.distance(here, $1.coordinate) }
    }

    private func listItem(for place: SavedPlace, here: CLLocationCoordinate2D?) -> CPListItem {
        let detail = here.map { "\(Fmt.distance(GeoMath.distance($0, place.coordinate))) · \(GeoMath.cardinalName(GeoMath.bearing(from: $0, to: place.coordinate)))" }
        let item = CPListItem(text: place.name, detailText: detail ?? place.category?.name,
                              image: UIImage(systemName: place.category?.iconName ?? "mappin"))
        let waypoint = place.asWaypoint
        item.handler = { [weak self] _, done in
            self?.env.navigation.navigate(to: waypoint)
            self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
            done()
        }
        return item
    }

    private func showOptions() {
        var items: [CPListItem] = []

        if let loc = env.location.location {
            let info = CPListItem(text: "موقعي الحالي",
                                  detailText: "\(CoordinateUtilities.shareString(loc.coordinate)) · \(Fmt.accuracy(loc.horizontalAccuracy))",
                                  image: UIImage(systemName: "location"))
            items.append(info)

            let save = CPListItem(text: "حفظ الموقع الحالي", detailText: "يُحفظ باسم تلقائي ويمكن تعديله من الهاتف",
                                  image: UIImage(systemName: "mappin.and.ellipse"))
            save.handler = { [weak self] _, done in
                self?.quickSave(loc)
                done()
            }
            items.append(save)
        }

        let rec = env.recorder
        let recordItem = CPListItem(text: rec.isActive ? "إنهاء تسجيل المسار" : "بدء تسجيل المسار",
                                    detailText: rec.isActive ? "\(Fmt.distance(rec.distance)) · \(Fmt.duration(rec.elapsed))" : nil,
                                    image: UIImage(systemName: rec.isActive ? "stop.circle" : "record.circle"))
        recordItem.handler = { [weak self] _, done in
            guard let self else { done(); return }
            if self.env.recorder.isActive { self.env.recorder.finish() } else { self.env.recorder.start(trip: self.env.trips.activeTrip) }
            self.interfaceController.popToRootTemplate(animated: true, completion: nil)
            done()
        }
        items.append(recordItem)

        for engine in [CarPlayMapEngine.mapKitStandard, .mapKitSatellite, .offline] {
            let selected = mapViewController.engine == engine
            let item = CPListItem(text: engine.title, detailText: engineDetail(engine),
                                  image: UIImage(systemName: selected ? "checkmark.circle.fill" : "circle"))
            item.handler = { [weak self] _, done in
                self?.mapViewController.setEngine(engine)
                self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
                done()
            }
            items.append(item)
        }

        let list = CPListTemplate(title: "خيارات", sections: [
            CPListSection(items: Array(items.prefix(3)), header: "الموقع والتسجيل", sectionIndexTitle: nil),
            CPListSection(items: Array(items.dropFirst(3)), header: "نوع الخريطة", sectionIndexTitle: nil)
        ])
        interfaceController.pushTemplate(list, animated: true, completion: nil)
    }

    private func engineDetail(_ e: CarPlayMapEngine) -> String {
        switch e {
        case .mapKitStandard, .mapKitSatellite: return env.network.isOnline ? "يتطلب الإنترنت" : "غير متاح حاليًا: لا يوجد اتصال"
        case .offline:
            if let c = env.location.location?.coordinate {
                return env.offlineMaps.hasOfflineCoverage(at: c) ? "خريطة محملة لهذه المنطقة" : "لا توجد خريطة محملة لهذه المنطقة"
            }
            return "الخرائط المحملة مسبقًا"
        }
    }

    private func quickSave(_ loc: CLLocation) {
        let ctx = env.container.mainContext
        let place = SavedPlace(name: "موقع من السيارة \(Fmt.dateTime.string(from: Date()))", coordinate: loc.coordinate,
                               altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil, horizontalAccuracy: loc.horizontalAccuracy)
        ctx.insert(place)
        try? ctx.save()
        mapViewController.refreshOverlays(force: true)
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        presentAlert(title: "تم حفظ الموقع", subtitle: CoordinateUtilities.shareString(loc.coordinate), duration: 4)
    }
}

// MARK: - CPMapTemplateDelegate

extension CarPlayTemplateManager: CPMapTemplateDelegate {
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated { mapViewController.pan(direction) }
    }

    nonisolated func mapTemplateDidDismissPanningInterface(_ mapTemplate: CPMapTemplate) {}

    nonisolated func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated {
            session = nil
            env.navigation.stop()
        }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            mapTemplate.hideTripPreviews()
            let c = trip.destination.placemark.coordinate
            env.navigation.navigate(to: Waypoint(name: trip.destination.name ?? "الوجهة", coordinate: c))
        }
    }
}
