import UIKit
import MapKit
import MapLibre
import Combine
import SwiftData
import CarPlay

/// محرك الخريطة على شاشة السيارة.
enum CarPlayMapEngine: String {
    case mapKitStandard, mapKitSatellite, offline
    var title: String {
        switch self {
        case .mapKitStandard: return "خريطة عادية"
        case .mapKitSatellite: return "أقمار صناعية"
        case .offline: return "دون إنترنت"
        }
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
        // بدون إنترنت ومع توفر خرائط محلية: نبدأ بمحرك دون إنترنت تلقائيًا
        if !env.network.isOnline, engine != .offline,
           let c = env.location.location?.coordinate, env.offlineMaps.hasOfflineCoverage(at: c) {
            engine = .offline
        }
        buildMap()
        bind()
    }

    // MARK: - المحرك

    func setEngine(_ e: CarPlayMapEngine) {
        guard e != engine else { return }
        engine = e
        buildMap()
    }

    private func buildMap() {
        mapKitView?.removeFromSuperview(); mapKitView = nil
        libreView?.removeFromSuperview(); libreView = nil
        lastOverlays = nil

        switch engine {
        case .mapKitStandard, .mapKitSatellite:
            let m = MKMapView(frame: view.bounds)
            m.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            m.delegate = mapKitDelegate
            m.mapType = engine == .mapKitSatellite ? .hybrid : .standard
            m.showsUserLocation = true
            m.showsCompass = role != .cluster
            m.showsScale = role == .main
            m.pointOfInterestFilter = role == .cluster ? .excludingAll : .includingAll
            m.isPitchEnabled = false
            view.addSubview(m)
            mapKitView = m
            if let c = env.location.location?.coordinate {
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
            view.addSubview(m)
            libreView = m
            if let c = env.location.location?.coordinate {
                m.setCenter(c, zoomLevel: role == .cluster ? 14 : 13, animated: false)
            }
            m.userTrackingMode = .followWithCourse
        }
        refreshOverlays(force: true)
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
    }

    private func locationChanged(_ loc: CLLocation) {
        guard isFollowing else { return }
        if let m = mapKitView {
            let camera = MKMapCamera(lookingAtCenter: loc.coordinate,
                                     fromDistance: m.camera.centerCoordinateDistance > 0 ? m.camera.centerCoordinateDistance : zoomMeters * 2,
                                     pitch: 0,
                                     heading: (loc.course >= 0 && loc.speed > 3) ? loc.course : m.camera.heading)
            m.setCamera(camera, animated: true)
        } else if let m = libreView, m.userTrackingMode == .none {
            m.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
        }
    }

    func refreshOverlays(force: Bool) {
        if Date().timeIntervalSince(lastPlacesFetch) > 20 || force {
            let descriptor = FetchDescriptor<SavedPlace>(sortBy: [SortDescriptor(\.name)])
            places = (try? env.container.mainContext.fetch(descriptor)) ?? []
            lastPlacesFetch = Date()
        }
        // في شاشة العدادات نعرض الوجهة والمسار فقط لتقليل التشتيت
        let showPlaces = role == .main ? places : []
        let set = MapOverlaySet.build(places: showPlaces,
                                      liveSegments: role == .cluster ? [] : env.recorder.liveSegments,
                                      navigation: env.navigation.snapshot,
                                      currentLocation: env.location.location?.coordinate)
        guard force || set != lastOverlays else { return }
        lastOverlays = set
        if let m = mapKitView { MapKitOverlayRenderer.apply(set, to: m) }
        if let m = libreView { MapLibreOverlayRenderer.apply(set, to: m) }
    }

    // MARK: - أوامر من قوالب CarPlay

    func zoom(in zoomIn: Bool) {
        if let m = mapKitView {
            var r = m.region
            let f = zoomIn ? 0.5 : 2.0
            r.span = MKCoordinateSpan(latitudeDelta: min(max(r.span.latitudeDelta * f, 0.002), 90),
                                      longitudeDelta: min(max(r.span.longitudeDelta * f, 0.002), 180))
            m.setRegion(r, animated: true)
        } else if let m = libreView {
            m.setZoomLevel(m.zoomLevel + (zoomIn ? 1 : -1), animated: true)
        }
    }

    func recenter() {
        isFollowing = true
        if let loc = env.location.location { locationChanged(loc) }
        libreView?.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
    }

    /// تحريك الخريطة يدويًا (إلزامي في تطبيقات الملاحة على CarPlay).
    func pan(_ direction: CPMapTemplate.PanDirection) {
        isFollowing = false
        var dx = 0.0, dy = 0.0
        if direction.contains(.left) { dx = -1 }
        if direction.contains(.right) { dx = 1 }
        if direction.contains(.up) { dy = 1 }
        if direction.contains(.down) { dy = -1 }
        if let m = mapKitView {
            var c = m.region.center
            c.latitude += dy * m.region.span.latitudeDelta * 0.25
            c.longitude += dx * m.region.span.longitudeDelta * 0.25
            m.setCenter(c, animated: true)
        } else if let m = libreView {
            m.userTrackingMode = .none
            let b = m.visibleCoordinateBounds
            var c = m.centerCoordinate
            c.latitude += dy * (b.ne.latitude - b.sw.latitude) * 0.25
            c.longitude += dx * (b.ne.longitude - b.sw.longitude) * 0.25
            m.setCenter(c, animated: true)
        }
    }

    func showWholeRoute() {
        guard let plan = env.navigation.snapshot.plan else { return }
        isFollowing = false
        var coords = plan.allPoints.map(\.coordinate)
        if let c = env.location.location?.coordinate { coords.append(c) }
        guard let box = GeoMath.boundingBox(coords) else { return }
        if let m = mapKitView {
            let center = CLLocationCoordinate2D(latitude: (box.sw.latitude + box.ne.latitude) / 2,
                                                longitude: (box.sw.longitude + box.ne.longitude) / 2)
            m.setRegion(MKCoordinateRegion(center: center,
                                           span: MKCoordinateSpan(latitudeDelta: max(0.01, (box.ne.latitude - box.sw.latitude) * 1.5),
                                                                  longitudeDelta: max(0.01, (box.ne.longitude - box.sw.longitude) * 1.5))),
                        animated: true)
        } else if let m = libreView {
            m.userTrackingMode = .none
            m.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: box.sw, ne: box.ne),
                                         edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                                         animated: true, completionHandler: nil)
        }
    }
}

// MARK: - مندوبو الخريطة
// كائنان منفصلان لأن MKMapViewDelegate وMLNMapViewDelegate يستخدمان أسماء دوال Objective-C متطابقة
// ولا يمكن لكائن واحد أن يطبّق الاثنين معًا.

final class CarPlayMapKitDelegate: NSObject, MKMapViewDelegate {
    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        MainActor.assumeIsolated { MapKitOverlayRenderer.renderer(for: overlay) }
    }

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        MainActor.assumeIsolated { MapKitOverlayRenderer.view(for: annotation, in: mapView) }
    }
}

final class CarPlayMapLibreDelegate: NSObject, MLNMapViewDelegate {
    nonisolated func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
        MapLibreOverlayRenderer.strokeColor(for: annotation)
    }

    nonisolated func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
        MapLibreOverlayRenderer.lineWidth(for: annotation)
    }

    nonisolated func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
        MainActor.assumeIsolated { MapLibreOverlayRenderer.image(for: annotation, mapView: mapView) }
    }

    nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
        MainActor.assumeIsolated {
            CarPlayConnectionMonitor.shared.log("فشل تحميل الخريطة دون إنترنت: \(error.localizedDescription)")
            OfflineMapManager.shared.reportStyleError(error)
        }
    }
}
