import SwiftUI
import SwiftData

@main
struct ShettaMapsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let env = AppEnvironment.shared
    @StateObject private var router = AppRouter()
    @StateObject private var mapManager = MapManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(env.location)
                .environmentObject(env.navigation)
                .environmentObject(env.recorder)
                .environmentObject(env.trips)
                .environmentObject(env.network)
                .environmentObject(env.offlineMaps)
                .environmentObject(SearchService.shared)
                .environmentObject(CarPlayConnectionMonitor.shared)
                .environmentObject(router)
                .environmentObject(mapManager)
                // واجهة عربية بالكامل من اليمين إلى اليسار بغض النظر عن لغة الجهاز
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
                .tint(Theme.desertOrange)
                .onOpenURL { url in router.handleIncomingFile(url) }
        }
        .modelContainer(env.container)
    }
}

/// مندوب التطبيق: تهيئة مبكرة للخدمات لتعمل عند تشغيل التطبيق مباشرة من CarPlay دون فتح الهاتف.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            _ = AppEnvironment.shared
            AppEnvironment.shared.location.start()
            Self.startDemoNavigationIfRequested()
        }
        return true
    }

    /// لالتقاط لقطات الشاشة آليًا فقط: يبدأ ملاحة تجريبية عند تمرير الوسيط -DemoNavigation.
    @MainActor
    private static func startDemoNavigationIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-DemoNavigation") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated {
                let env = AppEnvironment.shared
                guard let c = env.location.location?.coordinate else { return }
                // مواقع عامة تجريبية حول الموقع الحالي لتظهر في قائمة الوجهات أثناء التقاط اللقطات
                let ctx = env.container.mainContext
                if ((try? ctx.fetchCount(FetchDescriptor<SavedPlace>())) ?? 0) == 0 {
                    for (name, d, b, fav) in [("المخيم", 9_000.0, 60.0, true), ("نقطة التزود", 4_200.0, 200.0, false),
                                              ("نقطة البداية", 1_500.0, 300.0, true), ("الاستراحة", 12_000.0, 120.0, false)] {
                        let p = SavedPlace(name: name, coordinate: GeoMath.destination(from: c, distance: d, bearing: b))
                        p.isFavorite = fav
                        ctx.insert(p)
                    }
                    try? ctx.save()
                }
                let stop = GeoMath.destination(from: c, distance: 3_500, bearing: 35)
                let dest = GeoMath.destination(from: c, distance: 9_000, bearing: 60)
                env.navigation.start(NavigationPlan(origin: Waypoint(name: "موقعي", coordinate: c),
                                                    waypoints: [Waypoint(name: "نقطة التوقف", coordinate: stop)],
                                                    destination: Waypoint(name: "المخيم", coordinate: dest),
                                                    mode: .direct))
            }
        }
    }
}
