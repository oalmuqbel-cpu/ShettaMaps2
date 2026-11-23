import SwiftUI
import MapKit
import MapLibre

/// خريطة MapLibre لعرض الحزم المنزلة وملفات MBTiles دون إنترنت.
struct OfflineMapView: UIViewRepresentable {
    let styleURL: URL?
    let overlays: MapOverlaySet
    @ObservedObject var mapManager: MapManager
    var highlightDirtRoads = false
    var dirtRoads: [DirtRoad] = []
    var coverageCells: [CoverageCell] = []
    var rainCells: [RainCell] = []
    var rainHour: Int = 0
    var rainShapes: [RainShape] = []
    var reserves: [Reserve] = []
    var markerStyle: UserMarkerStyle = .dot
    var markerColor: UserMarkerColor = .white

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(mapManager: mapManager)
        c.highlightDirtRoads = highlightDirtRoads
        return c
    }

    func makeUIView(context: Context) -> MLNMapView {
        let map = MLNMapView(frame: .zero, styleURL: styleURL)
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsUserHeadingIndicator = true
        map.compassView.isHidden = false
        map.logoView.isHidden = false
        map.attributionButton.isHidden = false
        map.setCenter(CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753), zoomLevel: 5, animated: false)
        if mapManager.followsUser { map.userTrackingMode = .follow }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        for g in map.gestureRecognizers ?? [] {
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 2 { tap.require(toFail: t) }
        }
        map.addGestureRecognizer(tap)
        context.coordinator.mapView = map
        context.coordinator.currentStyle = styleURL
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        if c.currentStyle != styleURL {
            c.currentStyle = styleURL
            map.styleURL = styleURL
        }
        if c.lastOverlays != overlays {
            c.lastOverlays = overlays
            MapLibreOverlayRenderer.apply(overlays, to: map)
        }
        let markerKey = "\(markerStyle.rawValue)-\(markerColor.rawValue)"
        if c.markerKey != markerKey {
            c.markerKey = markerKey
            c.markerStyle = markerStyle
            c.markerColor = markerColor
            // إعادة إنشاء علامة الموقع بالشكل الجديد
            map.showsUserLocation = false
            map.showsUserLocation = true
        }
        // المفتاح يشمل الشدة: صورة قمر جديدة قد تعطي نفس المربعات بشدة مختلفة
        let rainKey = "\(rainHour)|" + rainCells.map { "\($0.id):\(RainScale.level($0.hourly.indices.contains(rainHour) ? $0.hourly[rainHour] : 0))" }.joined(separator: ",")
        if c.lastRainKey != rainKey {
            c.lastRainKey = rainKey
            c.pendingRain = (rainCells, rainHour)
            c.applyRain(rainCells, hour: rainHour, on: map)
        }
        // معرّف كل شكل يتضمن وقت الساعة، فأول معرّف والعدد يكفيان لمعرفة تغيّر الساعة المعروضة
        let shapesKey = "\(rainShapes.first?.id ?? "-")|\(rainShapes.count)"
        if c.lastRainShapesKey != shapesKey {
            c.lastRainShapesKey = shapesKey
            c.pendingRainShapes = rainShapes
            MapLibreDataLayers.rainShapes(rainShapes, on: map)
        }
        let reservesKey = reserves.map(\.id).joined(separator: ",")
        if c.lastReservesKey != reservesKey {
            c.lastReservesKey = reservesKey
            c.pendingReserves = reserves
            MapLibreDataLayers.reserves(reserves, on: map)
        }
        // المفتاح يشمل الحالة: مربع تغيّر لونه (برتقالي إلى أخضر) يُعاد رسمه حتى لو بقيت المربعات نفسها
        let covKey = coverageCells.map { "\($0.id):\($0.level.rawValue)" }.joined(separator: ",")
        if c.lastCoverageKey != covKey {
            c.lastCoverageKey = covKey
            c.pendingCoverage = coverageCells
            c.applyCoverage(on: map)
        }
        let ids = dirtRoads.map(\.id)
        if c.lastDirtIDs != ids {
            c.lastDirtIDs = ids
            c.pendingDirt = dirtRoads
            c.applyDirt(on: map)
        }
        if c.lastCommandID != mapManager.commandID, let cmd = mapManager.command {
            c.lastCommandID = mapManager.commandID
            c.perform(cmd, on: map)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        let mapManager: MapManager
        weak var mapView: MLNMapView?
        var currentStyle: URL?
        var lastOverlays: MapOverlaySet?
        var lastCommandID = 0
        var highlightDirtRoads = false
        var lastDirtIDs: [String] = []
        var pendingDirt: [DirtRoad] = []
        var lastCoverageKey = ""
        var lastRainKey = ""
        var pendingRain: ([RainCell], Int) = ([], 0)
        var pendingCoverage: [CoverageCell] = []
        var pendingRainShapes: [RainShape] = []
        var lastRainShapesKey = ""
        var pendingReserves: [Reserve] = []
        var lastReservesKey = ""
        var markerKey = ""
        var markerStyle: UserMarkerStyle = .dot
        var markerColor: UserMarkerColor = .white

        init(mapManager: MapManager) { self.mapManager = mapManager }

        func applyDirt(on map: MLNMapView) { MapLibreDataLayers.dirt(pendingDirt, on: map) }
        func applyRain(_ cells: [RainCell], hour: Int, on map: MLNMapView) { MapLibreDataLayers.rain(cells, hour: hour, on: map) }
        func applyCoverage(on map: MLNMapView) { MapLibreDataLayers.coverage(pendingCoverage, on: map) }

        /// إبراز الطرق الترابية والردميات من بيانات OpenStreetMap (طبقة transportation: class=track أو surface=unpaved).
        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                if mapView.traitCollection.userInterfaceStyle == .dark { MapLibreNightStyle.apply(to: mapView) }
                applyDirt(on: mapView)
                applyCoverage(on: mapView)
                applyRain(pendingRain.0, hour: pendingRain.1, on: mapView)
                MapLibreDataLayers.rainShapes(pendingRainShapes, on: mapView)
                MapLibreDataLayers.reserves(pendingReserves, on: mapView)
                if highlightDirtRoads { MapLibreDataLayers.highlightStyleDirt(on: mapView, visible: true) }
            }
        }

        func perform(_ cmd: MapCommand, on map: MLNMapView) {
            switch cmd {
            case .zoomIn: map.setZoomLevel(min(map.zoomLevel + 1, map.maximumZoomLevel), animated: true)
            case .zoomOut: map.setZoomLevel(max(map.zoomLevel - 1, map.minimumZoomLevel), animated: true)
            case .resetNorth: map.setDirection(0, animated: true)
            case .centerOnUser:
                map.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
            case .followCourse:
                if map.zoomLevel < 15 { map.setZoomLevel(16, animated: false) }
                map.setUserTrackingMode(.followWithCourse, animated: true, completionHandler: nil)
            case let .focus(coord, span):
                // مستوى تكبير تقريبي من المسافة المطلوبة
                let zoom = max(2, min(18, log2(40_075_000 / max(span, 50))))
                map.setCenter(coord, zoomLevel: zoom, animated: true)
            case .pitch(let on):
                // الميلان يحتاج تقريبًا كافيًا ليظهر المنظور
                if on, map.zoomLevel < 12 { map.setZoomLevel(13, animated: false) }
                let cam = map.camera
                cam.pitch = on ? 60 : 0
                map.setCamera(cam, withDuration: 0.6, animationTimingFunction: nil)
            case let .fit(coords):
                guard let box = GeoMath.boundingBox(coords) else { return }
                if coords.count == 1 {
                    map.setCenter(box.sw, zoomLevel: 14, animated: true)
                } else {
                    map.setVisibleCoordinateBounds(MLNCoordinateBounds(sw: box.sw, ne: box.ne),
                                                   edgePadding: UIEdgeInsets(top: 80, left: 50, bottom: 160, right: 50),
                                                   animated: true, completionHandler: nil)
                }
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard mapManager.isPickingPoint, let map = mapView else { return }
            let coord = map.convert(g.location(in: map), toCoordinateFrom: map)
            mapManager.pickedCoordinate = coord
            mapManager.isPickingPoint = false
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                let b = mapView.visibleCoordinateBounds
                let center = CLLocationCoordinate2D(latitude: (b.sw.latitude + b.ne.latitude) / 2,
                                                    longitude: (b.sw.longitude + b.ne.longitude) / 2)
                mapManager.visibleRegion = MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: abs(b.ne.latitude - b.sw.latitude),
                                           longitudeDelta: abs(b.ne.longitude - b.sw.longitude)))
                mapManager.cameraHeading = mapView.direction
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
            MainActor.assumeIsolated {
                mapManager.followsUser = mode != .none
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            MapLibreOverlayRenderer.strokeColor(for: annotation)
        }

        nonisolated func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            MapLibreOverlayRenderer.lineWidth(for: annotation)
        }

        nonisolated func mapView(_ mapView: MLNMapView, imageFor annotation: MLNAnnotation) -> MLNAnnotationImage? {
            MainActor.assumeIsolated { MapLibreOverlayRenderer.image(for: annotation, mapView: mapView) }
        }

        nonisolated func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool {
            false
        }

        /// الضغط على علامة يفتح خيارات المكان (الملاحة، الحفظ، المشاركة...).
        nonisolated func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            MainActor.assumeIsolated {
                guard let a = annotation as? TaggedPointAnnotation else { return }
                if let pin = lastOverlays?.pins.first(where: { $0.id == a.pinID }) { mapManager.selectedPin = pin }
                mapView.deselectAnnotation(annotation, animated: false)
            }
        }

        /// علامة الموقع بشكل مركبة عند اختيارها من الإعدادات.
        nonisolated func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            MainActor.assumeIsolated {
                guard annotation is MLNUserLocation, markerStyle != .dot else { return nil }
                let v = VehicleUserLocationView(annotation: annotation, reuseIdentifier: "samt-vehicle")
                v.configure(style: markerStyle, color: markerColor)
                return v
            }
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            MainActor.assumeIsolated {
                OfflineMapManager.shared.reportStyleError(error)
            }
        }
    }
}

/// علامة الموقع بشكل مركبة في MapLibre: تدور مع اتجاه السير (أو البوصلة عند الوقوف) مع مراعاة دوران الخريطة.
final class VehicleUserLocationView: MLNUserLocationAnnotationView {
    private let imageView = UIImageView()

    @MainActor func configure(style: UserMarkerStyle, color: UserMarkerColor) {
        let img = VehicleMarkerImage.make(style: style, color: color)
        imageView.image = img
        let size = img?.size ?? CGSize(width: 34, height: 34)
        frame = CGRect(origin: .zero, size: CGSize(width: max(size.width, size.height), height: max(size.width, size.height)))
        imageView.frame = CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2,
                                 width: size.width, height: size.height)
        if imageView.superview == nil { addSubview(imageView) }
    }

    override func update() {
        guard let loc = userLocation?.location else { return }
        var angle: Double?
        if loc.course >= 0, loc.speed > 1.5 { angle = loc.course }
        else if let h = userLocation?.heading, h.headingAccuracy >= 0 { angle = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading }
        let mapDir = mapView?.direction ?? 0
        let rad = ((angle ?? 0) - mapDir) * .pi / 180
        UIView.animate(withDuration: 0.25) { self.imageView.transform = CGAffineTransform(rotationAngle: rad) }
    }
}
