import UIKit
import CarPlay

/// مشهد CarPlay الرئيسي لتطبيق ملاحة (يتطلب صلاحية com.apple.developer.carplay-maps من Apple).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var manager: CarPlayTemplateManager?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController,
                                  to window: CPWindow) {
        MainActor.assumeIsolated {
            AppEnvironment.shared.location.start()
            manager = CarPlayTemplateManager(interfaceController: interfaceController, window: window)
            CarPlayConnectionMonitor.shared.carPlayConnected()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController,
                                  from window: CPWindow) {
        MainActor.assumeIsolated {
            manager?.disconnect()
            manager = nil
            window.rootViewController = nil
            CarPlayConnectionMonitor.shared.carPlayDisconnected()
        }
    }
}

/// لوحة CarPlay (Dashboard): خريطة مصغّرة مع اختصارات، تظهر بجانب تطبيقات أخرى.
final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    private var mapController: CarPlayMapViewController?

    func templateApplicationDashboardScene(_ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
                                           didConnect dashboardController: CPDashboardController,
                                           to window: UIWindow) {
        MainActor.assumeIsolated {
            let vc = CarPlayMapViewController(role: .dashboard)
            window.rootViewController = vc
            mapController = vc
            dashboardController.shortcutButtons = makeShortcuts(scene: templateApplicationDashboardScene)
            CarPlayConnectionMonitor.shared.setDashboard(true)
        }
    }

    func templateApplicationDashboardScene(_ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
                                           didDisconnect dashboardController: CPDashboardController,
                                           from window: UIWindow) {
        MainActor.assumeIsolated {
            window.rootViewController = nil
            mapController = nil
            CarPlayConnectionMonitor.shared.setDashboard(false)
        }
    }

    @MainActor
    private func makeShortcuts(scene: UIScene) -> [CPDashboardButton] {
        let env = AppEnvironment.shared
        let home = CPDashboardButton(titleVariants: ["العودة للبداية"], subtitleVariants: ["الرحلة النشطة"],
                                     image: UIImage(systemName: "arrow.uturn.backward.circle.fill") ?? UIImage()) { _ in
            MainActor.assumeIsolated {
                _ = env.trips.returnToStart()
                Self.openApp(scene)
            }
        }
        let destinations = CPDashboardButton(titleVariants: ["الوجهات"], subtitleVariants: ["المواقع المحفوظة"],
                                             image: UIImage(systemName: "mappin.and.ellipse") ?? UIImage()) { _ in
            Self.openApp(scene)
        }
        return [home, destinations]
    }

    /// يفتح واجهة التطبيق الكاملة على CarPlay.
    private static func openApp(_ scene: UIScene) {
        if let url = URL(string: "shettamaps2://carplay") {
            scene.open(url, options: nil, completionHandler: nil)
        }
    }
}

/// شاشة العدادات خلف المقود (في السيارات الداعمة فقط).
final class CarPlayInstrumentClusterSceneDelegate: UIResponder, CPTemplateApplicationInstrumentClusterSceneDelegate,
                                                   CPInstrumentClusterControllerDelegate {
    private var mapController: CarPlayMapViewController?

    func templateApplicationInstrumentClusterScene(_ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
                                                   didConnect instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated {
            instrumentClusterController.delegate = self
            instrumentClusterController.inactiveDescriptionVariants = ["سَمْت"]
            CarPlayConnectionMonitor.shared.setInstrumentCluster(true)
        }
    }

    func templateApplicationInstrumentClusterScene(_ templateApplicationInstrumentClusterScene: CPTemplateApplicationInstrumentClusterScene,
                                                   didDisconnectInstrumentClusterController instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated {
            mapController = nil
            CarPlayConnectionMonitor.shared.setInstrumentCluster(false)
        }
    }

    func instrumentClusterControllerDidConnect(_ instrumentClusterWindow: UIWindow) {
        MainActor.assumeIsolated {
            let vc = CarPlayMapViewController(role: .cluster)
            instrumentClusterWindow.rootViewController = vc
            mapController = vc
        }
    }

    func instrumentClusterControllerDidDisconnectWindow(_ instrumentClusterWindow: UIWindow) {
        MainActor.assumeIsolated {
            instrumentClusterWindow.rootViewController = nil
            mapController = nil
        }
    }

    func instrumentClusterControllerDidZoom(in instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated { mapController?.zoom(in: true) }
    }

    func instrumentClusterControllerDidZoomOut(_ instrumentClusterController: CPInstrumentClusterController) {
        MainActor.assumeIsolated { mapController?.zoom(in: false) }
    }
}
