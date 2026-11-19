import XCTest
import CoreLocation
@testable import ShettaMaps2

/// اختبارات منطق السرعة والإرشاد المستخدم في الهاتف وCarPlay.
final class OverspeedMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testNoAlertWithoutLimitData() {
        var m = OverspeedMonitor()
        for i in 0..<10 { XCTAssertNil(m.update(limit: nil, speedKmh: 180, at: at(Double(i)))) }
        XCTAssertFalse(m.isOver)
    }

    func testMarginControlsAlertTimingOnly() {
        var m = OverspeedMonitor(margin: 10)
        // ١٠٨ على طريق حده ١٠٠ وهامش ١٠: لا تنبيه
        for i in 0..<5 { XCTAssertNil(m.update(limit: 100, speedKmh: 108, at: at(Double(i)))) }
        XCTAssertFalse(m.isOver)
        // ١١٢ لمدة ثانيتين: تنبيه بالحد النظامي نفسه (١٠٠) وليس بالحد + الهامش
        XCTAssertNil(m.update(limit: 100, speedKmh: 112, at: at(10)))
        XCTAssertNil(m.update(limit: 100, speedKmh: 112, at: at(11)))
        XCTAssertEqual(m.update(limit: 100, speedKmh: 112, at: at(12)), .alert(limit: 100))
        XCTAssertTrue(m.isOver)
    }

    func testShortSpikeDoesNotAlert() {
        var m = OverspeedMonitor(margin: 5)
        XCTAssertNil(m.update(limit: 80, speedKmh: 95, at: at(0)))
        XCTAssertNil(m.update(limit: 80, speedKmh: 95, at: at(1)))
        XCTAssertNil(m.update(limit: 80, speedKmh: 70, at: at(1.5)))
        XCTAssertNil(m.update(limit: 80, speedKmh: 95, at: at(2.5)))
        XCTAssertFalse(m.isOver)
    }

    func testSingleAlertPerEpisodeAndNoRepeatWhileOscillating() {
        var m = OverspeedMonitor(margin: 5, sustain: 2, cooldown: 30)
        var alerts = 0
        // يتذبذب حول عتبة التنبيه دون النزول تحت الحد النظامي لمدة دقيقة
        for i in 0..<60 {
            let v: Double = i % 4 < 2 ? 130 : 123   // الحد ١٢٠: فوق العتبة ثم بين الحد والعتبة
            if m.update(limit: 120, speedKmh: v, at: at(Double(i))) != nil { alerts += 1 }
        }
        XCTAssertLessThanOrEqual(alerts, 1)
    }

    func testCooldownAfterEpisodeEnds() {
        var m = OverspeedMonitor(margin: 0, sustain: 2, cooldown: 30)
        XCTAssertNil(m.update(limit: 100, speedKmh: 110, at: at(0)))
        XCTAssertEqual(m.update(limit: 100, speedKmh: 110, at: at(2)), .alert(limit: 100))
        XCTAssertNil(m.update(limit: 100, speedKmh: 90, at: at(5)))     // انتهى التجاوز
        XCTAssertNil(m.update(limit: 100, speedKmh: 110, at: at(10)))
        XCTAssertNil(m.update(limit: 100, speedKmh: 110, at: at(12)))   // داخل المهلة: بلا تكرار
        XCTAssertNil(m.update(limit: 100, speedKmh: 90, at: at(15)))
        XCTAssertNil(m.update(limit: 100, speedKmh: 110, at: at(40)))
        XCTAssertEqual(m.update(limit: 100, speedKmh: 110, at: at(42)), .alert(limit: 100))   // بعد المهلة
    }

    /// الانتقال بين طرق بحدود مختلفة.
    func testEnteringLowerLimitRoadWhileOverAlertsOnceForNewLimit() {
        var m = OverspeedMonitor(margin: 5)
        XCTAssertNil(m.update(limit: 120, speedKmh: 130, at: at(0)))
        XCTAssertEqual(m.update(limit: 120, speedKmh: 130, at: at(2)), .alert(limit: 120))
        // دخول طريق حده ٨٠ بنفس السرعة: تنبيه فوري واحد للحد الجديد
        XCTAssertEqual(m.update(limit: 80, speedKmh: 128, at: at(3)), .alert(limit: 80))
        XCTAssertNil(m.update(limit: 80, speedKmh: 128, at: at(4)))
        XCTAssertNil(m.update(limit: 80, speedKmh: 128, at: at(10)))
    }

    func testEnteringHigherLimitRoadClearsOverState() {
        var m = OverspeedMonitor(margin: 5)
        _ = m.update(limit: 80, speedKmh: 100, at: at(0))
        XCTAssertEqual(m.update(limit: 80, speedKmh: 100, at: at(2)), .alert(limit: 80))
        XCTAssertNil(m.update(limit: 120, speedKmh: 100, at: at(3)))
        XCTAssertFalse(m.isOver)
    }

    /// فقد GPS: لا تجاوز معروض، ولا تنبيه مكرر عند عودة الإشارة لنفس التجاوز.
    func testGPSLossClearsDisplayWithoutRepeatingAlert() {
        var m = OverspeedMonitor(margin: 5)
        _ = m.update(limit: 100, speedKmh: 120, at: at(0))
        XCTAssertEqual(m.update(limit: 100, speedKmh: 120, at: at(2)), .alert(limit: 100))
        XCTAssertNil(m.update(limit: 100, speedKmh: nil, at: at(3)))
        XCTAssertFalse(m.isOver)
        XCTAssertNil(m.update(limit: 100, speedKmh: 120, at: at(8)))
        XCTAssertNil(m.update(limit: 100, speedKmh: 120, at: at(10)))
        XCTAssertTrue(m.isOver)
    }

    func testMarginOptionsAndText() {
        XCTAssertEqual(SpeedAlertSettings.marginOptions, [0, 5, 10, 15, 20])
        XCTAssertTrue(SpeedAlertSettings.marginText(10).contains("10"))
    }
}

final class SpeedLimitMatcherTests: XCTestCase {
    // طريق يتجه شرقًا عند خط عرض ٢٥
    private let east = [CLLocationCoordinate2D(latitude: 25, longitude: 46.0), CLLocationCoordinate2D(latitude: 25, longitude: 46.01)]
    // طريق يتجه شمالًا يتقاطع معه
    private let north = [CLLocationCoordinate2D(latitude: 24.995, longitude: 46.005), CLLocationCoordinate2D(latitude: 25.005, longitude: 46.005)]
    private let here = CLLocationCoordinate2D(latitude: 25.00005, longitude: 46.005)

    func testDirectionSelectsForwardOrBackwardLimit() {
        let road = SpeedLimitMatcher.Road(forward: 120, backward: 100, oneway: false, name: "طريق", points: east)
        XCTAssertEqual(SpeedLimitMatcher.best(at: here, course: 90, roads: [road])?.limit, 120)
        XCTAssertEqual(SpeedLimitMatcher.best(at: here, course: 270, roads: [road])?.limit, 100)
    }

    func testOnewayAgainstDirectionIsIgnored() {
        let road = SpeedLimitMatcher.Road(forward: 120, backward: 120, oneway: true, name: nil, points: east)
        XCTAssertNil(SpeedLimitMatcher.best(at: here, course: 270, roads: [road]))
    }

    func testCrossingRoadIsNotMatchedAtIntersection() {
        let main = SpeedLimitMatcher.Road(forward: 120, backward: 120, oneway: false, name: "رئيسي", points: east)
        let cross = SpeedLimitMatcher.Road(forward: 60, backward: 60, oneway: false, name: "فرعي", points: north)
        // عند التقاطع ونحن نتجه شرقًا: حد الطريق الرئيسي وليس الفرعي
        let r = SpeedLimitMatcher.best(at: CLLocationCoordinate2D(latitude: 25, longitude: 46.005), course: 88, roads: [cross, main])
        XCTAssertEqual(r?.limit, 120)
        XCTAssertEqual(r?.name, "رئيسي")
    }

    func testTooFarFromRoadMeansUnknown() {
        let road = SpeedLimitMatcher.Road(forward: 80, backward: 80, oneway: false, name: nil, points: east)
        let far = CLLocationCoordinate2D(latitude: 25.001, longitude: 46.005)   // ~١١٠ م
        XCTAssertNil(SpeedLimitMatcher.best(at: far, course: 90, roads: [road]))
    }

    func testMissingLimitValueIsNotGuessed() {
        let road = SpeedLimitMatcher.Road(forward: 0, backward: 0, oneway: false, name: nil, points: east)
        XCTAssertNil(SpeedLimitMatcher.best(at: here, course: 90, roads: [road]))
    }
}

final class LiveSpeedTests: XCTestCase {
    func testStaleOrInaccurateSpeedIsNotLive() {
        let now = Date()
        let fresh = CLLocation(coordinate: .init(latitude: 25, longitude: 46), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: 90, courseAccuracy: 5, speed: 25, speedAccuracy: 1, timestamp: now)
        XCTAssertEqual(LiveSpeed.kmh(fresh, now: now) ?? 0, 90, accuracy: 0.01)
        let old = CLLocation(coordinate: .init(latitude: 25, longitude: 46), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 90, courseAccuracy: 5, speed: 25, speedAccuracy: 1, timestamp: now.addingTimeInterval(-10))
        XCTAssertNil(LiveSpeed.kmh(old, now: now))
        let noisy = CLLocation(coordinate: .init(latitude: 25, longitude: 46), altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: 90, courseAccuracy: 5, speed: 25, speedAccuracy: 9, timestamp: now)
        XCTAssertNil(LiveSpeed.kmh(noisy, now: now))
        XCTAssertNil(LiveSpeed.kmh(nil, now: now))
    }

    func testLimitStateNotes() {
        XCTAssertEqual(SpeedLimitState.known(80).limit, 80)
        XCTAssertNil(SpeedLimitState.noData.limit)
        XCTAssertNotNil(SpeedLimitState.noData.note)
        XCTAssertNotNil(SpeedLimitState.weakSignal.note)
        XCTAssertNil(SpeedLimitState.known(80).note)
    }
}

final class GuidanceTests: XCTestCase {
    private let a = CLLocationCoordinate2D(latitude: 25, longitude: 46)

    func testArabicDistancePhrases() {
        XCTAssertEqual(VoicePhrases.distance(800), "800 متر")
        XCTAssertEqual(VoicePhrases.distance(1000), "كيلومتر")
        XCTAssertEqual(VoicePhrases.distance(1500), "كيلومتر ونصف")
        XCTAssertEqual(VoicePhrases.distance(2000), "كيلومترين")
        XCTAssertEqual(VoicePhrases.distance(3000), "3 كيلومترات")
        XCTAssertEqual(VoicePhrases.distance(25_000), "25 كيلومتر")
    }

    private func snapshot(revision: Int, distance: Double, status: NavigationStatus = .active) -> NavigationSnapshot {
        var s = NavigationSnapshot()
        let dest = Waypoint(name: "روضة خريم", coordinate: .init(latitude: 25.4, longitude: 47.3))
        s.status = status
        s.plan = NavigationPlan(origin: nil, waypoints: [], destination: dest)
        s.planRevision = revision
        s.progress = NavigationProgress(targetIndex: 0, target: dest, distanceToTarget: distance, bearingToTarget: 45,
                                        remainingDistance: distance, relativeBearing: 0, estimatedSeconds: nil, isFinalTarget: true)
        return s
    }

    func testPlannerAnnouncesStartThresholdsAndArrivalOnce() {
        var p = VoiceGuidancePlanner()
        let start = p.phrases(for: snapshot(revision: 1, distance: 12_000), here: a)
        XCTAssertEqual(start.count, 1)
        XCTAssertTrue(start[0].hasPrefix("بدأت الملاحة"))
        XCTAssertTrue(p.phrases(for: snapshot(revision: 1, distance: 11_000), here: a).isEmpty)
        XCTAssertEqual(p.phrases(for: snapshot(revision: 1, distance: 4_900), here: a).count, 1)
        XCTAssertTrue(p.phrases(for: snapshot(revision: 1, distance: 4_800), here: a).isEmpty)   // لا تكرار
        XCTAssertEqual(p.phrases(for: snapshot(revision: 1, distance: 950), here: a).count, 1)
        XCTAssertEqual(p.phrases(for: snapshot(revision: 1, distance: 180), here: a).count, 1)
        let arrived = p.phrases(for: snapshot(revision: 1, distance: 20, status: .arrived), here: a)
        XCTAssertEqual(arrived, [VoicePhrases.arrived("روضة خريم")])
        XCTAssertTrue(p.phrases(for: snapshot(revision: 1, distance: 15, status: .arrived), here: a).isEmpty)
    }

    func testRemainingRoadDistanceUsesRouteNotStraightLine() {
        let s1 = RoadStep(instruction: "انعطف يمينًا", distance: 1000, endCoordinate: .init(latitude: 25.009, longitude: 46))
        let s2 = RoadStep(instruction: "استمر", distance: 3000, endCoordinate: .init(latitude: 25.009, longitude: 46.03))
        let route = RoadRoute(coordinates: [], steps: [s1, s2], distance: 4000, expectedTravelTime: 240)
        let d = SharedNavigationState.remainingRoadDistance(route: route, stepIndex: 0, at: a)
        XCTAssertEqual(d, GeoMath.distance(a, s1.endCoordinate) + 3000, accuracy: 1)
        XCTAssertEqual(SharedNavigationState.remainingRoadDistance(route: route, stepIndex: 5, at: a), 0)
    }

    func testRecentDestinationsDedupeAndCap() {
        let d = UserDefaults(suiteName: "test-recents-\(UUID().uuidString)")!
        RecentDestinations.record(Waypoint(name: "أ", coordinate: a), d)
        RecentDestinations.record(Waypoint(name: "أ مكرر", coordinate: .init(latitude: 25.0002, longitude: 46)), d)  // ~٢٢ م
        XCTAssertEqual(RecentDestinations.load(d).map(\.name), ["أ مكرر"])
        for i in 0..<12 { RecentDestinations.record(Waypoint(name: "\(i)", coordinate: .init(latitude: 20 + Double(i), longitude: 46)), d) }
        XCTAssertEqual(RecentDestinations.load(d).count, RecentDestinations.maxCount)
        XCTAssertEqual(RecentDestinations.load(d).first?.name, "11")
    }
}

final class NafudTests: XCTestCase {
    func testMajorSandNames() {
        XCTAssertTrue(SearchService.isMajorSand("نفود الثويرات"))
        XCTAssertTrue(SearchService.isMajorSand("الدهناء"))
        XCTAssertTrue(SearchService.isMajorSand("عروق بني معارض"))
        XCTAssertFalse(SearchService.isMajorSand("طعس ام عنيقر"))
        XCTAssertFalse(SearchService.isMajorSand("جبل طويق"))
    }

    func testBundledGazetteerHasNafud() throws {
        let url = try XCTUnwrap(Bundle(for: SearchService.self).url(forResource: "gazetteer", withExtension: "geojson")
            ?? Bundle.main.url(forResource: "gazetteer", withExtension: "geojson"))
        let entries = try SearchService.parseGeoJSON(Data(contentsOf: url))
        let nafud = entries.filter { $0.kind == .nafud }
        XCTAssertGreaterThan(nafud.count, 2500)
        XCTAssertTrue(nafud.contains { $0.name == "نفود الثويرات" })
        XCTAssertTrue(nafud.contains { $0.name == "الدهناء" })
    }
}

final class ColdWaterTests: XCTestCase {
    func testColdWaterKindAndSourceLinkParse() throws {
        let json = """
        {"type":"FeatureCollection","sourceURL":"https://maps.app.goo.gl/PSo5R6xbqBdGNV5j9","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[46.1,24.2]},
           "properties":{"id":"mared-1","name":"ماء بارد","kind":"coldWater","source":"مارد ماء"}}]}
        """
        let e = try SearchService.parseGeoJSON(Data(json.utf8))
        XCTAssertEqual(e.first?.kind, .coldWater)
        XCTAssertEqual(e.first?.url, "https://maps.app.goo.gl/PSo5R6xbqBdGNV5j9")
        XCTAssertEqual(PlaceKind.coldWater.title, "ماء بارد")
        // الماء البارد داخل «مياه وآبار» في الفلتر (لا زر مستقل)
        XCTAssertFalse(PlaceKind.mapKinds.contains(.coldWater))
        XCTAssertTrue(PlaceKind.expand([.water]).contains(.coldWater))
    }
}

final class WaterSubTests: XCTestCase {
    private func e(_ name: String, _ kind: PlaceKind) -> GazetteerEntry {
        GazetteerEntry(id: name, name: name, altNames: [], kind: kind, lat: 24, lon: 46, region: nil, source: "t")
    }
    func testWaterSubClassification() {
        XCTAssertEqual(WaterSub.of(e("ماء بارد", .coldWater)), .cold)
        XCTAssertEqual(WaterSub.of(e("بئر الحماد", .water)), .well)
        XCTAssertEqual(WaterSub.of(e("قليب العشار", .water)), .well)
        XCTAssertEqual(WaterSub.of(e("عين ماء", .water)), .spring)
        XCTAssertEqual(WaterSub.of(e("نقطة تعبئة ماء", .water)), .filling)
        XCTAssertEqual(WaterSub.of(e("ماء شرب", .water)), .filling)
        XCTAssertEqual(WaterSub.of(e("الخفس", .water)), .other)
        XCTAssertEqual(WaterSub.of(e("قلبان الشيحية", .water)), .well)
        XCTAssertEqual(WaterSub.of(e("عد الحسو", .water)), .well)
        XCTAssertNil(WaterSub.of(e("جبل طويق", .mountain)))
        XCTAssertEqual(PlaceKind.expand([.water]), [.water, .coldWater])
        XCTAssertEqual(WaterSub.decode(WaterSub.encode([.cold, .well])), [.cold, .well])
    }
}

final class TrackPartsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func pt(_ i: Int, _ minutes: Double, seg: Int = 0) -> TrackPoint {
        TrackPoint(lat: 25 + Double(i) * 0.001, lon: 46, time: t0.addingTimeInterval(minutes * 60), segment: seg)
    }

    /// مسار فيه وقفة تلقائية (مقطع جديد) ووقفة طويلة لم تُوقف التسجيل (فجوة زمنية).
    private var sample: [TrackPoint] {
        [pt(0, 0), pt(1, 1), pt(2, 2),                 // جزء ١
         pt(3, 20, seg: 1), pt(4, 21, seg: 1),         // جزء ٢ بعد إيقاف تلقائي
         pt(5, 40, seg: 1), pt(6, 41, seg: 1)]         // جزء ٣ بعد فجوة ١٩ دقيقة
    }

    func testSplitsAtAutoPauseAndLongGaps() {
        let n = TrackParts.normalized(sample, stopThreshold: 15 * 60)
        let parts = TrackParts.parts(n)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.map(\.index), [1, 2, 3])
        XCTAssertEqual(parts[0].stopAfter ?? 0, 18 * 60, accuracy: 1)
        XCTAssertNil(parts[2].stopAfter)
        XCTAssertGreaterThan(parts[0].distance, 200)
    }

    func testShortGapDoesNotSplit() {
        let n = TrackParts.normalized(sample, stopThreshold: 30 * 60)
        XCTAssertEqual(TrackParts.parts(n).count, 2)
    }

    func testDeletingOnePartLeavesOthersAndAGap() {
        let n = TrackParts.normalized(sample, stopThreshold: 15 * 60)
        let parts = TrackParts.parts(n)
        let after = TrackParts.removing(parts[1], from: n)
        let remaining = TrackParts.parts(after)
        XCTAssertEqual(remaining.count, 2)
        // المفاتيح ثابتة: الجزء الأول والثالث كما هما
        XCTAssertEqual(remaining.map(\.key), [parts[0].key, parts[2].key])
        // لا يُوصل الجزء الأول بالثالث: مقطعان منفصلان
        XCTAssertEqual(TrackAccumulator.segments(of: after).count, 2)
    }
}

final class PanTranslationTrackerTests: XCTestCase {
    /// سحب ثابت لليسار ٣٠٠ نقطة/ث، تحديث كل ٠٫٠٥ ث (١٥ نقطة لكل تحديث).
    private func run(cumulative: Bool, velocity: CGPoint = CGPoint(x: -300, y: 0)) -> CGFloat {
        var tr = PanTranslationTracker()
        var prev = CGPoint.zero, total: CGFloat = 0
        for i in 1...20 {
            let t = cumulative ? CGPoint(x: -15 * CGFloat(i), y: 0) : CGPoint(x: -15, y: 0)
            total += tr.step(translation: t, previous: prev, velocity: velocity, dt: i == 1 ? nil : 0.05).x
            prev = t
        }
        return total
    }

    func testCumulativeFollowsFinger() {
        XCTAssertEqual(run(cumulative: true), -300, accuracy: 1)
    }

    func testDeltaUpdatesDetectedAndFollowFinger() {
        // دون الاكتشاف كانت الخريطة تتحرك ١٥ نقطة فقط ثم تقف
        XCTAssertLessThan(run(cumulative: false), -250)
    }

    func testRightAndDownWorkToo() {
        var tr = PanTranslationTracker()
        var prev = CGPoint.zero, sum = CGPoint.zero
        for i in 1...10 {
            let t = CGPoint(x: 10 * CGFloat(i), y: 20 * CGFloat(i))
            let d = tr.step(translation: t, previous: prev, velocity: CGPoint(x: 200, y: 400), dt: 0.05)
            sum.x += d.x; sum.y += d.y; prev = t
        }
        XCTAssertEqual(sum.x, 100, accuracy: 1)
        XCTAssertEqual(sum.y, 200, accuracy: 1)
    }

    func testNoVelocityKeepsDocumentedCumulativeBehaviour() {
        XCTAssertEqual(run(cumulative: true, velocity: .zero), -300, accuracy: 1)
    }
}

final class CoordinateBarTests: XCTestCase {
    func testFormatIsShortLatinAndOrdered() {
        let t = CarPlayCoordinateBar.text(CLLocationCoordinate2D(latitude: 24.7136123, longitude: 46.6752957))
        XCTAssertEqual(t, "24.71361, 46.67530")
    }
}

final class RainNowTests: XCTestCase {
    func testLatestTimeFromCapabilities() {
        let xml = #"<Dimension name="time" default="2026-11-19T05:30:00Z" units="ISO8601" nearestValue="1">2022-12-09T08:00:00.000Z/2026-11-19T05:30:00.000Z/PT15M</Dimension>"#
        let d = RainNowService.latestTime(inCapabilities: xml)
        XCTAssertEqual(d, ISO8601DateFormatter().date(from: "2026-11-19T05:30:00Z"))
    }

    func testPaletteIntensityOrdering() {
        XCTAssertLessThan(RainNowService.intensity(r: 255, g: 255, b: 204), 1)
        XCTAssertEqual(RainScale.level(RainNowService.intensity(r: 126, g: 204, b: 186)), 2)
        XCTAssertEqual(RainScale.level(RainNowService.intensity(r: 12, g: 44, b: 133)), 4)
    }

    func testBoxClampedToRegionAndPixelsBounded() {
        let b = RainNowService.requestBox(sw: .init(latitude: 5, longitude: 20), ne: .init(latitude: 40, longitude: 70))
        XCTAssertEqual(b.0, 10); XCTAssertEqual(b.1, 32); XCTAssertEqual(b.2, 36); XCTAssertEqual(b.3, 62)
        let (w, h) = RainNowService.pixels(for: b)
        XCTAssertLessThanOrEqual(max(w, h), 221)
    }

    func testImageToCellsMergesRuns() {
        // صورة ٤×٢: الصف العلوي ثلاث نقاط بنفس اللون، والسفلي فارغ
        let w = 4, h = 2
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for x in 0..<3 { let i = x * 4; px[i] = 32; px[i + 1] = 120; px[i + 2] = 180; px[i + 3] = 255 }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let img = ctx.makeImage()!
        let cells = RainNowService.cells(from: img, box: (20, 40, 22, 44))
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].lat, 21.5, accuracy: 0.001)      // الصف العلوي = الشمال
        XCTAssertEqual(cells[0].width ?? 0, 3, accuracy: 0.001)  // ثلاث نقاط بعرض درجة
        XCTAssertEqual(RainScale.level(cells[0].hourly[0]), 4)
    }
}
