import SwiftUI
import MapKit
import MapLibre

/// خريطة MapLibre لعرض الحزم المنزلة وملفات MBTiles دون إنترنت.
struct OfflineMapView: UIViewRepresentable {
    let styleURL: URL?
    let overlays: MapOverlaySet
    @ObservedObject var mapManager: MapManager

    func makeCoordinator() -> Coordinator { Coordinator(mapManager: mapManager) }

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

        init(mapManager: MapManager) { self.mapManager = mapManager }

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
            !(annotation is MLNUserLocation)
        }

        nonisolated func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            MainActor.assumeIsolated {
                OfflineMapManager.shared.reportStyleError(error)
            }
        }
    }
}
