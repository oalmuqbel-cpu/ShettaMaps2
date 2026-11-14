import SwiftUI
import MapKit

/// خريطة MapKit (عادية، تضاريس، أقمار صناعية، هجينة). تحتاج إلى الإنترنت لتحميل المربعات.
struct OnlineMapView: View {
    let overlays: MapOverlaySet
    @ObservedObject var mapManager: MapManager
    var dirtRoads: [DirtRoad] = []
    var dirtLabels: [DirtRoad] = []
    var coverageCells: [CoverageCell] = []
    var userCoordinate: CLLocationCoordinate2D?
    var userHeading: Double?
    var markerStyle: UserMarkerStyle = .dot
    var markerColor: UserMarkerColor = .white

    @State private var position: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
                           latitudinalMeters: 600_000, longitudinalMeters: 600_000)))
    @State private var camera: MapCamera?
    @State private var selection: String?

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: .all, selection: $selection) {
                ForEach(coverageCells) { cell in
                    MapPolygon(coordinates: cell.corners)
                        .foregroundStyle(cell.level.color.opacity(0.32))
                        .stroke(cell.level.color.opacity(0.7), lineWidth: 0.6)
                }
                ForEach(dirtRoads) { road in
                    if road.kind == .detected {
                        // المرصودة من الأقمار: أصفر منقط بإطار داكن ليظهر على الرمل والأقمار الصناعية
                        MapPolyline(coordinates: road.coordinates)
                            .stroke(Color.black.opacity(0.45), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: road.coordinates)
                            .stroke(DirtRoadStyle.detected, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [3, 4]))
                    } else {
                        // الردميات المؤكدة: برتقالي ترابي واضح بإطار أبيض
                        MapPolyline(coordinates: road.coordinates)
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: road.coordinates)
                            .stroke(DirtRoadStyle.confirmed, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round, dash: [8, 4]))
                    }
                }
                ForEach(dirtLabels) { road in
                    Annotation("", coordinate: road.coordinates[road.coordinates.count / 2], anchor: .center) {
                        Text(road.name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DirtRoadStyle.labelBackground, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.8), lineWidth: 0.8))
                    }
                }
                ForEach(Array(overlays.lines.enumerated()), id: \.offset) { _, line in
                    lineContent(line)
                }
                ForEach(overlays.pins, id: \.id) { pin in
                    if pin.kind.isSmall {
                        Annotation("", coordinate: pin.coordinate, anchor: .center) {
                            SmallPinView(kind: pin.kind)
                        }
                        .tag(pin.id)
                    } else {
                        Marker(pin.title, systemImage: pin.symbol ?? PinImageFactory.symbol(kind: pin.kind), coordinate: pin.coordinate)
                            .tint(Color(uiColor: PinImageFactory.color(kind: pin.kind)))
                            .tag(pin.id)
                    }
                }
                if markerStyle == .dot {
                    UserAnnotation()
                } else if let c = userCoordinate {
                    Annotation("", coordinate: c, anchor: .center) {
                        VehicleMarkerView(style: markerStyle, color: markerColor)
                            .rotationEffect(.degrees((userHeading ?? 0) - (camera?.heading ?? 0)))
                            .animation(.easeOut(duration: 0.3), value: userHeading)
                            .allowsHitTesting(false)
                    }
                }
            }
            .mapStyle(mapManager.layer.mapStyle)
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .gesture(SpatialTapGesture().onEnded { value in
                guard mapManager.isPickingPoint, let c = proxy.convert(value.location, from: .local) else { return }
                mapManager.pickedCoordinate = c
                mapManager.isPickingPoint = false
            }, including: mapManager.isPickingPoint ? .all : .subviews)
            .onChange(of: selection) { _, id in
                guard let id else { return }
                if let pin = overlays.pins.first(where: { $0.id == id }) { mapManager.selectedPin = pin }
                selection = nil
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                camera = ctx.camera
                mapManager.visibleRegion = ctx.region
                mapManager.cameraHeading = ctx.camera.heading
                if position.positionedByUser { mapManager.followsUser = false }
                if ctx.camera.pitch < 5, mapManager.is3D { mapManager.is3D = false }
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
        case .myTracks:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.myTracks, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    private func perform(_ cmd: MapCommand) {
        switch cmd {
        case .zoomIn: scale(by: 0.5)
        case .zoomOut: scale(by: 2)
        case .resetNorth:
            if let cam = camera {
                withAnimation { position = .camera(MapCamera(centerCoordinate: cam.centerCoordinate, distance: cam.distance, heading: 0, pitch: cam.pitch)) }
            }
        case .centerOnUser:
            if mapManager.is3D, let c = userCoordinate {
                withAnimation { position = .camera(MapCamera(centerCoordinate: c, distance: min(camera?.distance ?? 2500, 4000),
                                                             heading: camera?.heading ?? 0, pitch: 65)) }
            } else {
                withAnimation { position = .userLocation(followsHeading: false, fallback: .automatic) }
            }
        case let .focus(coord, span):
            withAnimation { position = .region(MKCoordinateRegion(center: coord, latitudinalMeters: span, longitudinalMeters: span)) }
        case let .fit(coords):
            guard let box = GeoMath.boundingBox(coords) else { return }
            let center = CLLocationCoordinate2D(latitude: (box.sw.latitude + box.ne.latitude) / 2,
                                                longitude: (box.sw.longitude + box.ne.longitude) / 2)
            let span = MKCoordinateSpan(latitudeDelta: max(0.01, (box.ne.latitude - box.sw.latitude) * 1.4),
                                        longitudeDelta: max(0.01, (box.ne.longitude - box.sw.longitude) * 1.4))
            withAnimation { position = .region(MKCoordinateRegion(center: center, span: span)) }
        case .pitch(let on):
            // الميلان يحتاج تقريبًا كافيًا؛ نقرّب إلى ٤ كم كحد أقصى عند التفعيل
            let center = camera?.centerCoordinate ?? userCoordinate ?? CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)
            let distance = on ? min(camera?.distance ?? 2500, 4000) : (camera?.distance ?? 2500)
            withAnimation(.easeInOut(duration: 0.6)) {
                position = .camera(MapCamera(centerCoordinate: center, distance: distance,
                                             heading: camera?.heading ?? 0, pitch: on ? 65 : 0))
            }
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

/// ألوان الردميات الموحدة على كل الطبقات.
enum DirtRoadStyle {
    static let confirmedUI = UIColor(red: 0.86, green: 0.45, blue: 0.08, alpha: 1)
    static let detectedUI = UIColor(red: 0.98, green: 0.80, blue: 0.18, alpha: 1)
    static let confirmed = Color(uiColor: confirmedUI)
    static let detected = Color(uiColor: detectedUI)
    static let labelBackground = Color(red: 0.42, green: 0.24, blue: 0.08)
}

/// علامة صغيرة لوقفات الرحلة.
struct SmallPinView: View {
    let kind: MapOverlaySet.PinKind
    var body: some View {
        Image(systemName: PinImageFactory.symbol(kind: kind))
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color(uiColor: PinImageFactory.color(kind: kind))))
            .overlay(Circle().stroke(.white, lineWidth: 1.8))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}
