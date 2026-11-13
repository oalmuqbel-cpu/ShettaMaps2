import SwiftUI
import MapKit

/// خريطة MapKit (عادية، تضاريس، أقمار صناعية، هجينة). تحتاج إلى الإنترنت لتحميل المربعات.
struct OnlineMapView: View {
    let overlays: MapOverlaySet
    @ObservedObject var mapManager: MapManager
    var dirtRoads: [DirtRoad] = []
    var dirtLabels: [DirtRoad] = []

    @State private var position: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
                           latitudinalMeters: 600_000, longitudinalMeters: 600_000)))
    @State private var camera: MapCamera?

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: .all) {
                ForEach(dirtRoads) { road in
                    if road.kind == .detected {
                        MapPolyline(coordinates: road.coordinates)
                            .stroke(Color(red: 0.93, green: 0.62, blue: 0.25).opacity(0.9),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4]))
                    } else {
                        MapPolyline(coordinates: road.coordinates)
                            .stroke(Color(red: 0.55, green: 0.29, blue: 0.08),
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [7, 4]))
                    }
                }
                ForEach(dirtLabels) { road in
                    Annotation("", coordinate: road.coordinates[road.coordinates.count / 2], anchor: .center) {
                        Text(road.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(road.kind == .detected ? Color.orange : Color(red: 0.45, green: 0.22, blue: 0.05))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.regularMaterial, in: Capsule())
                    }
                }
                UserAnnotation()
                ForEach(Array(overlays.lines.enumerated()), id: \.offset) { _, line in
                    lineContent(line)
                }
                ForEach(overlays.pins, id: \.id) { pin in
                    Marker(pin.title, systemImage: pin.symbol ?? PinImageFactory.symbol(kind: pin.kind), coordinate: pin.coordinate)
                        .tint(Color(uiColor: PinImageFactory.color(kind: pin.kind)))
                }
            }
            .mapStyle(mapManager.layer.mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
                MapPitchToggle()
            }
            .onTapGesture { point in
                guard mapManager.isPickingPoint, let c = proxy.convert(point, from: .local) else { return }
                mapManager.pickedCoordinate = c
                mapManager.isPickingPoint = false
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                camera = ctx.camera
                mapManager.visibleRegion = ctx.region
                mapManager.cameraHeading = ctx.camera.heading
                if position.positionedByUser { mapManager.followsUser = false }
            }
            .onChange(of: mapManager.commandID) { _, _ in
                if let cmd = mapManager.command { perform(cmd) }
            }
        }
    }

    @MapContentBuilder
    private func lineContent(_ line: MapOverlaySet.Line) -> some MapContent {
        switch line.kind {
        case .direct:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.directLine, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10, 8]))
        case .road:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.route, lineWidth: 7)
        case .track:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.track, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        case .importedTrack:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Color.purple, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        case .community:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Color(red: 0.55, green: 0.30, blue: 0.12).opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [6, 5]))
        }
    }

    private func perform(_ cmd: MapCommand) {
        switch cmd {
        case .zoomIn: scale(by: 0.5)
        case .zoomOut: scale(by: 2)
        case .resetNorth:
            if let cam = camera {
                withAnimation { position = .camera(MapCamera(centerCoordinate: cam.centerCoordinate, distance: cam.distance, heading: 0, pitch: 0)) }
            }
        case .centerOnUser:
            withAnimation { position = .userLocation(followsHeading: false, fallback: .automatic) }
        case let .focus(coord, span):
            withAnimation { position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: span, longitudinalMeters: span)) }
        case let .fit(coords):
            guard let box = GeoMath.boundingBox(coords) else { return }
            let center = CLLocationCoordinate2D(latitude: (box.sw.latitude + box.ne.latitude) / 2,
                                                longitude: (box.sw.longitude + box.ne.longitude) / 2)
            let span = MKCoordinateSpan(latitudeDelta: max(0.01, (box.ne.latitude - box.sw.latitude) * 1.4),
                                        longitudeDelta: max(0.01, (box.ne.longitude - box.sw.longitude) * 1.4))
            withAnimation { position = .region(MKCoordinateRegion(center: center, span: span)) }
        }
    }

    private func scale(by factor: Double) {
        guard let cam = camera else { return }
        let d = min(max(cam.distance * factor, 150), 20_000_000)
        withAnimation {
            position = .camera(MapCamera(centerCoordinate: cam.centerCoordinate, distance: d, heading: cam.heading, pitch: cam.pitch))
        }
    }
}
