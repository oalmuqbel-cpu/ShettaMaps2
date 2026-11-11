import XCTest
import SwiftData
import CoreLocation
@testable import ShettaMaps2

/// اختبارات الحفظ المحلي في SwiftData (حاوية في الذاكرة لا تمس بيانات الجهاز).
@MainActor
final class PersistenceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }

    override func setUp() async throws {
        let schema = Schema(AppSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testSaveEditDeletePlaceWithCategory() throws {
        let cat = PlaceCategory(name: "مخيمات", iconName: "tent")
        context.insert(cat)
        let place = SavedPlace(name: "مخيم", coordinate: .init(latitude: 25.1, longitude: 45.2), notes: "ملاحظة", category: cat)
        context.insert(place)
        try context.save()

        var fetched = try context.fetch(FetchDescriptor<SavedPlace>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].category?.name, "مخيمات")
        XCTAssertEqual(cat.places?.count, 1)

        fetched[0].coordinate = .init(latitude: 25.5, longitude: 45.5)
        fetched[0].name = "مخيم معدل"
        try context.save()
        fetched = try context.fetch(FetchDescriptor<SavedPlace>())
        XCTAssertEqual(fetched[0].latitude, 25.5)
        XCTAssertEqual(fetched[0].name, "مخيم معدل")

        // حذف التصنيف لا يحذف الموقع (nullify)
        context.delete(cat)
        try context.save()
        fetched = try context.fetch(FetchDescriptor<SavedPlace>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].category)

        context.delete(fetched[0])
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SavedPlace>()), 0)
    }

    func testTrackPointsRoundTrip() throws {
        let track = RecordedTrack(name: "مسار")
        let pts = (0..<500).map { i in
            TrackPoint(lat: 24 + Double(i) * 1e-4, lon: 46, alt: 600, time: Date(timeIntervalSince1970: Double(i)), speed: 5, hAcc: 4, segment: i / 250)
        }
        track.points = pts
        track.isComplete = true
        context.insert(track)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<RecordedTrack>()).first
        XCTAssertEqual(fetched?.pointCount, 500)
        XCTAssertEqual(fetched?.points, pts)
        XCTAssertEqual(TrackAccumulator.segments(of: fetched?.points ?? []).count, 2)
    }

    func testTripStopsAndRelationship() throws {
        let trip = Trip(name: "رحلة")
        trip.stops = [Waypoint(name: "1", coordinate: .init(latitude: 24, longitude: 46)),
                      Waypoint(name: "2", coordinate: .init(latitude: 24.1, longitude: 46.1))]
        let track = RecordedTrack(name: "م")
        track.distanceMeters = 1500
        track.trip = trip
        context.insert(trip); context.insert(track)
        try context.save()

        let t = try context.fetch(FetchDescriptor<Trip>()).first
        XCTAssertEqual(t?.stops.map(\.name), ["1", "2"])
        XCTAssertEqual(t?.totalDistance ?? 0, 1500, accuracy: 0.001)
    }

    /// دورة حياة التسجيل كاملة بمواقع مُحاكاة: بدء، إيقاف مؤقت، استئناف، إنهاء وحفظ.
    func testRecorderLifecycle() async throws {
        let location = LocationManager.shared
        let rec = RouteRecordingManager(context: context, location: location)
        rec.start(name: "اختبار")
        XCTAssertEqual(rec.state, .recording)

        let base = Date()
        func send(_ i: Int, lat: Double) {
            location.locationPublisher.send(CLLocation(coordinate: .init(latitude: lat, longitude: 46), altitude: 600,
                                                       horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 11,
                                                       timestamp: base.addingTimeInterval(Double(i) * 10)))
        }
        for i in 0..<5 { send(i, lat: 24 + Double(i) * 0.001) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rec.distance, 4 * 111.2, accuracy: 3)

        rec.pause()
        XCTAssertEqual(rec.state, .paused)
        send(5, lat: 24.01) // يُتجاهل أثناء الإيقاف المؤقت
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rec.distance, 4 * 111.2, accuracy: 3)

        rec.resume()
        send(6, lat: 24.02)
        send(7, lat: 24.021)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(rec.liveSegments.count, 2)

        let saved = rec.finish()
        XCTAssertEqual(rec.state, .idle)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.isComplete, true)
        XCTAssertEqual(saved?.pointCount, 7)
        XCTAssertEqual(saved?.distanceMeters ?? 0, 5 * 111.2, accuracy: 4)
    }

    func testRecoveryOfUnfinishedTrack() throws {
        let t = RecordedTrack(name: "غير مكتمل")
        t.points = [TrackPoint(lat: 24, lon: 46, time: Date()), TrackPoint(lat: 24.01, lon: 46, time: Date().addingTimeInterval(60))]
        t.isComplete = false
        context.insert(t)
        try context.save()

        let rec = RouteRecordingManager(context: context, location: LocationManager.shared)
        rec.recoverUnfinishedTrackIfNeeded()
        XCTAssertEqual(t.isComplete, true)
        XCTAssertNotNil(rec.recoveredNotice)
    }

    func testBackupRoundTrip() throws {
        let cat = PlaceCategory(name: "جبال")
        context.insert(cat)
        context.insert(SavedPlace(name: "جبل", coordinate: .init(latitude: 24, longitude: 46), category: cat))
        let track = RecordedTrack(name: "مسار")
        track.points = [TrackPoint(lat: 24, lon: 46, time: Date(timeIntervalSince1970: 0)),
                        TrackPoint(lat: 24.01, lon: 46, time: Date(timeIntervalSince1970: 60))]
        track.isComplete = true
        context.insert(track)
        try context.save()

        let url = try BackupService.makeBackup(context: context)

        // استعادة في حاوية جديدة فارغة
        let other = try ModelContainer(for: Schema(AppSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let summary = try BackupService.restore(from: url, context: other.mainContext)
        XCTAssertEqual(summary.places, 1)
        XCTAssertEqual(summary.tracks, 1)
        let restored = try other.mainContext.fetch(FetchDescriptor<SavedPlace>())
        XCTAssertEqual(restored.first?.category?.name, "جبال")
        XCTAssertEqual(try other.mainContext.fetch(FetchDescriptor<RecordedTrack>()).first?.pointCount, 2)

        // الاستعادة مرة ثانية لا تكرر العناصر
        let again = try BackupService.restore(from: url, context: other.mainContext)
        XCTAssertEqual(again.places, 0)
        XCTAssertEqual(again.skipped, 2)
    }
}
