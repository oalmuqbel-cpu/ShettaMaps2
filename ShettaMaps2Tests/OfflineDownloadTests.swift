import XCTest
import CoreLocation
import MapLibre
@testable import ShettaMaps2

/// اختبار تكامل: تنزيل منطقة صغيرة فعليًا من مصدر الخرائط الافتراضي ثم إيقافها واستئنافها وحذفها.
@MainActor
final class OfflineDownloadTests: XCTestCase {
    private let regionName = "اختبار-تنزيل"

    private func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            OfflineMapManager.shared.refreshRegions()
            if condition() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func testDownloadPauseResumeDelete() async throws {
        let m = OfflineMapManager.shared
        for r in m.regions where r.name == regionName { m.delete(r) }
        let sw = CLLocationCoordinate2D(latitude: 24.70, longitude: 46.65)
        let ne = CLLocationCoordinate2D(latitude: 24.73, longitude: 46.68)
        try m.download(name: regionName, sw: sw, ne: ne, minZoom: 9, maxZoom: 12)

        try await waitFor(30) { m.regions.contains { $0.name == regionName } }
        guard let started = m.regions.first(where: { $0.name == regionName }) else { return XCTFail("لم تظهر المنطقة") }

        // إيقاف ثم استئناف بنفس المعرّف
        if started.state == .downloading {
            m.toggle(started)
            try await waitFor(10) { m.regions.first { $0.id == started.id }?.state == .paused }
            XCTAssertEqual(m.regions.first { $0.id == started.id }?.state, .paused)
            m.toggle(started)
        }

        try await waitFor(180) { m.regions.first { $0.id == started.id }?.state == .complete }
        let done = m.regions.first { $0.id == started.id }
        XCTAssertEqual(done?.state, .complete, "الخطأ: \(m.lastError ?? "لا يوجد")")
        XCTAssertGreaterThan(done?.bytes ?? 0, 0)
        XCTAssertTrue(m.hasOfflineCoverage(at: CLLocationCoordinate2D(latitude: 24.715, longitude: 46.665)))

        // المعرّف ثابت بين مرات التحديث (كان سبب تعذّر الحذف)
        m.refreshRegions()
        XCTAssertEqual(m.regions.first { $0.name == regionName }?.id, started.id)

        if let done { m.delete(done) }
        try await waitFor(20) { !m.regions.contains { $0.id == started.id } }
        XCTAssertFalse(m.regions.contains { $0.id == started.id })
    }
}

/// الحزم القديمة المنزّلة بنمط demotiles تسبب انهيارًا عند استئنافها؛ يجب حذفها دون تشغيلها.
@MainActor
final class IncompatiblePackTests: XCTestCase {
    func testOldDemotilesPackIsRemovedWithoutResuming() async throws {
        let style = URL(string: "https://demotiles.maplibre.org/style.json")!
        let region = MLNTilePyramidOfflineRegion(styleURL: style,
                                                 bounds: MLNCoordinateBounds(sw: .init(latitude: 24.7, longitude: 46.6),
                                                                             ne: .init(latitude: 24.8, longitude: 46.7)),
                                                 fromZoomLevel: 6, toZoomLevel: 8)
        let added = expectation(description: "added")
        MLNOfflineStorage.shared.addPack(for: region, withContext: Data()) { _, error in
            XCTAssertNil(error); added.fulfill()     // لا يُستأنف: الإضافة وحدها لا تبدأ التنزيل
        }
        await fulfillment(of: [added], timeout: 10)

        func blockedCount() -> Int {
            (MLNOfflineStorage.shared.packs ?? []).filter {
                ($0.region as? MLNTilePyramidOfflineRegion)?.styleURL.host == "demotiles.maplibre.org"
            }.count
        }
        XCTAssertGreaterThan(blockedCount(), 0)
        let m = OfflineMapManager.shared
        m.refreshRegions()
        XCTAssertFalse(m.regions.contains { $0.styleURL.contains("demotiles") }, "لا تظهر في القائمة")
        XCTAssertGreaterThan(m.removeIncompatiblePacks(), 0)
        let deadline = Date().addingTimeInterval(10)
        while blockedCount() > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 300_000_000) }
        XCTAssertEqual(blockedCount(), 0)
    }
}
