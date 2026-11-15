import Foundation
import CoreLocation

/// الطبقات التي تُنزَّل مع أي خريطة دون إنترنت (منطقة أو ملف أقمار صناعية) حتى تعمل كلها معًا بلا اتصال.
/// الاختيارات محفوظة في الإعدادات ومشتركة بين الهاتف وCarPlay.
enum OfflineLayerOption: String, CaseIterable, Identifiable {
    case dirt, speed, community, coverage
    var id: String { rawValue }
    var key: String { "offlineInclude_\(rawValue)" }
    var title: String {
        switch self {
        case .dirt: return "الردميات والطرق الترابية"
        case .speed: return "حدود السرعة"
        case .community: return "مشاركات المجتمع (أماكن ومسارات)"
        case .coverage: return "تغطية الشبكة"
        }
    }
    var icon: String {
        switch self {
        case .dirt: return "road.lanes"
        case .speed: return "speedometer"
        case .community: return "person.2"
        case .coverage: return "antenna.radiowaves.left.and.right"
        }
    }
    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// ينزّل الخريطة والطبقات المرافقة لها في عملية واحدة.
@MainActor
final class OfflinePackageService: ObservableObject {
    static let shared = OfflinePackageService()

    /// وصف العملية الجارية لعرضه (مثل: «تنزيل الردميات»)، أو nil إن لا يوجد تنزيل للطبقات.
    @Published private(set) var layersStatus: String?

    private init() {}

    /// تنزيل منطقة: الخريطة الأساسية ثم الطبقات المختارة.
    func downloadRegion(name: String, sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D,
                        minZoom: Int, maxZoom: Int) async throws {
        try await OfflineMapManager.shared.download(name: name, sw: sw, ne: ne, minZoom: minZoom, maxZoom: maxZoom)
        await downloadLayers(sw: sw, ne: ne)
    }

    /// تنزيل منطقة بمستوى تكبير يُختار تلقائيًا ضمن حد المصدر (يُستخدم من شاشة السيارة).
    /// يعيد أعلى مستوى تكبير اختير.
    @discardableResult
    func downloadRegionAuto(name: String, sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async throws -> Int {
        let limit = Double(OfflineMapManager.shared.maxTilesPerRegion) * 0.9
        var maxZoom = 14
        while maxZoom > 8, Double(GeoMath.estimatedTileCount(sw: sw, ne: ne, minZoom: 6, maxZoom: maxZoom)) > limit {
            maxZoom -= 1
        }
        try await downloadRegion(name: name, sw: sw, ne: ne, minZoom: 6, maxZoom: maxZoom)
        return maxZoom
    }

    /// تنزيل الطبقات فقط لمنطقة (مثلًا حدود ملف أقمار صناعية مستورد).
    func downloadLayers(sw: CLLocationCoordinate2D, ne: CLLocationCoordinate2D) async {
        guard NetworkMonitor.shared.isOnline else { return }
        // المناطق الكبيرة جدًا تُقصر على ما يكفي للرحلة حتى لا يُستهلك التخزين بلا حاجة
        let latSpan = ne.latitude - sw.latitude, lonSpan = ne.longitude - sw.longitude
        guard latSpan > 0, lonSpan > 0 else { return }
        defer { layersStatus = nil }
        if OfflineLayerOption.dirt.isOn, latSpan <= 12, lonSpan <= 12 {
            layersStatus = "تنزيل الردميات"
            await DirtRoadsStore.shared.download(sw: sw, ne: ne)
        }
        if OfflineLayerOption.speed.isOn, latSpan <= 12, lonSpan <= 12 {
            layersStatus = "تنزيل حدود السرعة"
            await SpeedLimitStore.shared.download(sw: sw, ne: ne)
        }
        if OfflineLayerOption.community.isOn, CommunityService.shared.isEnabled, latSpan <= 6, lonSpan <= 6 {
            layersStatus = "تنزيل مشاركات المجتمع"
            await CommunityService.shared.refresh(sw: sw, ne: ne, force: true)
            await CommunityTrackStore.shared.refresh(sw: sw, ne: ne, force: true)
        }
        if OfflineLayerOption.coverage.isOn, latSpan <= 3, lonSpan <= 3 {
            layersStatus = "تنزيل تغطية الشبكة"
            await CoverageService.shared.refresh(sw: sw, ne: ne)
        }
    }
}
