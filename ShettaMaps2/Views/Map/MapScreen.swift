import SwiftUI
import SwiftData
import CoreLocation

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
    @State private var nameFilter = ""
    @State private var showFilterField = false
    @FocusState private var filterFocused: Bool
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]

    @State private var showPickedOptions = false
    @State private var sendingLocation = false
    @State private var shareLocationText: String?
    @AppStorage(SettingsKeys.emergencyNumber) private var emergencyNumber = ""
    @AppStorage(SettingsKeys.showDirtRoads) private var showDirtRoads = true
    @AppStorage(SettingsKeys.showDetectedRoads) private var showDetectedRoads = true
    @EnvironmentObject private var dirt: DirtRoadsStore
    @EnvironmentObject private var coverage: CoverageService
    @EnvironmentObject private var safeTrip: SafeTripManager
    @EnvironmentObject private var follow: FollowService
    @State private var dirtRoads: [DirtRoad] = []
    @State private var coverageCells: [CoverageCell] = []
    @State private var showStopRecordingConfirm = false
    @State private var showCoverageReport = false
    @State private var showCarrierPicker = false
    @AppStorage(SettingsKeys.showMyTracks) private var showMyTracks = false
    @AppStorage(SettingsKeys.showCoverage) private var showCoverage = false
    @AppStorage(SettingsKeys.coverageOnlyMine) private var coverageOnlyMine = true
    @AppStorage(SettingsKeys.coverageCarrier) private var carrierRaw = ""
    @AppStorage(SettingsKeys.userMarkerStyle) private var markerStyleRaw = UserMarkerStyle.dot.rawValue
    @AppStorage(SettingsKeys.userMarkerColor) private var markerColorRaw = UserMarkerColor.white.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \RecordedTrack.startedAt, order: .reverse) private var myTracks: [RecordedTrack]

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
        return MyTracksOverlay.shared.lines(for: myTracks, sw: b.sw, ne: b.ne)
    }

    private var overlays: MapOverlaySet {
        MapOverlaySet.build(places: places,
                            liveSegments: recorder.liveSegments,
                            navigation: navigation.snapshot,
                            currentLocation: location.location?.coordinate,
                            picked: mapManager.pickedCoordinate,
                            extraPins: landmarkPins + communityPins + shownTrackPins + followPins,
                            extraLines: myTracksLines
                                + (router.shownTrack?.segments ?? []).map { .init(kind: .importedTrack, coordinates: $0) }
                                + communityTrackLines)
    }

    /// أسماء الأماكن المعروفة (OpenStreetMap) ضمن المنطقة الظاهرة، عند تكبير كافٍ.
    private var landmarkPins: [MapOverlaySet.Pin] {
        let kinds = PlaceKind.decodeSet(landmarkKindsRaw)
        let filtered = !kinds.isEmpty || !nameFilter.isEmpty
        // عند الفلترة تقل الأسماء، فيُسمح بعرضها على مساحة أوسع
        guard showLandmarks, let b = mapManager.visibleBounds, let r = mapManager.visibleRegion,
              r.span.latitudeDelta < (filtered ? 8 : 3) else { return [] }
        return search.entries(sw: b.sw, ne: b.ne, limit: r.span.latitudeDelta < 0.5 ? 150 : 70,
                              kinds: kinds, nameFilter: nameFilter).map {
            .init(id: "g-\($0.id)", title: $0.name, subtitle: $0.kind.title, coordinate: .init(latitude: $0.lat, longitude: $0.lon),
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
        return communityTracks.tracks(in: b.sw, b.ne).prefix(40).map { .init(kind: .community, coordinates: communityTracks.coordinates(of: $0)) }
    }

    private var communityPins: [MapOverlaySet.Pin] {
        guard showCommunity, let b = mapManager.visibleBounds else { return [] }
        return community.places(in: b.sw, b.ne).prefix(150).map {
            .init(id: "c-\($0.id)", title: $0.name, subtitle: "مشاركة مجتمعية · \($0.kind.title)", coordinate: $0.coordinate,
                  kind: .community, symbol: nil)
        }
    }

    var body: some View {
        withDialogs(withPinDialogs(withObservers(withSheets(mainStack))))
    }

    private var coverageNote: String? {
        guard let r = mapManager.visibleRegion, r.span.latitudeDelta > 0.6 else { return nil }
        return "قرّب للعرض"
    }

    private var selectedPinTitle: String { mapManager.selectedPin?.title ?? "" }

    private var pinDialogShown: Binding<Bool> {
        Binding(get: { mapManager.selectedPin != nil }, set: { if !$0 { mapManager.selectedPin = nil } })
    }

    private var mainStack: some View {
        ZStack {
            mapLayer.ignoresSafeArea(edges: [.top, .horizontal])

            overlayColumn

            if showLandmarks || showCommunity || !dirtRoads.isEmpty {
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

    private var overlayColumn: some View {
        VStack(spacing: 8) {
            StatusHUD()
            if showLandmarks && !navigation.snapshot.isNavigating && !mapManager.isPickingPoint { placeFilterBar }
            banners
            if navigation.snapshot.isNavigating { NavigationPanel() }
            if recorder.isActive { RecordingPanel(onStop: { showStopRecordingConfirm = true }) }
            Spacer()
            if showCoverage {
                CoverageLegend(note: coverageNote)
            }
            HStack(alignment: .bottom) {
                secondaryControls
                Spacer()
                controls
            }
            ActionBar(onRecordTap: toggleRecording)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func withSheets<V: View>(_ v: V) -> some View {
        v
        .sheet(item: $router.mapSheet) { sheet in sheetContent(sheet) }
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
        .onChange(of: mapManager.visibleRegion?.center.latitude) { _, _ in refreshCommunity(); refreshDirt() }
        .onChange(of: mapManager.visibleRegion?.center.longitude) { _, _ in refreshCommunity(); refreshDirt() }
        .onChange(of: mapManager.visibleRegion?.span.latitudeDelta) { _, _ in refreshDirt() }
        .onChange(of: dirt.revision) { _, _ in refreshDirt() }
        .onChange(of: mapManager.visibleRegion?.center.latitude) { _, _ in refreshCoverage() }
        .onChange(of: mapManager.visibleRegion?.span.latitudeDelta) { _, _ in refreshCoverage() }
        .onChange(of: showCoverage) { _, _ in refreshCoverage() }
        .onChange(of: coverageOnlyMine) { _, _ in refreshCoverage() }
        .onChange(of: coverage.cells.count) { _, _ in refreshCoverage(fetch: false) }
        .onChange(of: showDirtRoads) { _, _ in refreshDirt() }
        .onChange(of: showDetectedRoads) { _, _ in refreshDirt() }
        .onChange(of: mapManager.pickedCoordinate?.latitude) { _, new in
            if new != nil { showPickedOptions = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await follow.refresh() }
        }
        .task {
            // متابعة الرحلات الآمنة لمن أضافوني: كل 5 دقائق أثناء فتح التطبيق
            while !Task.isCancelled {
                await follow.refresh()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    private func withPinDialogs<V: View>(_ v: V) -> some View {
        v
        .confirmationDialog("نقطة محددة", isPresented: $showPickedOptions, titleVisibility: .visible) {
            if let c = mapManager.pickedCoordinate {
                Button("حفظ الموقع") { router.mapSheet = .savePlace(c) }
                Button("الملاحة إلى هذه النقطة") {
                    navigation.navigate(to: Waypoint(name: "نقطة محددة", coordinate: c))
                    mapManager.pickedCoordinate = nil
                }
                Button("إضافة إلى مخطط المسار") {
                    router.plannerDraft.waypoints.append(Waypoint(name: "نقطة \(router.plannerDraft.waypoints.count + 1)", coordinate: c))
                    mapManager.pickedCoordinate = nil
                    router.mapSheet = .routePlanner
                }
                Button("نسخ الإحداثيات") {
                    UIPasteboard.general.string = CoordinateUtilities.shareString(c)
                    mapManager.pickedCoordinate = nil
                }
                Button("إلغاء", role: .cancel) { mapManager.pickedCoordinate = nil }
            }
        } message: {
            if let c = mapManager.pickedCoordinate {
                Text(CoordinateUtilities.format(c, as: .decimal))
            }
        }
        .confirmationDialog(selectedPinTitle, isPresented: pinDialogShown,
                            titleVisibility: .visible, presenting: mapManager.selectedPin) { (pin: MapOverlaySet.Pin) in
            pinActions(pin)
        } message: { (pin: MapOverlaySet.Pin) in
            Text(pinMessage(pin))
        }
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
                           markerStyle: markerStyle, markerColor: markerColor)
                .overlay(nightDim)
        } else if mapManager.layer == .offline {
            OfflineMapView(styleURL: offlineMaps.activeStyleURL, overlays: overlays, mapManager: mapManager, highlightDirtRoads: true,
                           dirtRoads: dirtRoads, coverageCells: coverageCells, markerStyle: markerStyle, markerColor: markerColor)
                .overlay(nightDim)
        } else {
            OnlineMapView(overlays: overlays, mapManager: mapManager, dirtRoads: dirtRoads, dirtLabels: dirtLabels,
                          coverageCells: coverageCells, userCoordinate: location.location?.coordinate, userHeading: userHeading,
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

    private var controls: some View {
        VStack(spacing: 10) {
            Menu {
                Picker("طبقة الخريطة", selection: $mapManager.layer) {
                    ForEach(MapLayer.allCases) { l in
                        Label(l.title, systemImage: l.icon).tag(l)
                    }
                }
                Divider()
                Toggle(isOn: $showLandmarks) { Label("أسماء الأماكن المعروفة", systemImage: "mappin.circle") }
                if community.isEnabled {
                    Toggle(isOn: $showCommunity) { Label("مشاركات المجتمع", systemImage: "person.2") }
                }
                Toggle(isOn: $showDirtRoads) { Label("الردميات والطرق الترابية", systemImage: "road.lanes") }
                if showDirtRoads {
                    Toggle(isOn: $showDetectedRoads) { Label("طرق مرصودة من الأقمار الصناعية", systemImage: "globe.asia.australia") }
                }
                Toggle(isOn: $showCoverage) { Label("تغطية الشبكة", systemImage: "antenna.radiowaves.left.and.right") }
                if showCoverage {
                    Toggle(isOn: $coverageOnlyMine) { Label("شركتي فقط", systemImage: "simcard") }
                }
                Divider()
                Button { requestCoverageReport() } label: { Label("بلّغ عن الشبكة في موقعي", systemImage: "exclamationmark.bubble") }
                Button { router.mapSheet = .safeTrip } label: {
                    Label(safeTrip.isActive ? "الرحلة الآمنة (مفعلة)" : "الرحلة الآمنة", systemImage: "shield.lefthalf.filled")
                }
                Button { router.mapSheet = .following } label: {
                    Label(follow.activeTrips.isEmpty ? "أتابعهم" : "أتابعهم (\(follow.activeTrips.count))", systemImage: "person.2.wave.2")
                }
                Button { router.mapSheet = .emergency } label: { Label("الطوارئ وإنجاد", systemImage: "sos") }
                Button { sendLocation() } label: { Label("إرسال موقعي برسالة", systemImage: "message") }
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(Theme.brown)
                    .background(Circle().fill(.regularMaterial))
            }
            .accessibilityLabel("طبقة الخريطة")

            MapControlButton(systemImage: "plus", label: "تكبير") { mapManager.send(.zoomIn) }
            MapControlButton(systemImage: "minus", label: "تصغير") { mapManager.send(.zoomOut) }
            MapControlButton(systemImage: mapManager.followsUser ? "location.fill" : "location",
                             label: "موقعي الحالي", isActive: mapManager.followsUser) {
                mapManager.send(.centerOnUser)
            }
            MapControlButton(systemImage: "scope", label: "تحديد نقطة من الخريطة",
                             isActive: mapManager.isPickingPoint) {
                mapManager.isPickingPoint.toggle()
            }
        }
        .padding(.bottom, 8)
    }

    /// العمود الثاني: المنظور ثلاثي الأبعاد، مساراتي السابقة، والشمال.
    private var secondaryControls: some View {
        VStack(spacing: 10) {
            Button { mapManager.send(.pitch(!mapManager.is3D)) } label: {
                Text(mapManager.is3D ? "2D" : "3D")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .frame(width: 48, height: 48)
                    .foregroundStyle(mapManager.is3D ? Color.white : Theme.brown)
                    .background(Circle().fill(mapManager.is3D ? AnyShapeStyle(Theme.desertOrange) : AnyShapeStyle(.regularMaterial)))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            }
            .accessibilityLabel(mapManager.is3D ? "عرض مسطح" : "عرض ثلاثي الأبعاد")
            MapControlButton(systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                             label: showMyTracks ? "إخفاء مساراتي السابقة" : "عرض كل مساراتي السابقة",
                             isActive: showMyTracks) {
                showMyTracks.toggle()
                if showMyTracks, !myTracks.isEmpty, mapManager.visibleRegion.map({ $0.span.latitudeDelta > 3 }) ?? true {
                    // تقريب على مكان المسارات إن كانت الخريطة بعيدة
                    let pts = myTracks.prefix(30).compactMap { $0.points.first?.coordinate }
                    if !pts.isEmpty { mapManager.send(.fit(pts)) }
                }
            }
            MapControlButton(systemImage: "location.north.line", label: "توجيه الخريطة للشمال") { mapManager.send(.resetNorth) }
        }
        .padding(.bottom, 8)
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
        Array(dirtRoads.filter { !$0.name.isEmpty && $0.coordinates.count > 1 }.prefix(30))
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

    @ViewBuilder
    private func pinActions(_ pin: MapOverlaySet.Pin) -> some View {
        Button("الملاحة إليه") {
            navigation.navigate(to: Waypoint(name: pin.title, coordinate: pin.coordinate))
            mapManager.selectedPin = nil
        }
        Button("طريق بالسيارة إن وُجد") {
            navigation.navigate(to: Waypoint(name: pin.title, coordinate: pin.coordinate), mode: .road)
            mapManager.selectedPin = nil
        }
        if pin.kind != .saved {
            Button("حفظ في أماكني") { router.mapSheet = .savePlace(pin.coordinate); mapManager.selectedPin = nil }
        }
        Button("إضافة إلى مخطط المسار") {
            router.plannerDraft.waypoints.append(Waypoint(name: pin.title, coordinate: pin.coordinate))
            mapManager.selectedPin = nil
            router.mapSheet = .routePlanner
        }
        Button("نسخ الإحداثيات") {
            UIPasteboard.general.string = CoordinateUtilities.shareString(pin.coordinate)
            mapManager.selectedPin = nil
        }
        Button("مشاركة الموقع") {
            shareLocationText = pin.title + "\n" + CoordinateUtilities.shareString(pin.coordinate)
            mapManager.selectedPin = nil
        }
        Button("إلغاء", role: .cancel) { mapManager.selectedPin = nil }
    }

    private func pinMessage(_ pin: MapOverlaySet.Pin) -> String {
        var parts: [String] = []
        if let s = pin.subtitle, !s.isEmpty { parts.append(s) }
        if let here = location.location?.coordinate {
            parts.append("\(Fmt.distance(GeoMath.distance(here, pin.coordinate))) · \(Fmt.bearing(GeoMath.bearing(from: here, to: pin.coordinate)))")
        }
        parts.append(CoordinateUtilities.format(pin.coordinate, as: .decimal))
        return parts.joined(separator: "\n")
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
