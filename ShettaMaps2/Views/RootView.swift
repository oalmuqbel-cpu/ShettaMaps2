import SwiftUI

/// يختار التخطيط: شريط تبويبات للآيفون، وتخطيط متعدد الأعمدة للآيباد.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var location: LocationManager
    @State private var showSplash = true

    var body: some View {
        ZStack {
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular {
                    PadRootView()
                } else {
                    PhoneRootView()
                }
            }
            if showSplash {
                SplashView().transition(.opacity).zIndex(1)
            }
            #if DEBUG
            if GuideScreens.requested == "gauge" { GaugePreviewBoard().zIndex(2) }
            #endif
        }
        .onAppear { location.start() }
        .task {
            // وقت قصير تتجهز فيه الخريطة خلف الشاشة ثم تختفي بانسياب
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeInOut(duration: 0.4)) { showSplash = false }
        }
    }
}

struct PhoneRootView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedSection) {
            MapScreen()
                .tabItem { Label(AppSection.map.title, systemImage: AppSection.map.icon) }
                .tag(AppSection.map)
            NavigationStack { PlacesListView() }
                .tabItem { Label(AppSection.places.title, systemImage: AppSection.places.icon) }
                .tag(AppSection.places)
            NavigationStack { TracksListView() }
                .tabItem { Label(AppSection.tracks.title, systemImage: AppSection.tracks.icon) }
                .tag(AppSection.tracks)
            NavigationStack { TripsListView() }
                .tabItem { Label(AppSection.trips.title, systemImage: AppSection.trips.icon) }
                .tag(AppSection.trips)
            NavigationStack { SettingsView() }
                .tabItem { Label(AppSection.settings.title, systemImage: AppSection.settings.icon) }
                .tag(AppSection.settings)
        }
    }
}

/// الآيباد: الأقسام في الشريط الجانبي، القائمة والتفاصيل في العمود الأوسط، والخريطة دائمًا في العمود الأكبر.
struct PadRootView: View {
    @EnvironmentObject private var router: AppRouter
    /// تبدأ الخريطة بكامل الشاشة؛ القوائم تُفتح من زر الشريط الجانبي وتطفو فوق الخريطة.
    @State private var columns: NavigationSplitViewVisibility = .detailOnly

    private var listSections: [AppSection] { AppSection.allCases.filter { $0 != .map } }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: Binding<AppSection?>(
                get: { router.selectedSection == .map ? .places : router.selectedSection },
                set: { router.selectedSection = $0 ?? .places })) {
                ForEach(listSections) { s in
                    Label(s.title, systemImage: s.icon).tag(s)
                }
            }
            .navigationTitle("سَمْت")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } content: {
            NavigationStack {
                switch router.selectedSection {
                case .map, .places: PlacesListView()
                case .tracks: TracksListView()
                case .trips: TripsListView()
                case .offlineMaps: OfflineMapsView()
                case .settings: SettingsView()
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        } detail: {
            MapScreen()
        }
        // الخريطة لا تنضغط عند فتح القوائم، بل تبقى كاملة والقوائم فوقها
        .navigationSplitViewStyle(.prominentDetail)
        // فتح قسم من داخل التطبيق (مثل استيراد مسار) يُظهر قائمته
        .onChange(of: router.selectedSection) { _, s in
            if s != .map, columns == .detailOnly { withAnimation { columns = .doubleColumn } }
        }
    }
}

#if DEBUG
/// لقطات الشاشة فقط: عداد السرعة في حالاته المختلفة على خلفية خريطة.
private struct GaugePreviewBoard: View {
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                SpeedGauge(kmh: 0, limit: 60).frame(width: 150, height: 150)
                SpeedGauge(kmh: 72, limit: 80).frame(width: 150, height: 150)
            }
            HStack(spacing: 20) {
                SpeedGauge(kmh: 134, limit: 120, over: true).frame(width: 150, height: 150)
                SpeedGauge(kmh: 45, limit: nil, limitUnknown: true).frame(width: 120, height: 120)
            }
            SpeedGauge(kmh: nil, limit: nil).frame(width: 96, height: 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.55, green: 0.5, blue: 0.42))
    }
}
#endif
