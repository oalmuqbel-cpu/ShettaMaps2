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
        let covKey = coverageCells.map(\.id).joined(separator: ",")
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
        var pendingCoverage: [CoverageCell] = []
        var markerKey = ""
        var markerStyle: UserMarkerStyle = .dot
        var markerColor: UserMarkerColor = .white

        init(mapManager: MapManager) { self.mapManager = mapManager }

        /// ردميات بيانات سَمْت: مصدر أشكال مع طبقة خطوط وطبقة نصوص على امتداد الطريق.
        func applyDirt(on map: MLNMapView) {
            guard let style = map.style else { return }
            let features: [MLNPolylineFeature] = pendingDirt.map { r in
                var coords = r.coordinates
                let f = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
                f.attributes = ["kind": r.kind.rawValue, "label": r.name]
                return f
            }
            let shape = MLNShapeCollectionFeature(shapes: features)
            if let src = style.source(withIdentifier: "samt-dirt-data") as? MLNShapeSource {
                src.shape = shape
                return
            }
            let src = MLNShapeSource(identifier: "samt-dirt-data", shape: shape, options: nil)
            style.addSource(src)
            // إطار تحت الخط ليظهر على الرمل والأقمار الصناعية: أبيض للمؤكدة وداكن للمرصودة
            let casing = MLNLineStyleLayer(identifier: "samt-dirt-data-casing", source: src)
            casing.lineColor = NSExpression(format: "TERNARY(kind == 'ms_detected', %@, %@)",
                                            UIColor.black.withAlphaComponent(0.45), UIColor.white.withAlphaComponent(0.9))
            casing.lineWidth = NSExpression(format: "TERNARY(kind == 'ms_detected', 4.5, 6)")
            casing.lineCap = NSExpression(forConstantValue: "round")
            let line = MLNLineStyleLayer(identifier: "samt-dirt-data-line", source: src)
            line.lineColor = NSExpression(format: "TERNARY(kind == 'ms_detected', %@, %@)",
                                          DirtRoadStyle.detectedUI, DirtRoadStyle.confirmedUI)
            line.lineWidth = NSExpression(format: "TERNARY(kind == 'ms_detected', 2.5, 3.5)")
            line.lineDashPattern = NSExpression(forConstantValue: [2, 1.2])
            let text = MLNSymbolStyleLayer(identifier: "samt-dirt-data-label", source: src)
            text.predicate = NSPredicate(format: "label != ''")
            text.text = NSExpression(forKeyPath: "label")
            text.symbolPlacement = NSExpression(forConstantValue: "line")
            text.textFontSize = NSExpression(forConstantValue: 12)
            text.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
            text.textColor = NSExpression(forConstantValue: UIColor(red: 0.30, green: 0.15, blue: 0.03, alpha: 1))
            text.textHaloColor = NSExpression(forConstantValue: UIColor.white)
            text.textHaloWidth = NSExpression(forConstantValue: 2)
            text.minimumZoomLevel = 12
            if let firstSymbol = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                style.insertLayer(casing, below: firstSymbol)
                style.insertLayer(line, below: firstSymbol)
            } else {
                style.addLayer(casing)
                style.addLayer(line)
            }
            style.addLayer(text)
        }

        /// مربعات تغطية الشبكة (تعبئة ملونة حسب الحالة).
        func applyCoverage(on map: MLNMapView) {
            guard let style = map.style else { return }
            let polys: [MLNPolygonFeature] = pendingCoverage.map { cell in
                var coords = cell.corners
                let f = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
                f.attributes = ["level": cell.level.rawValue]
                return f
            }
            let shape = MLNShapeCollectionFeature(shapes: polys)
            if let src = style.source(withIdentifier: "samt-coverage") as? MLNShapeSource {
                src.shape = shape
                return
            }
            let src = MLNShapeSource(identifier: "samt-coverage", shape: shape, options: nil)
            style.addSource(src)
            let fill = MLNFillStyleLayer(identifier: "samt-coverage-fill", source: src)
            fill.fillColor = NSExpression(format: "TERNARY(level == 'data', %@, TERNARY(level == 'voice', %@, %@))",
                                          CoverageLevel.data.uiColor, CoverageLevel.voice.uiColor, CoverageLevel.none.uiColor)
            fill.fillOpacity = NSExpression(forConstantValue: 0.32)
            fill.fillOutlineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.25))
            if let firstSymbol = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                style.insertLayer(fill, below: firstSymbol)
            } else {
                style.addLayer(fill)
            }
        }

        /// إبراز الطرق الترابية والردميات من بيانات OpenStreetMap (طبقة transportation: class=track أو surface=unpaved).
        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                applyDirt(on: mapView)
                applyCoverage(on: mapView)
                guard highlightDirtRoads, style.layer(withIdentifier: "samt-dirt-roads") == nil else { return }
                let vectorSources = style.sources.compactMap { $0 as? MLNVectorTileSource }
                guard let source = vectorSources.first(where: { $0.identifier == "openmaptiles" }) ?? vectorSources.first else { return }
                let casing = MLNLineStyleLayer(identifier: "samt-dirt-roads-casing", source: source)
                casing.sourceLayerIdentifier = "transportation"
                casing.predicate = NSPredicate(format: "%K == %@ OR %K == %@", "class", "track", "surface", "unpaved")
                casing.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.9))
                casing.lineWidth = NSExpression(forConstantValue: 5.5)
                casing.minimumZoomLevel = 9
                let line = MLNLineStyleLayer(identifier: "samt-dirt-roads", source: source)
                line.sourceLayerIdentifier = "transportation"
                line.predicate = casing.predicate
                line.lineColor = NSExpression(forConstantValue: DirtRoadStyle.confirmedUI)
                line.lineWidth = NSExpression(forConstantValue: 3)
                line.lineDashPattern = NSExpression(forConstantValue: [2.2, 1.2])
                line.minimumZoomLevel = 9
                // تحت الأسماء: قبل أول طبقة رموز إن وجدت
                if let firstSymbol = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
                    style.insertLayer(casing, below: firstSymbol)
                    style.insertLayer(line, below: firstSymbol)
                } else {
                    style.addLayer(casing)
                    style.addLayer(line)
                }
            }
        }

        func perform(_ cmd: MapCommand, on map: MLNMapView) {
            switch cmd {
            case .zoomIn: map.setZoomLevel(min(map.zoomLevel + 1, map.maximumZoomLevel), animated: true)
            case .zoomOut: map.setZoomLevel(max(map.zoomLevel - 1, map.minimumZoomLevel), animated: true)
            case .resetNorth: map.setDirection(0, animated: true)
            case .centerOnUser:
                map.setUserTrackingMode(.follow, animated: true, completionHandler: nil)
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
