import SwiftUI
import SwiftData
import CoreLocation
import MapKit

/// الشاشة الرئيسية: خريطة تفاعلية مع معلومات الموقع وأدوات الملاحة والتسجيل.
struct MapScreen: View {
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var recorder: RouteRecordingManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var offlineMaps: OfflineMapManager
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var trips: TripManager
    @EnvironmentObject private var search: SearchService
    @EnvironmentObject private var community: CommunityService
    @EnvironmentObject private var communityTracks: CommunityTrackStore
    @AppStorage(SettingsKeys.showLandmarks) private var showLandmarks = true
    @AppStorage(SettingsKeys.showCommunity) private var showCommunity = true
    @AppStorage(SettingsKeys.landmarkKinds) private var landmarkKindsRaw = ""
    @AppStorage("waterSubs") private var waterSubsRaw = ""
    @State private var nameFilter = ""
    @State private var showFilterField = false
    @FocusState private var filterFocused: Bool
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]

    @State private var showPickedOptions = false
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var sendingLocation = false
    @State private var shareLocationText: String?
    @AppStorage(SettingsKeys.emergencyNumber) private var emergencyNumber = ""
    @AppStorage(SettingsKeys.showDirtRoads) private var showDirtRoads = true
    @AppStorage(SettingsKeys.showDetectedRoads) private var showDetectedRoads = true
    @EnvironmentObject private var dirt: DirtRoadsStore
    @EnvironmentObject private var coverage: CoverageService
    @EnvironmentObject private var safeTrip: SafeTripManager
    @EnvironmentObject private var follow: FollowService
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var speedLimits: SpeedLimitStore
    @AppStorage(SettingsKeys.showWind) private var showWind = true
    @AppStorage(SettingsKeys.showRainMap) private var showRainMap = false
    @State private var rainHour = 0
    @StateObject private var rainNow = RainNowService.shared
    @StateObject private var rainForecast = RainForecastService.shared
    @AppStorage(RainNowService.modeKey) private var rainObserved = false

    /// طبقة الأمطار: توقعات الساعات القادمة بأشكال ناعمة (افتراضيًا)، أو رصد القمر الصناعي الآن.
    private var shownRainCells: [RainCell] {
        guard showRainMap, rainObserved else { return [] }
        return rainNow.cells
    }
    private var shownRainShapes: [RainShape] {
        guard showRainMap, !rainObserved else { return [] }
        return rainForecast.selected?.shapes ?? []
    }
    private var shownRainHour: Int { 0 }
    @State private var showFuel = false
    @State private var showLayers = false
    @State private var dirtRoads: [DirtRoad] = []
    @State private var coverageCells: [CoverageCell] = []
    @State private var showStopRecordingConfirm = false
    @State private var showCoverageReport = false
    @State private var showCarrierPicker = false
    @AppStorage(SettingsKeys.showMyTracks) private var showMyTracks = false
    @AppStorage(SettingsKeys.showSpeed) private var showSpeed = true
    @AppStorage(SettingsKeys.showCoverage) private var showCoverage = false
    @AppStorage(SettingsKeys.coverageOnlyMine) private var coverageOnlyMine = true
    @AppStorage(SettingsKeys.coverageCarrier) private var carrierRaw = ""
    @AppStorage(SettingsKeys.userMarkerStyle) private var markerStyleRaw = UserMarkerStyle.dot.rawValue
    @AppStorage(SettingsKeys.userMarkerColor) private var markerColorRaw = UserMarkerColor.white.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \RecordedTrack.startedAt, order: .reverse) private var myTracks: [RecordedTrack]
    /// نتائج الطبقات الثقيلة محفوظة حسب المنطقة والإعدادات، فلا يُعاد حسابها مع كل تحديث للموقع أو البوصلة.
    @State private var memo = OverlayMemo()
    @State private var regionWork: Task<Void, Never>?

    /// مفتاح المنطقة الظاهرة (تتغير فقط عند نهاية تحريك الخريطة).
    private var regionKey: String {
        guard let r = mapManager.visibleRegion else { return "-" }
        return String(format: "%.5f,%.5f,%.5f,%.5f", r.center.latitude, r.center.longitude, r.span.latitudeDelta, r.span.longitudeDelta)
    }

    private var markerStyle: UserMarkerStyle { UserMarkerStyle(rawValue: markerStyleRaw) ?? .dot }
    private var markerColor: UserMarkerColor { UserMarkerColor(rawValue: markerColorRaw) ?? .white }

    /// اتجاه علامة المركبة: اتجاه السير أثناء الحركة، وإلا البوصلة.
    private var userHeading: Double? {
        if let l = location.location, l.course >= 0, l.speed > 1.5 { return l.course }
        return location.currentHeadingDegrees
    }

    /// آخر مواقع من أتابع رحلاتهم الآمنة النشطة.
    private var followPins: [MapOverlaySet.Pin] {
        follow.activeTrips.map {
            .init(id: "f-\($0.id)", title: $0.displayName,
                  subtitle: ($0.isLate ? "تأخر التحديث · " : "رحلة آمنة · ") + "آخر تحديث " + Fmt.time.string(from: $0.updatedAt),
                  coordinate: $0.coordinate, kind: .friend)
        }
    }

    /// كل مساراتي السابقة (عند تفعيل زر المسارات) بلون مختلف.
    private var myTracksLines: [MapOverlaySet.Line] {
        guard showMyTracks, let b = mapManager.visibleBounds else { return [] }
        let key = "\(regionKey)|\(myTracks.count)|\(myTracks.first?.id.uuidString ?? "")|\(myTracks.reduce(0) { $0 + $1.pointCount })"
        return memo.get("myTracks", key) { MyTracksOverlay.shared.lines(for: myTracks, sw: b.sw, ne: b.ne) }
    }

    private var overlays: MapOverlaySet {
        MapOverlaySet.build(places: places,
                            liveSegments: recorder.liveSegments,
                            navigation: navigation.snapshot,
                            currentLocation: location.location?.coordinate,
                            picked: mapManager.pickedCoordinate,
                            extraPins: landmarkPins + communityPins + shownTrackPins + followPins + (mapManager.searchPin.map { [$0] } ?? []),
                            extraLines: myTracksLines
                                + (router.shownTrack?.segments ?? []).map { .init(kind: .importedTrack, coordinates: $0) }
                                + communityTrackLines)
    }

    /// أسماء الأماكن المعروفة (OpenStreetMap) ضمن المنطقة الظاهرة، عند تكبير كافٍ.
    private var landmarkPins: [MapOverlaySet.Pin] {
        let kinds = PlaceKind.expand(PlaceKind.decodeSet(landmarkKindsRaw))
        let subs = kinds.contains(.water) ? WaterSub.decode(waterSubsRaw) : []
        let filtered = !kinds.isEmpty || !nameFilter.isEmpty
        // عند الفلترة تقل الأسماء، فيُسمح بعرضها على مساحة أوسع
        guard showLandmarks, let b = mapManager.visibleBounds, let r = mapManager.visibleRegion else { return [] }
        let key = "\(regionKey)|\(landmarkKindsRaw)|\(waterSubsRaw)|\(nameFilter)|\(search.indexRevision)"
        return memo.get("landmarks", key) {
            Self.declutter(computeLandmarkPins(b: b, r: r, kinds: kinds, subs: subs, filtered: filtered), region: r)
        }
    }

    /// تخفيف الازدحام: لا يظهر مكانان متقاربان جدًا على الشاشة (الأهم أولًا لأن القائمة مرتبة بالأولوية).
    /// الشبكة ٩ خانات بعرض الشاشة (خانات مربعة على الأرض)، أي علامة واحدة لكل ٤٥ نقطة تقريبًا على الجوال.
    static func declutter(_ pins: [MapOverlaySet.Pin], region r: MKCoordinateRegion, columns: Double = 9) -> [MapOverlaySet.Pin] {
        let cellLon = max(r.span.longitudeDelta / columns, 1e-6)
        // درجة الطول أقصر من درجة العرض بمقدار جيب تمام خط العرض، فنجعل الخانة مربعة على الأرض
        let cellLat = max(cellLon * cos(r.center.latitude * .pi / 180), 1e-6)
        var used = Set<Int64>()
        var out: [MapOverlaySet.Pin] = []
        for p in pins {
            let key = Int64((p.coordinate.latitude / cellLat).rounded(.down)) << 32 ^ Int64((p.coordinate.longitude / cellLon).rounded(.down))
            if used.insert(key).inserted { out.append(p) }
        }
        return out
    }

    private func computeLandmarkPins(b: (sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D), r: MKCoordinateRegion,
                                     kinds: Set<PlaceKind>, subs: Set<WaterSub>, filtered: Bool) -> [MapOverlaySet.Pin] {
        // النفود والعروق مناطق واسعة: أسماؤها تظهر من مسافة أبعد من بقية الأماكن
        if r.span.latitudeDelta >= (filtered ? 8 : 3) {
            guard r.span.latitudeDelta < 12, kinds.isEmpty || kinds.contains(.nafud) else { return [] }
            return search.entries(sw: b.sw, ne: b.ne, limit: 40, kinds: [.nafud], nameFilter: nameFilter).map {
                .init(id: "g-\($0.id)", title: $0.name, subtitle: $0.kind.title, coordinate: .init(latitude: $0.lat, longitude: $0.lon),
                      kind: .landmark, symbol: $0.kind.icon)
            }
        }
        return search.entries(sw: b.sw, ne: b.ne, limit: r.span.latitudeDelta < 0.5 ? 150 : 70,
                              kinds: kinds, nameFilter: nameFilter, waterSubs: subs).map {
            .init(id: "g-\($0.id)", title: $0.name, subtitle: [$0.kind.title, $0.region].compactMap { $0 }.joined(separator: " · "), coordinate: .init(latitude: $0.lat, longitude: $0.lon),
                  kind: .landmark, symbol: $0.kind.icon)
        }
    }

    private var shownTrackPins: [MapOverlaySet.Pin] {
        guard let t = router.shownTrack, let s = t.segments.first?.first, let e = t.segments.last?.last else { return [] }
        return [.init(id: "st-start", title: "البداية", subtitle: t.name, coordinate: s, kind: .start, symbol: "flag.fill"),
                .init(id: "st-end", title: "النهاية", subtitle: t.name, coordinate: e, kind: .destination, symbol: "flag.checkered")]
            + TrackStops.pins(stops: t.stops, idPrefix: "st")
    }

    /// مسارات المجتمع ضمن المنطقة الظاهرة (عند تكبير كافٍ لتبقى الخريطة واضحة).
    private var communityTrackLines: [MapOverlaySet.Line] {
        guard showCommunity, let b = mapManager.visibleBounds, let r = mapManager.visibleRegion, r.span.latitudeDelta < 4 else { return [] }
        let key = "\(regionKey)|\(communityTracks.tracks.count)|\(communityTracks.tracks.last?.id ?? "")"
        return memo.get("communityTracks", key) {
            communityTracks.tracks(in: b.sw, b.ne).prefix(40).map { .init(kind: .community, coordinates: communityTracks.coordinates(of: $0)) }
        }
    }

    private var communityPins: [MapOverlaySet.Pin] {
        guard showCommunity, let b = mapManager.visibleBounds else { return [] }
        let key = "\(regionKey)|\(community.places.count)|\(community.places.last?.id ?? "")|\(community.hiddenAuthors.count)|\(community.reportedIDs.count)"
        return memo.get("community", key) {
            community.places(in: b.sw, b.ne).prefix(150).map {
                .init(id: "c-\($0.id)", title: $0.name, subtitle: "مشاركة مجتمعية · \($0.kind.title)", coordinate: $0.coordinate,
                      kind: .community, symbol: nil)
            }
        }
    }

    var body: some View {
        withFuelDialog(withDialogs(withPinDialogs(withMoreObservers(withObservers(withSheets(mainStack))))))
    }

    private var coverageNote: String? {
        guard let r = mapManager.visibleRegion, r.span.latitudeDelta > 0.6 else { return nil }
        return "قرّب للعرض"
    }


    private var mainStack: some View {
        ZStack {
            mapLayer.ignoresSafeArea(edges: [.top, .horizontal])

            overlayColumn

            if (showLandmarks || showCommunity || !dirtRoads.isEmpty) && !hasPlaceCard {
                VStack {
                    Spacer()
                    HStack {
                        Text(dirtRoads.contains { $0.kind == .detected }
                             ? "البيانات: © OpenStreetMap contributors، Microsoft Road Detections"
                             : "البيانات: © OpenStreetMap contributors")
                            .font(.system(size: 9))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                            .environment(\.layoutDirection, .rightToLeft)
                        Spacer()
                    }
                    .padding(.leading, 70)
                    .padding(.bottom, 92)
                }
                .allowsHitTesting(false)
            }

            if mapManager.isPickingPoint {
                VStack {
                    Text("اضغط على الخريطة لتحديد نقطة")
                        .font(.callout.weight(.semibold))
                        .hudCard()
                        .padding(.top, 120)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// على الآيباد (العرض الواسع) لا تمتد البطاقات بعرض الشاشة.
    private var isWide: Bool { hSizeClass == .regular }

    private var overlayColumn: some View {
        VStack(spacing: DS.s) {
            VStack(spacing: DS.s) {
                StatusHUD()
                if showLandmarks && !navigation.snapshot.isNavigating && !mapManager.isPickingPoint { placeFilterBar }
                banners
                // مفتاح ألوان التغطية أعلى الشاشة تحت الشريط، لا في وسط الخريطة
                if showCoverage && !navigation.snapshot.isNavigating {
                    CoverageLegend(note: coverageNote)
                }
                if showRainMap && !navigation.snapshot.isNavigating {
                    RainPanel(forecast: rainForecast, observedService: rainNow, observed: $rainObserved)
                }
                if navigation.snapshot.isNavigating { NavigationPanel() }
                if recorder.isActive { RecordingPanel(onStop: { showStopRecordingConfirm = true }) }
            }
            .frame(maxWidth: isWide ? DS.panelMaxWidth : .infinity)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            HStack(alignment: .bottom) {
                secondaryControls
                Spacer()
                controls
            }
            Group {
                if hasPlaceCard {
                    placeCard.frame(maxWidth: isWide ? DS.panelMaxWidth : .infinity)
                } else {
                    ActionBar(onRecordTap: toggleRecording).frame(maxWidth: isWide ? DS.actionBarMaxWidth : .infinity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: hasPlaceCard)
        }
        .padding(.horizontal, DS.m)
        .padding(.bottom, DS.s)
        // ظهور لوحة المفاتيح أو إغلاق شاشة فوق الخريطة لا يحرك الأزرار من أماكنها
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func withSheets<V: View>(_ v: V) -> some View {
        v
        .sheet(item: $router.mapSheet) { sheet in sheetContent(sheet) }
        .onChange(of: router.mapSheet == nil) { _, closed in if !closed { filterFocused = false } }
        .onChange(of: showLayers) { _, open in if open { filterFocused = false } }
        .sheet(isPresented: $showLayers) {
            LayersSheet(mapManager: mapManager, communityEnabled: community.isEnabled, safeTripActive: safeTrip.isActive,
                        followingCount: follow.activeTrips.count) { action in
                // ننتظر إغلاق اللوحة قبل فتح شاشة أخرى
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { performLayersAction(action) }
            }
        }
        .sheet(isPresented: $sendingLocation) {
            if let loc = location.location {
                MessageComposer(recipients: emergencyNumber.isEmpty ? [] : [emergencyNumber], body: LocationMessage.text(for: loc))
                    .ignoresSafeArea()
            }
        }
        .sheet(item: Binding(get: { shareLocationText.map { ShareText(text: $0) } }, set: { shareLocationText = $0?.text })) {
            ShareSheet(items: [$0.text])
        }
    }

    private func withObservers<V: View>(_ v: V) -> some View {
        v
        .onChange(of: mapManager.visibleRegion?.center.latitude) { _, _ in regionChanged(moved: true) }
        .onChange(of: mapManager.visibleRegion?.center.longitude) { _, _ in regionChanged(moved: true) }
        .onChange(of: mapManager.visibleRegion?.span.latitudeDelta) { _, _ in regionChanged(moved: false) }
        .onChange(of: dirt.revision) { _, _ in refreshDirt() }
        .onChange(of: showDirtRoads) { _, _ in refreshDirt() }
        .onChange(of: showDetectedRoads) { _, _ in refreshDirt() }
        .onChange(of: mapManager.pickedCoordinate?.latitude) { _, new in
            if new != nil { showPickedOptions = true }
        }
    }

    private func withMoreObservers<V: View>(_ v: V) -> some View {
        v
        .onChange(of: showCoverage) { _, _ in refreshCoverage() }
        .onChange(of: coverageOnlyMine) { _, _ in refreshCoverage() }
        .onChange(of: coverage.revision) { _, _ in refreshCoverage(fetch: false) }
        .onChange(of: location.location?.coordinate.latitude) { _, _ in refreshWeather() }
        .onChange(of: network.isOnline) { _, on in if on { refreshWeather(); refreshRain() } }
        .onChange(of: showRainMap) { _, on in rainHour = 0; if on { refreshRain() } }
        .onChange(of: rainObserved) { _, _ in refreshRain() }
        // المطر الفعلي يتجدد كل ١٥ دقيقة عند الخادم: نتحقق كل ٥ دقائق ما دامت الطبقة ظاهرة
        .task(id: showRainMap) {
            while showRainMap && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if showRainMap { refreshRain() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await follow.refresh() }
            refreshWeather()
        }
        .task {
            // متابعة الرحلات الآمنة لمن أضافوني: كل 5 دقائق أثناء فتح التطبيق
            while !Task.isCancelled {
                await follow.refresh()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    private func withFuelDialog<V: View>(_ v: V) -> some View {
        v
        .confirmationDialog("أقرب محطات الوقود", isPresented: $showFuel, titleVisibility: .visible) {
            ForEach(Array(nearestFuel.enumerated()), id: \.offset) { _, item in
                Button("\(item.0.name) · \(Fmt.distance(item.1))") {
                    navigation.navigate(to: Waypoint(name: item.0.name, coordinate: .init(latitude: item.0.lat, longitude: item.0.lon)),
                                        mode: .road)
                }
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text(nearestFuel.isEmpty ? "لا توجد محطات معروفة قريبة في قاعدة الأماكن، أو لم يتحدد موقعك بعد."
                                     : "من بيانات OpenStreetMap، وقد لا تشمل كل المحطات. تأكد من عمل المحطة قبل الاعتماد عليها.")
        }
    }

    /// كل ما يتحدث عند تحريك الخريطة أو تكبيرها.
    /// نهاية تحريك الخريطة تغيّر المركز والمقياس معًا (ثلاثة إشعارات)؛ نجمعها في تحديث واحد بعد توقف قصير.
    private func regionChanged(moved: Bool) {
        regionWork?.cancel()
        regionWork = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            refreshCommunity()
            refreshDirt()
            refreshCoverage()
            refreshRain()
        }
    }

    /// الخيارات صارت بطاقة أسفل الخريطة (placeCard) بدل نافذة الخيارات التي لا تظهر على الآيباد.
    private func withPinDialogs<V: View>(_ v: V) -> some View { v }

    /// بطاقة النقطة المحددة أو المكان المضغوط عليه.
    @ViewBuilder
    private var placeCard: some View {
        if let pin = mapManager.selectedPin {
            PlaceCard(title: pin.title, subtitle: pin.subtitle, detail: distanceText(to: pin.coordinate),
                      coordinateText: CoordinateUtilities.format(pin.coordinate, as: .decimal),
                      primary: pinPrimaryActions(pin), more: pinMoreActions(pin)) {
                if mapManager.searchPin?.id == pin.id { mapManager.searchPin = nil }
                mapManager.selectedPin = nil
            }
        } else if showPickedOptions, let c = mapManager.pickedCoordinate {
            PlaceCard(title: "نقطة محددة", detail: distanceText(to: c),
                      coordinateText: CoordinateUtilities.format(c, as: .decimal),
                      primary: [
                        .init(id: "nav", title: "الملاحة", icon: "location.north.line.fill") {
                            navigation.navigate(to: Waypoint(name: "نقطة محددة", coordinate: c)); closePicked()
                        },
                        .init(id: "save", title: "حفظ", icon: "mappin.and.ellipse") { router.mapSheet = .savePlace(c); closePicked() },
                        .init(id: "share", title: "مشاركة", icon: "square.and.arrow.up") {
                            shareLocationText = CoordinateUtilities.shareString(c); closePicked()
                        }
                      ],
                      more: [
                        .init(id: "plan", title: "إضافة إلى مخطط المسار", icon: "point.3.connected.trianglepath.dotted") {
                            router.plannerDraft.waypoints.append(Waypoint(name: "نقطة \(router.plannerDraft.waypoints.count + 1)", coordinate: c))
                            closePicked(); router.mapSheet = .routePlanner
                        },
                        .init(id: "copy", title: "نسخ الإحداثيات", icon: "doc.on.doc") {
                            UIPasteboard.general.string = CoordinateUtilities.shareString(c); closePicked()
                        }
                      ]) { closePicked() }
        }
    }

    private var hasPlaceCard: Bool { mapManager.selectedPin != nil || (showPickedOptions && mapManager.pickedCoordinate != nil) }

    private func closePicked() {
        showPickedOptions = false
        mapManager.pickedCoordinate = nil
    }

    private func distanceText(to c: CLLocationCoordinate2D) -> String? {
        guard let here = location.location?.coordinate else { return nil }
        return "\(Fmt.distance(GeoMath.distance(here, c))) · \(Fmt.bearing(GeoMath.bearing(from: here, to: c)))"
    }

    private func withDialogs<V: View>(_ v: V) -> some View {
        v
        .confirmationDialog("حالة الشبكة في موقعك الآن", isPresented: $showCoverageReport, titleVisibility: .visible) {
            ForEach(CoverageLevel.allCases, id: \.self) { l in
                Button(l.title) {
                    if let c = location.location?.coordinate, let carrier = Carrier(rawValue: carrierRaw) {
                        coverage.report(l, at: c, carrier: carrier)
                        showCoverage = true
                    }
                }
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("شركتك: \(Carrier(rawValue: carrierRaw)?.title ?? "")")
        }
        .confirmationDialog("اختر شركة الاتصال في جوالك", isPresented: $showCarrierPicker, titleVisibility: .visible) {
            ForEach(Carrier.allCases) { c in
                Button(c.title) { carrierRaw = c.rawValue; showCoverageReport = true }
            }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("إنهاء التسجيل؟", isPresented: $showStopRecordingConfirm, titleVisibility: .visible) {
            Button("إنهاء وحفظ المسار") { recorder.finish() }
            Button("حذف التسجيل", role: .destructive) { recorder.discard() }
            Button("متابعة التسجيل", role: .cancel) {}
        }
    }

    // MARK: - الخريطة

    @ViewBuilder
    private var mapLayer: some View {
        if mapManager.layer == .dirt {
            // نفس مصدر الخرائط المجاني مع إبراز الطرق الترابية؛ يعمل دون إنترنت في المناطق المنزّلة
            OfflineMapView(styleURL: URL(string: OfflineMapManager.defaultStyleURL), overlays: overlays, mapManager: mapManager,
                           highlightDirtRoads: true, dirtRoads: dirtRoads, coverageCells: coverageCells,
                           rainCells: shownRainCells, rainHour: shownRainHour, rainShapes: shownRainShapes,
                           markerStyle: markerStyle, markerColor: markerColor)
                .overlay(nightDim)
        } else if mapManager.layer == .offline {
            OfflineMapView(styleURL: offlineMaps.activeStyleURL, overlays: overlays, mapManager: mapManager, highlightDirtRoads: true,
                           dirtRoads: dirtRoads, coverageCells: coverageCells,
                           rainCells: shownRainCells, rainHour: shownRainHour, rainShapes: shownRainShapes,
                           markerStyle: markerStyle, markerColor: markerColor)
                .overlay(nightDim)
        } else {
            OnlineMapView(overlays: overlays, mapManager: mapManager, dirtRoads: dirtRoads, dirtLabels: dirtLabels,
                          coverageCells: coverageCells, rainCells: shownRainCells, rainHour: shownRainHour, rainShapes: shownRainShapes,
                          userCoordinate: location.location?.coordinate, userHeading: userHeading,
                          markerStyle: markerStyle, markerColor: markerColor)
        }
    }

    /// خرائط MapLibre نهارية التصميم؛ في النمط الليلي نخفف سطوعها حتى لا تبهر السائق.
    @ViewBuilder
    private var nightDim: some View {
        if colorScheme == .dark {
            Color.black.opacity(0.32).allowsHitTesting(false)
        }
    }

    // MARK: - أدوات الخريطة

    /// العمود الأساسي: الطبقات، ثم التكبير والتصغير معًا، ثم موقعي وتحديد نقطة معًا (مثل خرائط Apple).
    private var controls: some View {
        VStack(spacing: DS.s) {
            MapControlButton(systemImage: "square.3.layers.3d", label: "الطبقات والأدوات") { showLayers = true }
            MapControlGroup(items: [
                .init(id: "in", systemImage: "plus", label: "تكبير") { mapManager.send(.zoomIn) },
                .init(id: "out", systemImage: "minus", label: "تصغير") { mapManager.send(.zoomOut) }
            ])
            MapControlGroup(items: [
                .init(id: "me", systemImage: mapManager.followsUser ? "location.fill" : "location", label: "موقعي الحالي",
                      isActive: mapManager.followsUser) { mapManager.send(.centerOnUser) },
                .init(id: "pick", systemImage: "scope", label: "تحديد نقطة من الخريطة",
                      isActive: mapManager.isPickingPoint) { mapManager.isPickingPoint.toggle() }
            ])
        }
        .padding(.bottom, DS.s)
    }

    /// العمود الثاني: المنظور ثلاثي الأبعاد، مساراتي السابقة، والشمال.
    /// السرعة الحالية إذا كانت موثوقة وأعلى من المشي البطيء.
    private var currentSpeed: Double? {
        // سرعة حية فقط (أحدث من ٣ ثوانٍ وبدقة مقبولة)؛ القديمة لا تُعرض كأنها حالية
        guard let kmh = LiveSpeed.kmh(location.location) else { return nil }
        // أقل من ٤ كم/س تقريبًا يعني واقف (ضجيج GPS)
        return kmh > 4.3 ? kmh / 3.6 : 0
    }

    /// الطقس المعروض يخص منطقتك (أقل من ٥٠ كم) وعمره أقل من ٣ ساعات.
    private func isWeatherNearby(_ r: WeatherReport) -> Bool {
        guard Date().timeIntervalSince(r.fetchedAt) < 3 * 3600 else { return false }
        guard let c = location.location?.coordinate else { return true }
        return GeoMath.distance(c, r.coordinate) < 50_000
    }

    /// العمود الثاني: المعلومات (الرياح والسرعة) بنفس عرض الأزرار، ثم أدوات العرض في مجموعة واحدة.
    private var secondaryControls: some View {
        VStack(spacing: DS.s) {
            if showWind, let r = weather.report, isWeatherNearby(r) {
                Button { router.mapSheet = .weather } label: { WindChip(now: r.now, mapHeading: mapManager.cameraHeading) }
                    .buttonStyle(.plain)
            }
            if showSpeed {
                SpeedBubble(speedMS: currentSpeed, limit: speedLimits.currentLimit, over: speedLimits.isOver,
                            limitNote: speedLimits.state.note)
                    .padding(.top, 12)
            }
            MapControlGroup(items: [
                .init(id: "3d", systemImage: "view.3d", text: mapManager.is3D ? "2D" : "3D",
                      label: mapManager.is3D ? "عرض مسطح" : "عرض ثلاثي الأبعاد", isActive: mapManager.is3D) {
                    mapManager.send(.pitch(!mapManager.is3D))
                },
                .init(id: "tracks", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                      label: showMyTracks ? "إخفاء مساراتي السابقة" : "عرض كل مساراتي السابقة", isActive: showMyTracks) {
                    showMyTracks.toggle()
                    if showMyTracks, !myTracks.isEmpty, mapManager.visibleRegion.map({ $0.span.latitudeDelta > 3 }) ?? true {
                        // تقريب على مكان المسارات إن كانت الخريطة بعيدة
                        let pts = myTracks.prefix(30).compactMap { $0.points.first?.coordinate }
                        if !pts.isEmpty { mapManager.send(.fit(pts)) }
                    }
                },
                .init(id: "north", systemImage: "location.north.line", label: "توجيه الخريطة للشمال") { mapManager.send(.resetNorth) }
            ])
        }
        .padding(.bottom, DS.s)
    }

    // MARK: - التنبيهات

    @ViewBuilder
    private var banners: some View {
        if location.isDenied {
            Banner(icon: "location.slash", text: "إذن الموقع مرفوض. لا يمكن عرض موقعك أو تسجيل المسارات.",
                   actionTitle: "فتح الإعدادات", tint: .red) { location.openSystemSettings() }
        } else if !location.isFullAccuracy && location.isAuthorized {
            Banner(icon: "location.circle", text: "الموقع التقريبي مفعل؛ الدقة غير كافية للملاحة.",
                   actionTitle: "طلب الدقة الكاملة", tint: .orange) { location.requestFullAccuracyIfNeeded() }
        }
        if (recorder.isActive || navigation.snapshot.isNavigating) && location.gpsQuality == .weak {
            Banner(icon: "antenna.radiowaves.left.and.right.slash",
                   text: "دقة GPS ضعيفة حاليًا. قد تكون المسافات والاتجاهات غير دقيقة.", tint: .orange)
        }
        if !network.isOnline && mapManager.layer.needsInternet {
            Banner(icon: "wifi.slash", text: "لا يوجد اتصال. قد لا تظهر الخريطة الحالية في المناطق غير المحملة.",
                   actionTitle: "خرائط دون إنترنت", tint: Theme.brown) { mapManager.layer = .offline }
        }
        if let err = offlineMaps.lastError {
            Banner(icon: "exclamationmark.triangle", text: err, actionTitle: "إخفاء", tint: .red) { offlineMaps.clearError() }
        }
        if let t = router.shownTrack {
            Banner(icon: "point.topleft.down.to.point.bottomright.curvepath", text: "معروض: \(t.name)", actionTitle: "إخفاء", tint: Theme.brown) {
                router.shownTrack = nil
            }
        }
        if let s = safeTrip.state {
            Banner(icon: "shield.lefthalf.filled",
                   text: s.lastUploadAt.map { "الرحلة الآمنة مفعلة · آخر تحديث الساعة " + Fmt.time.string(from: $0) }
                       ?? "الرحلة الآمنة مفعلة · بانتظار الاتصال لرفع الموقع",
                   actionTitle: "التفاصيل", tint: .green) { router.mapSheet = .safeTrip }
        }
        ForEach(follow.lateTrips) { t in
            Banner(icon: "exclamationmark.triangle.fill",
                   text: "\(t.displayName): لم يتحدث موقعه منذ \(SafeTripManager.hoursText(t.hours)) أو أكثر.",
                   actionTitle: "آخر موقع", tint: .red) { router.mapSheet = .following }
        }
        if showMyTracks && myTracks.isEmpty {
            Banner(icon: "point.topleft.down.to.point.bottomright.curvepath", text: "لا توجد مسارات محفوظة بعد.",
                   actionTitle: "إخفاء", tint: Theme.brown) { showMyTracks = false }
        }
        if let n = recorder.recoveredNotice {
            Banner(icon: "arrow.uturn.backward.circle", text: n, actionTitle: "حسنًا", tint: Theme.brown) { recorder.clearRecoveredNotice() }
        }
        if let msg = location.lastError, location.isAuthorized {
            Banner(icon: "exclamationmark.circle", text: msg, tint: .orange)
        }
    }

    // MARK: - فلتر الأماكن المعروفة

    private var selectedKinds: Set<PlaceKind> { PlaceKind.decodeSet(landmarkKindsRaw) }

    private func toggleKind(_ k: PlaceKind) {
        var s = selectedKinds
        if s.contains(k) { s.remove(k) } else { s.insert(k) }
        if s.count == PlaceKind.mapKinds.count { s = [] }
        landmarkKindsRaw = PlaceKind.encodeSet(s)
    }

    /// شريط فلترة أسماء الأماكن الظاهرة على الخريطة حسب النوع أو الاسم.
    private var placeFilterBar: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Button { showFilterField.toggle(); filterFocused = showFilterField; if !showFilterField { nameFilter = "" } } label: {
                        Image(systemName: nameFilter.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 34, height: 32)
                            .background(Capsule().fill(showFilterField || !nameFilter.isEmpty ? Theme.desertOrange : Theme.sand))
                            .foregroundStyle(showFilterField || !nameFilter.isEmpty ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("فلترة الأسماء على الخريطة")
                    FilterChip(title: "الكل", icon: "square.grid.2x2", selected: selectedKinds.isEmpty) { landmarkKindsRaw = "" }
                    ForEach(PlaceKind.mapKinds) { k in
                        FilterChip(title: k.title, icon: k.icon, selected: selectedKinds.contains(k)) { toggleKind(k) }
                    }
                }
                .padding(.horizontal, 2)
            }
            // تفصيل المياه: يظهر عند اختيار «مياه وآبار» فقط
            if selectedKinds.contains(.water) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        let subs = WaterSub.decode(waterSubsRaw)
                        let counts = search.waterCounts
                        FilterChip(title: "كل المياه", icon: "drop.circle", selected: subs.isEmpty) { waterSubsRaw = "" }
                        ForEach(WaterSub.allCases) { s in
                            FilterChip(title: "\(s.title) \(counts[s] ?? 0)", icon: s.icon, selected: subs.contains(s)) {
                                var n = subs
                                if n.contains(s) { n.remove(s) } else { n.insert(s) }
                                waterSubsRaw = n.count == WaterSub.allCases.count ? "" : WaterSub.encode(n)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                // توضيح مصدر الماء البارد مع رابط قائمته الأصلية مباشرة
                let subsNow = WaterSub.decode(waterSubsRaw)
                if subsNow.isEmpty || subsNow.contains(.cold), let url = search.coldWaterSourceURL {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Image(systemName: "waterbottle").foregroundStyle(Theme.desertOrange)
                            Text("الماء البارد من قائمة «موارد الماء» لعبدالعزيز المفدى").lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text("فتح القائمة").fontWeight(.semibold).foregroundStyle(Theme.desertOrange)
                            Image(systemName: "arrow.up.left.square").foregroundStyle(Theme.desertOrange)
                        }
                        .font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                }
            }
            if showFilterField {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("اكتب اسم المكان لإظهاره على الخريطة", text: $nameFilter)
                        .focused($filterFocused)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                    if !nameFilter.isEmpty {
                        Button { nameFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("مسح")
                    }
                    Button("بحث شامل") { router.pendingSearchQuery = nameFilter; router.mapSheet = .search }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            }
            if (!selectedKinds.isEmpty || !nameFilter.isEmpty), let r = mapManager.visibleRegion, r.span.latitudeDelta >= 8 {
                Text("قرّب الخريطة لعرض الأماكن المطابقة")
                    .font(.caption).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
            }
        }
    }

    /// رسالة SMS بالموقع (تصل بإشارة الجوال دون إنترنت)، أو مشاركة النص إن تعذّرت الرسائل.
    private func sendLocation() {
        guard let loc = location.location else { location.requestWhenInUse(); return }
        if MessageComposer.canSend { sendingLocation = true } else { shareLocationText = LocationMessage.text(for: loc) }
    }

    /// الردميات ضمن المنطقة الظاهرة، مع تنزيل تلقائي لبيانات المنطقة عند توفر الإنترنت.
    private func refreshDirt() {
        guard showDirtRoads, let b = mapManager.visibleBounds, let r = mapManager.visibleRegion, r.span.latitudeDelta < 0.45 else {
            if !dirtRoads.isEmpty { dirtRoads = [] }
            return
        }
        if network.isOnline, r.span.latitudeDelta < 1 { Task { await dirt.download(sw: b.sw, ne: b.ne, auto: true) } }
        let limit = r.span.latitudeDelta < 0.1 ? 1500 : 700
        dirtRoads = dirt.roads(sw: b.sw, ne: b.ne, limit: limit, includeDetected: showDetectedRoads && r.span.latitudeDelta < 0.25)
    }

    /// النصوص المكتوبة على الردميات: المسماة أولًا، ثم غير المسماة الطويلة عند التكبير.
    private var dirtLabels: [DirtRoad] {
        // الأسماء فقط؛ الطرق غير المسماة يكفي لونها (ومفتاح الألوان في قائمة الطبقات)
        let key = "\(dirtRoads.count)|\(dirtRoads.first?.id ?? "")|\(dirtRoads.last?.id ?? "")"
        return memo.get("dirtLabels", key) { Array(dirtRoads.filter { !$0.name.isEmpty && $0.coordinates.count > 1 }.prefix(30)) }
    }

    private func refreshCommunity() {
        guard showCommunity, community.isEnabled, network.isOnline,
              let b = mapManager.visibleBounds, let r = mapManager.visibleRegion, r.span.latitudeDelta < 4 else { return }
        Task {
            await community.refresh(sw: b.sw, ne: b.ne)
            await communityTracks.refresh(sw: b.sw, ne: b.ne)
        }
    }

    // MARK: - الضغط على مكان في الخريطة

    private func pinPrimaryActions(_ pin: MapOverlaySet.Pin) -> [PlaceCard.Action] {
        var list: [PlaceCard.Action] = [
            .init(id: "nav", title: "الملاحة", icon: "location.north.line.fill") {
                navigation.navigate(to: Waypoint(name: pin.title, coordinate: pin.coordinate)); mapManager.selectedPin = nil
            }
        ]
        if pin.kind != .saved {
            list.append(.init(id: "save", title: "حفظ", icon: "mappin.and.ellipse") {
                router.mapSheet = .savePlace(pin.coordinate); mapManager.selectedPin = nil
            })
        }
        list.append(.init(id: "share", title: "مشاركة", icon: "square.and.arrow.up") {
            shareLocationText = pin.title + "\n" + CoordinateUtilities.shareString(pin.coordinate); mapManager.selectedPin = nil
        })
        return list
    }

    private func pinMoreActions(_ pin: MapOverlaySet.Pin) -> [PlaceCard.Action] {
        var list: [PlaceCard.Action] = [
            .init(id: "road", title: "طريق بالسيارة إن وُجد", icon: "car") {
                navigation.navigate(to: Waypoint(name: pin.title, coordinate: pin.coordinate), mode: .road); mapManager.selectedPin = nil
            },
            .init(id: "plan", title: "إضافة إلى مخطط المسار", icon: "point.3.connected.trianglepath.dotted") {
                router.plannerDraft.waypoints.append(Waypoint(name: pin.title, coordinate: pin.coordinate))
                mapManager.selectedPin = nil; router.mapSheet = .routePlanner
            }
        ]
        if let key = ReviewsService.placeKey(forPinID: pin.id) {
            list.append(.init(id: "reviews", title: "التقييمات والتعليقات", icon: "star.bubble") {
                router.mapSheet = .reviews(key, pin.title); mapManager.selectedPin = nil
            })
        }
        if let link = search.entry(forPinID: pin.id)?.url, let url = URL(string: link) {
            list.append(.init(id: "source", title: "فتح المصدر الأصلي", icon: "arrow.up.left.square") {
                UIApplication.shared.open(url); mapManager.selectedPin = nil
            })
        }
        list.append(.init(id: "copy", title: "نسخ الإحداثيات", icon: "doc.on.doc") {
            UIPasteboard.general.string = CoordinateUtilities.shareString(pin.coordinate); mapManager.selectedPin = nil
        })
        return list
    }

    private func performLayersAction(_ a: LayersAction) {
        switch a {
        case .weather: router.mapSheet = .weather
        case .fuel: showFuel = true
        case .safeTrip: router.mapSheet = .safeTrip
        case .following: router.mapSheet = .following
        case .emergency: router.mapSheet = .emergency
        case .sendLocation: sendLocation()
        case .reportCoverage: requestCoverageReport()
        }
    }

    // MARK: - الطقس

    private func refreshWeather() {
        guard (showWind || router.mapSheet != nil), network.isOnline, let c = location.location?.coordinate else { return }
        Task { await weather.refresh(at: c) }
    }

    private func refreshRain() {
        guard showRainMap, network.isOnline, let b = mapManager.visibleBounds else { return }
        if rainObserved {
            Task { await rainNow.refresh(sw: b.sw, ne: b.ne) }
        } else {
            Task { await rainForecast.refresh() }
        }
    }

    /// أقرب محطات الوقود من قاعدة الأماكن (تعمل دون إنترنت).
    private var nearestFuel: [(GazetteerEntry, Double)] {
        guard let c = location.location?.coordinate else { return [] }
        return search.nearest(.fuel, to: c, count: 5)
    }

    // MARK: - تغطية الشبكة

    private func requestCoverageReport() {
        guard location.location != nil else { location.requestWhenInUse(); return }
        if Carrier(rawValue: carrierRaw) == nil { showCarrierPicker = true } else { showCoverageReport = true }
    }

    private func refreshCoverage(fetch: Bool = true) {
        guard showCoverage, let b = mapManager.visibleBounds, let r = mapManager.visibleRegion, r.span.latitudeDelta <= 0.6 else {
            if !coverageCells.isEmpty { coverageCells = [] }
            return
        }
        if fetch, network.isOnline { Task { await coverage.refresh(sw: b.sw, ne: b.ne) } }
        let mine = coverageOnlyMine ? Carrier(rawValue: carrierRaw) : nil
        var list = coverage.visibleCells(sw: b.sw, ne: b.ne, carrier: mine)
        if mine == nil {
            // لكل مربع أفضل حالة بين الشركات
            var best: [String: CoverageCell] = [:]
            for c in list {
                let key = "\(c.lat)_\(c.lon)"
                if let e = best[key], e.level.rank >= c.level.rank { continue }
                best[key] = c
            }
            list = Array(best.values)
        }
        coverageCells = list
    }

    private func toggleRecording() {
        switch recorder.state {
        case .idle:
            if location.isAuthorized { recorder.start(trip: trips.activeTrip) } else { location.requestWhenInUse() }
        case .recording: recorder.pause()
        case .paused: recorder.resume()
        }
    }

    // MARK: - الأوراق

    @ViewBuilder
    private func sheetContent(_ sheet: MapSheet) -> some View {
        switch sheet {
        case .savePlace(let c):
            NavigationStack { PlaceEditorView(mode: .create(c)) }
                .onDisappear { mapManager.pickedCoordinate = nil }
        case .search:
            NavigationStack { SearchView() }
        case .coordinates:
            NavigationStack { CoordinateInputView() }
        case .offlineMaps:
            NavigationStack { OfflineMapsView() }
        case .trips:
            NavigationStack { TripsListView() }
        case .routePlanner:
            NavigationStack { RoutePlannerView() }
        case .recording:
            NavigationStack { TracksListView() }
        case .safeTrip:
            NavigationStack { SafeTripView() }
        case .emergency:
            NavigationStack { EmergencyView() }
        case .following:
            NavigationStack { FollowingView() }
        case .weather:
            NavigationStack { WeatherView() }
        case .reviews(let key, let name):
            NavigationStack { ReviewsView(placeKey: key, placeName: name) }
        }
    }
}

/// شريط تنبيه موحّد.
struct Banner: View {
    let icon: String
    let text: String
    var actionTitle: String?
    var tint: Color = .orange
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.headline)
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(tint)
            }
        }
        .hudCard()
    }
}

struct ShareText: Identifiable {
    let text: String
    var id: String { text }
}

/// ذاكرة مؤقتة صغيرة لنتائج الطبقات الثقيلة: تُعاد النتيجة نفسها ما دام المفتاح (المنطقة والإعدادات والبيانات) لم يتغير.
/// مرجع (class) حتى لا يؤدي تحديثها إلى إعادة رسم الشاشة.
final class OverlayMemo {
    private var store: [String: (key: String, value: Any)] = [:]

    func get<T>(_ name: String, _ key: String, _ make: () -> T) -> T {
        if let e = store[name], e.key == key, let v = e.value as? T { return v }
        let v = make()
        store[name] = (key, v)
        return v
    }
}
