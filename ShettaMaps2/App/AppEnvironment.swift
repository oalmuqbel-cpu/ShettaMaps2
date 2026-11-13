import Foundation
import SwiftData
import OSLog

enum SettingsKeys {
    static let highContrast = "highContrast"
    static let coordinateFormat = "coordinateFormat"
    static let batteryMode = "batteryMode"
    static let autoRecordTrips = "autoRecordTrips"
    static let iCloudSync = "iCloudSync"
    static let offlineStyleURL = "offlineStyleURL"
    static let preferOfflineMap = "preferOfflineMap"
    static let mapLayer = "mapLayer"
    static let useRoadRouting = "useRoadRouting"
    static let didSeedCategories = "didSeedCategories"
    static let weakGPSThreshold = "weakGPSThreshold"
    static let showLandmarks = "showLandmarks"
    static let showCommunity = "showCommunity"
    static let landmarkKinds = "landmarkKinds"
    static let autoPauseMinutes = "autoPauseMinutes"
    static let sunsetReminder = "sunsetReminder"
    static let emergencyNumber = "emergencyNumber"
}

let appLog = Logger(subsystem: "com.almuqbel.ShettaMaps2", category: "app")

/// الحاوية المشتركة لكل مشاهد التطبيق (الآيفون/الآيباد وCarPlay) حتى تتطابق البيانات.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let container: ModelContainer
    /// رسالة توضح سبب العودة للتخزين المحلي إذا فشل تفعيل iCloud.
    private(set) var storageNotice: String?
    let isCloudSyncActive: Bool

    let location = LocationManager.shared
    let navigation = SharedNavigationState.shared
    let recorder: RouteRecordingManager
    let trips: TripManager
    let network = NetworkMonitor.shared
    let offlineMaps = OfflineMapManager.shared

    private init() {
        let schema = Schema(AppSchema.models)
        let wantsCloud = UserDefaults.standard.bool(forKey: SettingsKeys.iCloudSync)
        var made: ModelContainer?
        var cloud = false

        if wantsCloud {
            do {
                let config = ModelConfiguration("ShettaMaps2", schema: schema,
                                                cloudKitDatabase: .private("iCloud.com.almuqbel.ShettaMaps2"))
                made = try ModelContainer(for: schema, configurations: config)
                cloud = true
            } catch {
                appLog.error("CloudKit container failed: \(error.localizedDescription)")
                storageNotice = "تعذّر تفعيل مزامنة iCloud، ويعمل التطبيق بالتخزين المحلي. تأكد من إضافة قدرة iCloud وتسجيل الدخول."
            }
        }
        if made == nil {
            do {
                let config = ModelConfiguration("ShettaMaps2", schema: schema, cloudKitDatabase: .none)
                made = try ModelContainer(for: schema, configurations: config)
            } catch {
                // آخر حل: تخزين في الذاكرة حتى لا يتوقف التطبيق، مع إشعار المستخدم.
                appLog.fault("Local store failed: \(error.localizedDescription)")
                storageNotice = "تعذّر فتح قاعدة البيانات المحلية. لن تُحفظ التغييرات بعد إغلاق التطبيق."
                made = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
        }
        let finalContainer = made!
        container = finalContainer
        isCloudSyncActive = cloud

        let loc = LocationManager.shared
        let nav = SharedNavigationState.shared
        let rec = RouteRecordingManager(context: finalContainer.mainContext, location: loc)
        recorder = rec
        trips = TripManager(context: finalContainer.mainContext, recorder: rec, navigation: nav, location: loc)
        nav.attach(location: loc)
        seedIfNeeded()
        recorder.recoverUnfinishedTrackIfNeeded()
    }

    private func seedIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: SettingsKeys.didSeedCategories) else { return }
        let ctx = container.mainContext
        let existing = (try? ctx.fetchCount(FetchDescriptor<PlaceCategory>())) ?? 0
        if existing == 0 {
            for (i, c) in PlaceCategory.defaults.enumerated() {
                ctx.insert(PlaceCategory(name: c.0, iconName: c.1, colorHex: c.2, sortOrder: i))
            }
            try? ctx.save()
        }
        defaults.set(true, forKey: SettingsKeys.didSeedCategories)
    }
}
