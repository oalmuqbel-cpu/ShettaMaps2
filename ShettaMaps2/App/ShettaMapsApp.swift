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
        }
        return true
    }
}
