import UIKit
import MapKit
import MapLibre
import Combine
import SwiftData
import CarPlay
import SwiftUI

/// محرك الخريطة على شاشة السيارة.
enum CarPlayMapEngine: String, CaseIterable {
    case mapKitStandard, mapKitTerrain, mapKitSatellite, offline
    var title: String {
        switch self {
        case .mapKitStandard: return "خريطة عادية"
        case .mapKitTerrain: return "تضاريس"
        case .mapKitSatellite: return "أقمار صناعية"
        case .offline: return "دون إنترنت"
        }
    }
    var icon: String {
        switch self {
        case .mapKitStandard: return "map"
        case .mapKitTerrain: return "mountain.2"
        case .mapKitSatellite: return "globe.asia.australia"
        case .offline: return "arrow.down.circle"
        }
    }
    var needsInternet: Bool { self != .offline }
}

/// إعدادات العرض المشتركة بين الهاتف والسيارة (نفس مفاتيح شاشة الطبقات في الهاتف).
enum CarPlaySettings {
    static let northUpKey = "carPlayNorthUp"

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
    static func toggle(_ key: String, _ fallback: Bool) {
        UserDefaults.standard.set(!bool(key, fallback), forKey: key)
    }

    static var showLandmarks: Bool { bool(SettingsKeys.showLandmarks, true) }
    static var showCommunity: Bool { bool(SettingsKeys.showCommunity, true) }
    static var showDirtRoads: Bool { bool(SettingsKeys.showDirtRoads, true) }
    static var showDetectedRoads: Bool { bool(SettingsKeys.showDetectedRoads, true) }
    static var showMyTracks: Bool { bool(SettingsKeys.showMyTracks, false) }
    static var showCoverage: Bool { bool(SettingsKeys.showCoverage, false) }
    static var coverageOnlyMine: Bool { bool(SettingsKeys.coverageOnlyMine, true) }
    static var showRainMap: Bool { bool(SettingsKeys.showRainMap, false) }
    static var northUp: Bool { bool(northUpKey, false) }
    static var landmarkKinds: Set<PlaceKind> {
        PlaceKind.expand(PlaceKind.decodeSet(UserDefaults.standard.string(forKey: SettingsKeys.landmarkKinds) ?? ""))
    }
    static var waterSubs: Set<WaterSub> {
        landmarkKinds.contains(.water) ? WaterSub.decode(UserDefaults.standard.string(forKey: "waterSubs") ?? "") : []
    }

    /// بصمة لكل ما يؤثر على الرسم، لاكتشاف تغيّر الإعدادات من الهاتف.
    static var signature: String {
        [showLandmarks, showCommunity, showDirtRoads, showDetectedRoads, showMyTracks, showCoverage, coverageOnlyMine,
         showRainMap, northUp, RainNowService.observedMode].map { $0 ? "1" : "0" }.joined()
            + (UserDefaults.standard.string(forKey: SettingsKeys.landmarkKinds) ?? "")
            + (UserDefaults.standard.string(forKey: SettingsKeys.coverageCarrier) ?? "")
            + (UserDefaults.standard.string(forKey: "waterSubs") ?? "")
    }
}

/// متحكم العرض الأساسي (Base View) لنافذة CarPlay: يرسم الخريطة فقط وفق إرشادات Apple،
/// وكل الأزرار والمعلومات تُعرض عبر قوالب CarPlay الرسمية.
@MainActor
final class CarPlayMapViewController: UIViewController {
    enum Role { case main, dashboard, cluster }

    private let role: Role
    private var mapKitView: MKMapView?
    private var libreView: MLNMapView?
    private var cancellables = Set<AnyCancellable>()
    private var lastOverlays: MapOverlaySet?
    private(set) var isFollowing = true
    private var places: [SavedPlace] = []
    private var lastPlacesFetch = Date.distantPast

    // طبقات البيانات للمنطقة الظاهرة
    private var dataPins: [MapOverlaySet.Pin] = []
    private var dataLines: [MapOverlaySet.Line] = []
    private var dirt: [DirtRoad] = []
    private var coverageCells: [CoverageCell] = []
    private var rainCells: [RainCell] = []
    private var rainShapes: [RainShape] = []
    private var lastDataRegion: MKCoordinateRegion?
    private var dataWork: DispatchWorkItem?
    private var settingsSignature = CarPlaySettings.signature
    private var lastNorthUp = CarPlaySettings.northUp
    private var tracks: [RecordedTrack] = []
    private var lastTracksFetch = Date.distantPast

    private var lastPan = CGPoint.zero
    /// الوجهة المعروضة للمعاينة قبل بدء الملاحة.
    private(set) var previewCoordinate: CLLocationCoordinate2D?

    private let env = AppEnvironment.shared
    private let mapKitDelegate = CarPlayMapKitDelegate()
    private let libreDelegate = CarPlayMapLibreDelegate()

    private(set) var engine: CarPlayMapEngine {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "carPlayEngine") }
    }

    init(role: Role) {
        self.role = role
        let saved = CarPlayMapEngine(rawValue: UserDefaults.standard.string(forKey: "carPlayEngine") ?? "") ?? .mapKitStandard
        self.engine = saved
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.beigeUI
        mapKitDelegate.onRegionChange = { [weak self] in self?.regionChanged() }
        libreDelegate.onRegionChange = { [weak self] in self?.regionChanged() }
        libreDelegate.onStyleLoaded = { [weak self] in
            guard let self else { return }
            // السيارة في الوضع الليلي: خريطة داكنة لا تُبهر السائق
            if self.traitCollection.userInterfaceStyle == .dark, let m = self.libreView { MapLibreNightStyle.apply(to: m) }
            self.applyDataLayers()
        }
        // بدون إنترنت ومع توفر خرائط محلية: نبدأ بمحرك دون إنترنت تلقائيًا
        if !env.network.isOnline, engine != .offline,
           let c = env.location.location?.coordinate, env.offlineMaps.hasOfflineCoverage(at: c) {
            engine = .offline
        }
        buildMap()
        bind()
        if role == .cluster { setupClusterSign() }
        // احتياط إن لم تُستدعَ viewDidAppear في نافذة السيارة
        if role == .main {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.setupSpeedOverlay() }
        }
    }

    // MARK: - السرعة على الخريطة

    private var speedHost: UIHostingController<CarPlaySpeedOverlay>?

    /// يُنشأ بعد ظهور الخريطة لا أثناء تعيينها جذرًا لنافذة السيارة: إضافة واجهات SwiftUI بقيود Auto Layout
    /// أثناء ذلك الانتقال كانت تُسقط التطبيق عند الاتصال بالسيارة. نستخدم إطارات ثابتة بلا قيود.
    private func setupSpeedOverlay() {
        guard speedHost == nil else { return }
        let host = UIHostingController(rootView: CarPlaySpeedOverlay())
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = true
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        speedHost = host

        let coords = UIHostingController(rootView: CarPlayCoordinateBar())
        coords.sizingOptions = []
        coords.view.backgroundColor = .clear
        coords.view.isUserInteractionEnabled = false
        coords.view.translatesAutoresizingMaskIntoConstraints = true
        addChild(coords)
        view.addSubview(coords.view)
        coords.didMove(toParent: self)
        coordsHost = coords
        layoutOverlays()
    }

    private func layoutOverlays() {
        let b = view.bounds, inset = view.safeAreaInsets
        guard b.width > 0, b.height > 0 else { return }
        // السرعة أقصى يمين أعلى الخريطة، والإحداثيات أسفلها في المنتصف
        speedHost?.view.frame = CGRect(x: b.width - inset.right - 4 - 96, y: inset.top, width: 96, height: 96)
        let w = min(220, b.width - inset.left - inset.right - 8)
        coordsHost?.view.frame = CGRect(x: inset.left + (b.width - inset.left - inset.right - w) / 2,
                                        y: b.height - inset.bottom - 2 - 30, width: w, height: 30)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutOverlays()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard role == .main, speedHost == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.setupSpeedOverlay() }
    }

    private var coordsHost: UIHostingController<CarPlayCoordinateBar>?

    // MARK: - شاشة العدادات: لوحة حد السرعة

    /// تسمح السيارة (أو تفضيل المستخدم) برسم حد السرعة والبوصلة في شاشة العدادات.
    var clusterSpeedLimitAllowed = false { didSet { updateClusterSign() } }
    var clusterCompassAllowed = true { didSet { mapKitView?.showsCompass = clusterCompassAllowed; libreView?.compassView.isHidden = !clusterCompassAllowed } }
    private let clusterSign = UILabel()

    private func setupClusterSign() {
        clusterSign.translatesAutoresizingMaskIntoConstraints = false
        clusterSign.textAlignment = .center
        clusterSign.font = .systemFont(ofSize: 20, weight: .heavy)
        clusterSign.textColor = .black
        clusterSign.backgroundColor = .white
        clusterSign.layer.cornerRadius = 24
        clusterSign.layer.borderColor = UIColor.systemRed.cgColor
        clusterSign.layer.borderWidth = 5
        clusterSign.clipsToBounds = true
        clusterSign.isHidden = true
        view.addSubview(clusterSign)
        NSLayoutConstraint.activate([
            clusterSign.widthAnchor.constraint(equalToConstant: 48),
            clusterSign.heightAnchor.constraint(equalToConstant: 48),
            clusterSign.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            clusterSign.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        SpeedLimitStore.shared.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateClusterSign() }
            .store(in: &cancellables)
    }

    private func updateClusterSign() {
        guard role == .cluster else { return }
        // حد موثوق فقط، ولا يظهر دون إذن السيارة
        if clusterSpeedLimitAllowed, let limit = SpeedLimitStore.shared.currentLimit {
            clusterSign.text = "\(limit)"
            clusterSign.isHidden = false
            view.bringSubviewToFront(clusterSign)
        } else {
            clusterSign.isHidden = true
        }
    }

    /// تبدّل نهار/ليل السيارة: يُعاد تحميل خريطة MapLibre بالألوان المناسبة (MapKit يتبدّل تلقائيًا).
    /// لا نحذف خريطة MapLibre هنا: يصل هذا الاستدعاء أثناء نقل الخريطة لنافذة السيارة، وحذفها في تلك اللحظة
    /// كان يُسقط التطبيق عند الاتصال بالسيارة ليلًا. نعيد تحميل النمط فقط بعد انتهاء الانتقال.
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle, libreView != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let m = self.libreView else { return }
            m.styleURL = self.env.offlineMaps.activeStyleURL  // onStyleLoaded يطبّق ألوان الليل عند الحاجة
        }
    }

    // MARK: - المحرك

    /// تغيير نوع الخريطة. force يعيد البناء حتى لو لم يتغير المحرك (مثل تغيير ملف الخرائط المحلي).
    func setEngine(_ e: CarPlayMapEngine, force: Bool = false) {
        guard e != engine || force else { return }
        engine = e
        buildMap()
    }

    private func buildMap() {
        mapKitView?.removeFromSuperview(); mapKitView = nil
        libreView?.removeFromSuperview(); libreView = nil
        lastOverlays = nil
        lastDataRegion = nil

        switch engine {
        case .mapKitStandard, .mapKitTerrain, .mapKitSatellite:
            let m = MKMapView(frame: view.bounds)
            m.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            m.delegate = mapKitDelegate
            switch engine {
            case .mapKitSatellite: m.preferredConfiguration = MKHybridMapConfiguration()
            case .mapKitTerrain: m.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            default: m.preferredConfiguration = MKStandardMapConfiguration()
            }
            m.showsUserLocation = true
            m.showsCompass = role != .cluster
            m.showsScale = role == .main
            m.pointOfInterestFilter = role == .cluster ? .excludingAll : .includingAll
            m.isPitchEnabled = false
            view.insertSubview(m, at: 0) // تحت فقاعة السرعة
            mapKitView = m
            if let c = previewCoordinate ?? env.location.location?.coordinate {
                m.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: zoomMeters, longitudinalMeters: zoomMeters), animated: false)
            }
        case .offline:
            let m = MLNMapView(frame: view.bounds, styleURL: env.offlineMaps.activeStyleURL)
            m.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            m.delegate = libreDelegate
            m.showsUserLocation = true
            m.compassView.isHidden = role == .cluster
            m.logoView.isHidden = role == .cluster
            m.attributionButton.isHidden = role == .cluster
            m.allowsTilting = false
            view.insertSubview(m, at: 0)
            libreView = m
            if let c = env.location.location?.coordinate {
                m.setCenter(c, zoomLevel: role == .cluster ? 14 : 13, animated: false)
            }
            if isFollowing { m.userTrackingMode = CarPlaySettings.northUp ? .follow : .followWithCourse }
        }
        refreshOverlays(force: true)
        scheduleDataRefresh(force: true)
        if role == .cluster { view.bringSubviewToFront(clusterSign); updateClusterSign() }
    }

    private var zoomMeters: CLLocationDistance { role == .cluster ? 1200 : 3000 }

    // MARK: - الربط بالحالة المشتركة

    private func bind() {
        env.location.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] loc in self?.locationChanged(loc) }
            .store(in: &cancellables)

        env.navigation.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshOverlays(force: false) }
            .store(in: &cancellables)

        env.recorder.$liveSegments
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.refreshOverlays(force: false) }
            .store(in: &cancellables)

        // قياس تغطية جديد (مثل مربع صار أخضر) أو اكتمال فهرس الأماكن: نعيد رسم الطبقات
        CoverageService.shared.$revision.map { _ in () }
            .merge(with: SearchService.shared.$indexRevision.map { _ in () })
            .merge(with: RainNowService.shared.$cells.map { _ in () })
            .merge(with: RainForecastService.shared.$frames.map { _ in () })
            .dropFirst(4)
            .throttle(for: .seconds(3), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self, self.role == .main, !self.gestureActive else { return }
                // من البيانات المحلية فقط، دون جلب جديد من الخادم
                self.collectData()
                self.applyAll()
            }
            .store(in: &cancellables)

        env.network.$isOnline
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] online in
                guard let self else { return }
                // عند انقطاع الإنترنت ننتقل للخرائط المحملة إن وجدت تغطية
                if !online, self.engine != .offline, let c = self.env.location.location?.coordinate,
                   self.env.offlineMaps.hasOfflineCoverage(at: c) {
                    self.setEngine(.offline)
                    CarPlayConnectionMonitor.shared.log("انقطع الإنترنت: التحويل إلى الخرائط المحملة")
                }
            }
            .store(in: &cancellables)

        // أي تغيير في إعدادات الطبقات من الهاتف أو من السيارة يظهر فورًا
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.settingsMaybeChanged() }
            .store(in: &cancellables)

        // اكتمال تنزيل ردميات أو تحديث بيانات المجتمع يعيد الرسم
        DirtRoadsStore.shared.$installed
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.collectData(); self?.applyAll() }
            .store(in: &cancellables)
    }

    private func settingsMaybeChanged() {
        let sig = CarPlaySettings.signature
        guard sig != settingsSignature else { return }
        settingsSignature = sig
        if lastNorthUp != CarPlaySettings.northUp {
            lastNorthUp = CarPlaySettings.northUp
            if isFollowing { recenter() }
        }
        scheduleDataRefresh(force: true)
    }

    private func locationChanged(_ loc: CLLocation) {
        guard isFollowing else { return }
        // شاشة العدادات: الاتجاه للأعلى دائمًا (إرشادات Apple)
        let northUp = role == .cluster ? false : CarPlaySettings.northUp
        if let m = mapKitView {
            let heading: CLLocationDirection = northUp ? 0 : ((loc.course >= 0 && loc.speed > 3) ? loc.course : m.camera.heading)
            let camera = MKMapCamera(lookingAtCenter: loc.coordinate,
                                     fromDistance: m.camera.centerCoordinateDistance > 0 ? m.camera.centerCoordinateDistance : zoomMeters * 2,
                                     pitch: 0, heading: heading)
            m.setCamera(camera, animated: true)
        } else if let m = libreView {
            let mode: MLNUserTrackingMode = northUp ? .follow : .followWithCourse
            if m.userTrackingMode != mode { m.setUserTrackingMode(mode, animated: true, completionHandler: nil) }
        }
    }

    // MARK: - العناصر فوق الخريطة

    func refreshOverlays(force: Bool) {
        if gestureActive && !force { return }
        if Date().timeIntervalSince(lastPlacesFetch) > 20 || force {
            let descriptor = FetchDescriptor<SavedPlace>(sortBy: [SortDescriptor(\.name)])
            places = (try? env.container.mainContext.fetch(descriptor)) ?? []
            lastPlacesFetch = Date()
        }
        // في شاشة العدادات نعرض الوجهة والمسار فقط لتقليل التشتيت
        let showPlaces = role == .main ? places : []
        var extra = role == .main ? dataPins : []
        if let p = previewCoordinate {
            extra.append(.init(id: "preview", title: "الوجهة", subtitle: nil, coordinate: p, kind: .destination))
        }
        let set = MapOverlaySet.build(places: showPlaces,
                                      liveSegments: role == .cluster ? [] : env.recorder.liveSegments,
                                      navigation: env.navigation.snapshot,
                                      currentLocation: env.location.location?.coordinate,
                                      extraPins: extra,
                                      extraLines: role == .main ? dataLines : [])
        guard force || set != lastOverlays else { return }
        lastOverlays = set
        if let m = mapKitView { MapKitOverlayRenderer.apply(set, to: m) }
        if let m = libreView { MapLibreOverlayRenderer.apply(set, to: m) }
    }

    /// المنطقة الظاهرة حاليًا على شاشة السيارة.
    var visibleRegion: MKCoordinateRegion? {
        if let m = mapKitView { return MKCoordinateRegion(m.visibleMapRect) }
        if let m = libreView {
            let b = m.visibleCoordinateBounds
            return MKCoordinateRegion(center: .init(latitude: (b.sw.latitude + b.ne.latitude) / 2, longitude: (b.sw.longitude + b.ne.longitude) / 2),
                                      span: .init(latitudeDelta: abs(b.ne.latitude - b.sw.latitude), longitudeDelta: abs(b.ne.longitude - b.sw.longitude)))
        }
        return nil
    }

    private func bounds(of r: MKCoordinateRegion) -> (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) {
        (.init(latitude: r.center.latitude - r.span.latitudeDelta / 2, longitude: r.center.longitude - r.span.longitudeDelta / 2),
         .init(latitude: r.center.latitude + r.span.latitudeDelta / 2, longitude: r.center.longitude + r.span.longitudeDelta / 2))
    }

    private func regionChanged() { if !gestureActive { scheduleDataRefresh(force: false) } }

    private func scheduleDataRefresh(force: Bool) {
        guard role == .main else { return }
        dataWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshData(force: force) }
        }
        dataWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (force ? 0.1 : 0.7), execute: work)
    }

    /// يحدّث طبقات البيانات للمنطقة الظاهرة إذا تحركت الخريطة بما يكفي.
    private func refreshData(force: Bool) {
        guard let r = visibleRegion, r.span.latitudeDelta > 0 else { return }
        if !force, let last = lastDataRegion {
            let moved = abs(r.center.latitude - last.center.latitude) > last.span.latitudeDelta * 0.2
                || abs(r.center.longitude - last.center.longitude) > last.span.longitudeDelta * 0.2
            let zoomed = abs(r.span.latitudeDelta / max(last.span.latitudeDelta, 1e-6) - 1) > 0.25
            guard moved || zoomed else { return }
        }
        lastDataRegion = r
        collectData()
        applyAll()
        fetchRemote(r)
    }

    /// قراءة البيانات المحلية للمنطقة (بدون شبكة).
    private func collectData() {
        guard let r = lastDataRegion ?? visibleRegion else { return }
        let (sw, ne) = bounds(of: r)
        let span = r.span.latitudeDelta
        let online = env.network.isOnline

        var pins: [MapOverlaySet.Pin] = []
        if CarPlaySettings.showLandmarks, span >= 2.5, span < 12,
           CarPlaySettings.landmarkKinds.isEmpty || CarPlaySettings.landmarkKinds.contains(.nafud) {
            // أسماء النفود والعروق تظهر من مسافة أبعد
            pins += SearchService.shared.entries(sw: sw, ne: ne, limit: 25, kinds: [.nafud]).map {
                .init(id: "g-\($0.id)", title: $0.name, subtitle: $0.kind.title,
                      coordinate: .init(latitude: $0.lat, longitude: $0.lon), kind: .landmark, symbol: $0.kind.icon)
            }
        }
        if CarPlaySettings.showLandmarks, span < 2.5 {
            pins += SearchService.shared.entries(sw: sw, ne: ne, limit: span < 0.4 ? 60 : 30, kinds: CarPlaySettings.landmarkKinds,
                                                 waterSubs: CarPlaySettings.waterSubs).map {
                .init(id: "g-\($0.id)", title: $0.name, subtitle: [$0.kind.title, $0.region].compactMap { $0 }.joined(separator: " · "),
                      coordinate: .init(latitude: $0.lat, longitude: $0.lon), kind: .landmark, symbol: $0.kind.icon)
            }
        }
        var lines: [MapOverlaySet.Line] = []
        if CarPlaySettings.showCommunity, CommunityService.shared.isEnabled, span < 3 {
            pins += CommunityService.shared.places(in: sw, ne).prefix(60).map {
                .init(id: "c-\($0.id)", title: $0.name, subtitle: "مشاركة مجتمعية · \($0.kind.title)", coordinate: $0.coordinate,
                      kind: .community, symbol: nil)
            }
            let store = CommunityTrackStore.shared
            lines += store.tracks(in: sw, ne).prefix(30).map { .init(kind: .community, coordinates: store.coordinates(of: $0)) }
        }
        if CarPlaySettings.showMyTracks {
            if Date().timeIntervalSince(lastTracksFetch) > 60 {
                let d = FetchDescriptor<RecordedTrack>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
                tracks = (try? env.container.mainContext.fetch(d)) ?? []
                lastTracksFetch = Date()
            }
            lines += MyTracksOverlay.shared.lines(for: tracks, sw: sw, ne: ne)
        }
        dataPins = pins
        dataLines = lines

        if CarPlaySettings.showDirtRoads, span < 0.45 {
            if online, span < 1 { Task { await DirtRoadsStore.shared.download(sw: sw, ne: ne, auto: true) } }
            dirt = DirtRoadsStore.shared.roads(sw: sw, ne: ne, limit: span < 0.1 ? 1200 : 600,
                                               includeDetected: CarPlaySettings.showDetectedRoads && span < 0.25)
        } else {
            dirt = []
        }

        if CarPlaySettings.showCoverage, span <= 0.6 {
            let mine = CarPlaySettings.coverageOnlyMine
                ? Carrier(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.coverageCarrier) ?? "") : nil
            var list = CoverageService.shared.visibleCells(sw: sw, ne: ne, carrier: mine)
            if mine == nil {
                var best: [String: CoverageCell] = [:]
                for c in list {
                    let key = "\(c.lat)_\(c.lon)"
                    if let e = best[key], e.level.rank >= c.level.rank { continue }
                    best[key] = c
                }
                list = Array(best.values)
            }
            coverageCells = list
        } else {
            coverageCells = []
        }
        // في السيارة: رصد القمر الآن، أو توقعات الساعة الحالية بأشكال ناعمة
        rainCells = CarPlaySettings.showRainMap && RainNowService.observedMode ? RainNowService.shared.cells : []
        rainShapes = CarPlaySettings.showRainMap && !RainNowService.observedMode
            ? (RainForecastService.shared.frames.first?.shapes ?? []) : []
    }

    /// جلب ما يحتاج الإنترنت، ثم إعادة الرسم من البيانات المحلية فقط.
    private func fetchRemote(_ r: MKCoordinateRegion) {
        guard env.network.isOnline else { return }
        let (sw, ne) = bounds(of: r)
        let span = r.span.latitudeDelta
        Task { [weak self] in
            if CarPlaySettings.showCommunity, CommunityService.shared.isEnabled, span < 3 {
                await CommunityService.shared.refresh(sw: sw, ne: ne)
                await CommunityTrackStore.shared.refresh(sw: sw, ne: ne)
            }
            if CarPlaySettings.showCoverage, span <= 0.6 { await CoverageService.shared.refresh(sw: sw, ne: ne) }
            if CarPlaySettings.showRainMap {
                if RainNowService.observedMode {
                    // في السيارة نعرض أحدث صورة دائمًا
                    let rn = RainNowService.shared
                    if !rn.isLatest, !rn.frames.isEmpty { rn.index = rn.frames.count - 1 }
                    await rn.refresh(sw: sw, ne: ne)
                } else {
                    await RainForecastService.shared.refresh()
                }
            }
            guard let self else { return }
            self.collectData()
            self.applyAll()
        }
    }

    private func applyAll() {
        refreshOverlays(force: false)
        applyDataLayers()
    }

    private func applyDataLayers() {
        guard role == .main else { return }
        if let m = mapKitView {
            MapKitDataLayers.apply(dirt: dirt, coverage: coverageCells, rain: rainCells, rainHour: 0, rainShapes: rainShapes, to: m)
        }
        if let m = libreView {
            MapLibreDataLayers.dirt(dirt, on: m)
            MapLibreDataLayers.coverage(coverageCells, on: m)
            MapLibreDataLayers.rain(rainCells, hour: 0, on: m)
            MapLibreDataLayers.rainShapes(rainShapes, on: m)
            MapLibreDataLayers.highlightStyleDirt(on: m, visible: CarPlaySettings.showDirtRoads)
        }
    }

    // MARK: - أوامر من قوالب CarPlay

    func zoom(in zoomIn: Bool) {
        if let m = mapKitView {
            let cam = m.camera.copy() as! MKMapCamera
            cam.centerCoordinateDistance = min(max(cam.centerCoordinateDistance * (zoomIn ? 0.5 : 2.0), 200), 20_000_000)
            m.setCamera(cam, animated: true)
        } else if let m = libreView {
            m.setZoomLevel(m.zoomLevel + (zoomIn ? 1 : -1), animated: true)
        }
    }

    func recenter() {
        isFollowing = true
        if let m = libreView {
            m.setUserTrackingMode(CarPlaySettings.northUp ? .follow : .followWithCourse, animated: true, completionHandler: nil)
        }
        if let loc = env.location.location { locationChanged(loc) }
    }

    // MARK: - اللمس (سحب، قرص، أزرار الاتجاهات)
    //
    // مبادئ مثل خرائط Google وWaze: الخريطة تتبع الإصبع تمامًا، إيماءة واحدة في كل مرة،
    // انزلاق خفيف بعد رفع الإصبع، ولا تحديثات ثقيلة أثناء اللمس، وعودة تلقائية للتتبع أثناء الملاحة.

    /// إيماءة جارية: لا نعيد رسم الطبقات أثناءها حتى تبقى الحركة سلسة.
    private(set) var gestureActive = false
    private var zoomActive = false
    private var zoomBase: Double = 0
    private var arrowTimer: Timer?
    private var recenterWork: DispatchWorkItem?

    private func gestureBegan() {
        gestureActive = true
        recenterWork?.cancel()
        stopFollowing()
    }

    private func gestureEnded() {
        gestureActive = false
        refreshOverlays(force: false)
        scheduleDataRefresh(force: false)
        scheduleAutoRecenter()
    }

    /// أثناء الملاحة: العودة لتتبع السيارة بعد ١٥ ثانية دون لمس (مثل Waze).
    private func scheduleAutoRecenter() {
        recenterWork?.cancel()
        guard env.navigation.snapshot.isNavigating, previewCoordinate == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.gestureActive, !self.isFollowing, self.env.navigation.snapshot.isNavigating else { return }
                self.recenter()
            }
        }
        recenterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// بداية سحب الخريطة باللمس على شاشة السيارة.
    func beginPan() {
        lastPan = .zero
        lastPanTime = nil
        panTracker.reset()
        gestureBegan()
    }

    private var lastPanTime: Date?
    private var panTracker = PanTranslationTracker()

    /// السحب باللمس. Apple توثّق translation تراكميًا منذ بداية السحب، لكن بعض شاشات السيارات
    /// ترسل فرق كل تحديث فقط، فلا تتحرك الخريطة إلا في البداية. نكتشف النوع من سرعة الإصبع ونطبقه.
    func updatePan(_ translation: CGPoint, velocity: CGPoint) {
        if !gestureActive { beginPan() }
        let now = Date()
        let dt = lastPanTime.map { now.timeIntervalSince($0) }
        lastPanTime = now
        // أثناء القرص بإصبعين لا نحرك الخريطة بالسحب حتى لا تتداخل الحركتان
        guard !zoomActive else { lastPan = translation; return }
        var d = panTracker.step(translation: translation, previous: lastPan, velocity: velocity, dt: dt)
        lastPan = translation
        // حماية من القفزات (قراءة شاذة أو بداية سحب جديدة دون إشعار)
        let maxStep = max(view.bounds.width, view.bounds.height) * 0.25
        d.x = max(-maxStep, min(maxStep, d.x)); d.y = max(-maxStep, min(maxStep, d.y))
        move(by: d, animated: false)
    }

    /// نهاية السحب: انزلاق قصير بحسب سرعة الإصبع ثم توقف.
    func endPan(velocity: CGPoint) {
        let speed = hypot(velocity.x, velocity.y)
        if speed > 250, !zoomActive {
            let limit = min(view.bounds.width, view.bounds.height) * 0.35
            let f = min(0.18, limit / speed)
            move(by: CGPoint(x: velocity.x * f, y: velocity.y * f), animated: true)
        }
        gestureEnded()
    }

    /// زر اتجاه ضغطة قصيرة: خطوة ثابتة.
    func pan(_ direction: CPMapTemplate.PanDirection) {
        stopFollowing()
        move(by: arrowStep(direction, fraction: 0.3), animated: true)
        scheduleAutoRecenter()
    }

    /// زر اتجاه مضغوط باستمرار: حركة متواصلة حتى رفع الإصبع.
    func beginContinuousPan(_ direction: CPMapTemplate.PanDirection) {
        stopFollowing()
        arrowTimer?.invalidate()
        arrowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.move(by: self.arrowStep(direction, fraction: 0.02), animated: false)
            }
        }
    }

    func endContinuousPan() {
        arrowTimer?.invalidate()
        arrowTimer = nil
        scheduleDataRefresh(force: false)
        scheduleAutoRecenter()
    }

    private func arrowStep(_ direction: CPMapTemplate.PanDirection, fraction: CGFloat) -> CGPoint {
        let w = view.bounds.width * fraction, h = view.bounds.height * fraction
        var t = CGPoint.zero
        if direction.contains(.left) { t.x = w }
        if direction.contains(.right) { t.x = -w }
        if direction.contains(.up) { t.y = h }
        if direction.contains(.down) { t.y = -h }
        return t
    }

    /// يحرك محتوى الخريطة بمقدار نقاط على الشاشة (كأن الإصبع سحبها).
    private func move(by t: CGPoint, animated: Bool) {
        if let m = mapKitView {
            let p = CGPoint(x: m.bounds.midX - t.x, y: m.bounds.midY - t.y)
            m.setCenter(m.convert(p, toCoordinateFrom: m), animated: animated)
        } else if let m = libreView {
            let p = CGPoint(x: m.bounds.midX - t.x, y: m.bounds.midY - t.y)
            m.setCenter(m.convert(p, toCoordinateFrom: m), animated: animated)
        }
    }

    private func stopFollowing() {
        isFollowing = false
        if let m = libreView, m.userTrackingMode != .none { m.userTrackingMode = .none }
    }

    /// بداية القرص بإصبعين.
    func beginZoom() {
        gestureBegan()
        zoomActive = true
        if let m = mapKitView { zoomBase = m.camera.centerCoordinateDistance }
        if let m = libreView { zoomBase = m.zoomLevel }
    }

    /// scale تراكمي منذ بداية القرص (أكبر من ١ = تكبير، أصغر = تصغير)، مثل قرص الجوال.
    func updateZoom(scale: CGFloat) {
        guard scale.isFinite, scale > 0.05 else { return }
        // بعض الأنظمة ترسل التحديث دون إشعار البداية (مثل النقر المزدوج بإصبعين للتصغير)
        if !zoomActive { beginZoom() }
        let s = Double(min(max(scale, 0.05), 20))
        if let m = mapKitView {
            let cam = m.camera.copy() as! MKMapCamera
            cam.centerCoordinateDistance = min(max(zoomBase / s, 200), 20_000_000)
            m.setCamera(cam, animated: false)
        } else if let m = libreView {
            m.setZoomLevel(min(max(zoomBase + log2(s), m.minimumZoomLevel), m.maximumZoomLevel), animated: false)
        }
    }

    func endZoom() {
        zoomActive = false
        gestureEnded()
    }

    /// عرض الوجهة قبل بدء الملاحة (مع موقعي)، أو إلغاء المعاينة بـ nil.
    func showPreview(_ c: CLLocationCoordinate2D?) {
        previewCoordinate = c
        refreshOverlays(force: true)
        guard let c else { recenter(); return }
        var coords = [c]
        if let here = env.location.location?.coordinate { coords.append(here) }
        fit(coords)
    }

    /// إظهار منطقة كاملة (مثل منطقة منزلة).
    func fit(_ coords: [CLLocationCoordinate2D]) {
        guard let box = GeoMath.boundingBox(coords) else { return }
        stopFollowing()
        if let m = mapKitView {
            let center = CLLocationCoordinate2D(latitude: (box.sw.latitude + box.ne.latitude) / 2,
                                                longitude: (box.sw.longitude + box.ne.longitude) / 2)
            m.setRegion(MKCoordinateRegion(center: center,
                                           span: MKCoordinateSpan(latitudeDelta: max(0.01, (box.ne.latitude - box.sw.latitude) * 1.5),
                                                                  longitudeDelta: max(0.01, (box.ne.longitude - box.sw.longitude) * 1.5))),
                        animated: true)
        } else if let m = libreView {
            m.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: box.sw, ne: box.ne),
                                         edgePadding: UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50),
                                         animated: true, completionHandler: nil)
        }
    }

    func showWholeRoute() {
        guard let plan = env.navigation.snapshot.plan else { return }
        var coords = plan.allPoints.map(\.coordinate)
        if let c = env.location.location?.coordinate { coords.append(c) }
        fit(coords)
    }
}

// MARK: - مندوبو الخريطة
// كائنان منفصلان لأن MKMapViewDelegate وMLNMapViewDelegate يستخدمان أسماء دوال Objective-C متطابقة
// ولا يمكن لكائن واحد أن يطبّق الاثنين معًا.

final class CarPlayMapKitDelegate: NSObject, MKMapViewDelegate {
    @MainActor var onRegionChange: (() -> Void)?

    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        MainActor.assumeIsolated { MapKitDataLayers.renderer(for: overlay) ?? MapKitOverlayRenderer.renderer(for: overlay) }
    }

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        MainActor.assumeIsolated { MapKitOverlayRenderer.view(for: annotation, in: mapView) }
    }

    nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        MainActor.assumeIsolated { onRegionChange?() }
    }
}

final class CarPlayMapLibreDelegate: NSObject, MLNMapViewDelegate {
    @MainActor var onRegionChange: (() -> Void)?
    @MainActor var onStyleLoaded: (() -> Void)?

    nonisolated func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        MapLibreOverlayRenderer.strokeColor(for: annotation)
    }

    nonisolated func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
        MapLibreOverlayRenderer.lineWidth(for: annotation)
    }

    nonisolated func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
        MainActor.assumeIsolated { MapLibreOverlayRenderer.image(for: annotation, mapView: mapView) }
    }

    nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        MainActor.assumeIsolated { onStyleLoaded?() }
    }

    nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        MainActor.assumeIsolated { onRegionChange?() }
    }

    nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        MainActor.assumeIsolated {
            CarPlayConnectionMonitor.shared.log("فشل تحميل الخريطة دون إنترنت: \(error.localizedDescription)")
            OfflineMapManager.shared.reportStyleError(error)
        }
    }
}
