import SwiftUI
import MapKit

/// خريطة MapKit (عادية، تضاريس، أقمار صناعية، هجينة). تحتاج إلى الإنترنت لتحميل المربعات.
struct OnlineMapView: View {
    let overlays: MapOverlaySet
    @ObservedObject var mapManager: MapManager
    var dirtRoads: [DirtRoad] = []
    var dirtLabels: [DirtRoad] = []
    var coverageCells: [CoverageCell] = []
    var rainCells: [RainCell] = []
    var rainHour: Int = 0
    var rainShapes: [RainShape] = []
    var reserves: [Reserve] = []
    var userCoordinate: CLLocationCoordinate2D?
    var userHeading: Double?
    var markerStyle: UserMarkerStyle = .dot
    var markerColor: UserMarkerColor = .white
    /// القيادة على طريق: تتبع قريب بمنظور مائل والسيارة أسفل الشاشة.
    var driving: Bool = false

    @State private var position: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753),
                           latitudinalMeters: 600_000, longitudinalMeters: 600_000)))
    @State private var camera: MapCamera?
    @State private var selection: String?

    var body: some View {
        MapReader { proxy in
            Map(position: $position, interactionModes: .all, selection: $selection) {
                ForEach(reserves) { r in
                    let color = Color(uiColor: r.kind.uiColor)
                    ForEach(Array(r.mkPolygons.enumerated()), id: \.offset) { _, poly in
                        MapPolygon(poly)
                            .foregroundStyle(color.opacity(0.10))
                            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, dash: [6, 4]))
                    }
                }
                ForEach(rainCells) { cell in
                    let l = RainScale.level(cell.hourly.indices.contains(rainHour) ? cell.hourly[rainHour] : 0)
                    if l > 0 {
                        MapPolygon(coordinates: cell.corners)
                            .foregroundStyle(RainScale.color(l).opacity(0.45))
                    }
                }
                ForEach(rainShapes) { shape in
                    MapPolygon(shape.polygon)
                        .foregroundStyle(RainScale.color(shape.level).opacity(0.55))
                }
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
                            .environment(\.layoutDirection, .leftToRight)
                            .animation(.easeOut(duration: 0.3), value: userHeading)
                            .allowsHitTesting(false)
                    }
                }
            }
            .mapStyle(mapManager.layer.mapStyle(threeD: mapManager.is3D))
            .mapControls {
                // أثناء القيادة على طريق تدور الخريطة مع الاتجاه دائمًا، فتختفي البوصلة حتى لا تغطي شريط الحالة
                MapCompass().mapControlVisibility(overlays.lines.contains { $0.kind == .road } ? .hidden : .automatic)
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
                if position.positionedByUser { mapManager.followsUser = false; mapManager.headingUp = false }
                followDistance = ctx.camera.distance
            }
            .onChange(of: mapManager.commandID) { _, _ in
                if let cmd = mapManager.command { perform(cmd) }
            }
            // التتبع يدويًا مع كل قراءة موقع أو اتجاه: يحافظ على التقريب الذي نختاره ويدور مع الاتجاه بثبات
            .onChange(of: userCoordinate?.latitude) { _, _ in follow() }
            .onChange(of: userCoordinate?.longitude) { _, _ in follow() }
            .onChange(of: userHeading) { _, _ in if mapManager.headingUp { follow(duration: 0.35) } }
        }
    }

    @MapContentBuilder
    private func lineContent(_ line: MapOverlaySet.Line) -> some MapContent {
        switch line.kind {
        case .direct:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.directLine, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10, 8]))
        case .road:
            // خط الطريق مثل تطبيقات الملاحة: إطار داكن ثم أزرق عريض
            MapPolyline(coordinates: line.coordinates)
                .stroke(Color(red: 0.05, green: 0.25, blue: 0.6), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.route, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        case .roadDone:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Color.gray.opacity(0.75), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        case .routeAlt:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Color(red: 0.55, green: 0.62, blue: 0.72).opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
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
        case .qibla:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Color(red: 0.05, green: 0.45, blue: 0.25).opacity(0.95),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: [12, 6]))
        case .myTracks:
            MapPolyline(coordinates: line.coordinates)
                .stroke(Theme.myTracks, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }

    private func perform(_ cmd: MapCommand) {
        switch cmd {
        case .zoomIn: scale(by: 0.5)
        case .zoomOut: scale(by: 2)
        case .resetNorth where mapManager.followsUser:
            follow(duration: 0.4)
        case .resetNorth:
            // يعمل حتى لو لم تُسجَّل الكاميرا بعد (مثل أول تشغيل أثناء تتبع الموقع)
            let center = camera?.centerCoordinate ?? mapManager.visibleRegion?.center ?? userCoordinate
            guard let center else { return }
            let distance = camera?.distance ?? max(1_000, (mapManager.visibleRegion?.span.latitudeDelta ?? 0.05) * 111_000 * 1.6)
            withAnimation { position = .camera(MapCamera(centerCoordinate: center, distance: distance, heading: 0, pitch: camera?.pitch ?? 0)) }
            mapManager.cameraHeading = 0
        case .followCourse:
            // وضع القيادة: قريب من السيارة مهما كان التقريب السابق
            followDistance = Self.drivingDistance
            follow(duration: 0.6)
        case .followHeading, .centerOnUser:
            // إذا كانت الخريطة بعيدة جدًا (مستوى الدولة) نقرّب على موقعك
            let d = camera?.distance ?? 3000
            followDistance = d > 40_000 ? 3000 : d
            follow(duration: 0.5)
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
            // الميلان يحتاج تقريبًا كافيًا؛ نقرّب إلى ٤ كم كحد أقصى عند التفعيل.
            // ننتظر لحظة حتى يُطبَّق نمط الارتفاعات ثم نميل الكاميرا.
            let center = camera?.centerCoordinate ?? userCoordinate ?? CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)
            let distance = on ? min(camera?.distance ?? 2500, 4000) : (camera?.distance ?? 2500)
            let heading = camera?.heading ?? 0
            withAnimation(.easeInOut(duration: 0.8)) {
                position = .camera(MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: on ? 60 : 0))
            }
        }
    }

    static let drivingDistance: Double = 700
    @State private var followDistance: Double?

    /// يضع الكاميرا على موقعك: الشمال للأعلى أو باتجاهك، وفي القيادة تظهر السيارة أسفل الشاشة ليظهر الطريق أمامك.
    private func follow(duration: Double = 0.9) {
        guard mapManager.followsUser else { return }
        guard let c = userCoordinate else {
            position = .userLocation(followsHeading: mapManager.headingUp, fallback: .automatic)
            return
        }
        let heading = mapManager.headingUp ? (userHeading ?? camera?.heading ?? 0) : 0
        var distance = followDistance ?? camera?.distance ?? 3000
        if driving && mapManager.headingUp { distance = min(distance, 1_500) }
        let pitch: Double = mapManager.is3D ? 60 : (driving && mapManager.headingUp ? 45 : 0)
        // في القيادة نزيح المركز للأمام فتظهر السيارة في الثلث السفلي
        let center = driving && mapManager.headingUp ? GeoMath.destination(from: c, distance: distance * 0.12, bearing: heading) : c
        withAnimation(.linear(duration: duration)) {
            position = .camera(MapCamera(centerCoordinate: center, distance: distance, heading: heading, pitch: pitch))
        }
    }

    private func scale(by factor: Double) {
        guard let cam = camera else { return }
        let d = min(max(cam.distance * factor, 150), 20_000_000)
        followDistance = d
        if mapManager.followsUser { follow(duration: 0.3); return }
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
