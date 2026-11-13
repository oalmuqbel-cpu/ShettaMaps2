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
    @State private var showStopRecordingConfirm = false

    private var overlays: MapOverlaySet {
        MapOverlaySet.build(places: places,
                            liveSegments: recorder.liveSegments,
                            navigation: navigation.snapshot,
                            currentLocation: location.location?.coordinate,
                            picked: mapManager.pickedCoordinate,
                            extraPins: landmarkPins + communityPins + shownTrackPins,
                            extraLines: (router.shownTrack?.segments ?? []).map { .init(kind: .importedTrack, coordinates: $0) }
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
        ZStack {
            mapLayer.ignoresSafeArea(edges: [.top, .horizontal])

            VStack(spacing: 8) {
                StatusHUD()
                if showLandmarks && !navigation.snapshot.isNavigating && !mapManager.isPickingPoint { placeFilterBar }
                banners
                if navigation.snapshot.isNavigating { NavigationPanel() }
                if recorder.isActive { RecordingPanel(onStop: { showStopRecordingConfirm = true }) }
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    controls
                }
                ActionBar(onRecordTap: toggleRecording)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if showLandmarks || showCommunity {
                VStack {
                    Spacer()
                    HStack {
                        Text("بيانات الأماكن: © OpenStreetMap contributors")
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
        .onChange(of: mapManager.visibleRegion?.center.latitude) { _, _ in refreshCommunity() }
        .onChange(of: mapManager.visibleRegion?.center.longitude) { _, _ in refreshCommunity() }
        .onChange(of: mapManager.pickedCoordinate?.latitude) { _, new in
            if new != nil { showPickedOptions = true }
        }
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
                           highlightDirtRoads: true)
        } else if mapManager.layer == .offline {
            OfflineMapView(styleURL: offlineMaps.activeStyleURL, overlays: overlays, mapManager: mapManager, highlightDirtRoads: true)
        } else {
            OnlineMapView(overlays: overlays, mapManager: mapManager)
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
                Divider()
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
            MapControlButton(systemImage: "location.north.line", label: "توجيه الخريطة للشمال") { mapManager.send(.resetNorth) }
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

    private func refreshCommunity() {
        guard showCommunity, community.isEnabled, network.isOnline,
              let b = mapManager.visibleBounds, let r = mapManager.visibleRegion, r.span.latitudeDelta < 4 else { return }
        Task {
            await community.refresh(sw: b.sw, ne: b.ne)
            await communityTracks.refresh(sw: b.sw, ne: b.ne)
        }
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
