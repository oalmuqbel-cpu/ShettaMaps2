import SwiftUI

/// يختار التخطيط: شريط تبويبات للآيفون، وتخطيط متعدد الأعمدة للآيباد.
struct RootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var location: LocationManager

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular {
                PadRootView()
            } else {
                PhoneRootView()
            }
        }
        .onAppear { location.start() }
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
    @State private var columns: NavigationSplitViewVisibility = .all

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
            .navigationTitle("خرائط شتة 2")
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
        } detail: {
            MapScreen()
        }
        .navigationSplitViewStyle(.balanced)
    }
}
