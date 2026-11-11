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
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]

    @State private var showPickedOptions = false
    @State private var showStopRecordingConfirm = false

    private var overlays: MapOverlaySet {
        MapOverlaySet.build(places: places,
                            liveSegments: recorder.liveSegments,
                            navigation: navigation.snapshot,
                            currentLocation: location.location?.coordinate,
                            picked: mapManager.pickedCoordinate)
    }

    var body: some View {
        ZStack {
            mapLayer.ignoresSafeArea(edges: [.top, .horizontal])

            VStack(spacing: 8) {
                StatusHUD()
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
        if mapManager.layer == .offline {
            OfflineMapView(styleURL: offlineMaps.activeStyleURL, overlays: overlays, mapManager: mapManager)
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
        if let n = recorder.recoveredNotice {
            Banner(icon: "arrow.uturn.backward.circle", text: n, actionTitle: "حسنًا", tint: Theme.brown) { recorder.clearRecoveredNotice() }
        }
        if let msg = location.lastError, location.isAuthorized {
            Banner(icon: "exclamationmark.circle", text: msg, tint: .orange)
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
