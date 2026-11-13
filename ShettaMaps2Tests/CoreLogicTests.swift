import XCTest
import CoreLocation
@testable import ShettaMaps2

final class CoordinateUtilitiesTests: XCTestCase {
    private func assertCoord(_ text: String, _ lat: Double, _ lon: Double, accuracy: Double = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        do {
            let c = try CoordinateUtilities.parse(text)
            XCTAssertEqual(c.latitude, lat, accuracy: accuracy, "lat for \(text)", file: file, line: line)
            XCTAssertEqual(c.longitude, lon, accuracy: accuracy, "lon for \(text)", file: file, line: line)
        } catch {
            XCTFail("Failed to parse \(text): \(error)", file: file, line: line)
        }
    }

    func testDecimalFormats() {
        assertCoord("24.7136, 46.6753", 24.7136, 46.6753)
        assertCoord("24.7136 46.6753", 24.7136, 46.6753)
        assertCoord("-33.5,151.25", -33.5, 151.25)
        assertCoord("24.7136N, 46.6753E", 24.7136, 46.6753)
    }

    func testArabicDigitsAndSeparators() {
        assertCoord("٢٤٫٧١٣٦، ٤٦٫٦٧٥٣", 24.7136, 46.6753)
        assertCoord("24.7136 ش، 46.6753 ق", 24.7136, 46.6753)
        assertCoord("24.7136 شمال 46.6753 شرق", 24.7136, 46.6753)
    }

    func testDMS() {
        assertCoord("24°42'49\"N 46°40'31\"E", 24.713611, 46.675278)
        assertCoord("24° 42′ 49″ ش 46° 40′ 31″ ق", 24.713611, 46.675278)
        assertCoord("24 42 49 N, 46 40 31 E", 24.713611, 46.675278)
        assertCoord("N24 42 49 E46 40 31", 24.713611, 46.675278)
    }

    func testDDM() {
        assertCoord("24 42.8167 N 46 40.5167 E", 24.713611, 46.675278, accuracy: 1e-4)
        assertCoord("24°42.8167' S, 46°40.5167' W", -24.713611, -46.675278, accuracy: 1e-4)
    }

    func testHemisphereOrderSwap() {
        // خط الطول أولًا مع حروف الاتجاه
        assertCoord("46.6753E, 24.7136N", 24.7136, 46.6753)
    }

    func testValidation() {
        XCTAssertThrowsError(try CoordinateUtilities.parse("")) { XCTAssertEqual($0 as? CoordinateParseError, .empty) }
        XCTAssertThrowsError(try CoordinateUtilities.parse("95, 46")) { XCTAssertEqual($0 as? CoordinateParseError, .latitudeOutOfRange) }
        XCTAssertThrowsError(try CoordinateUtilities.parse("24, 190")) { XCTAssertEqual($0 as? CoordinateParseError, .longitudeOutOfRange) }
        XCTAssertThrowsError(try CoordinateUtilities.parse("24 61 0 N, 46 0 0 E")) {
            XCTAssertEqual($0 as? CoordinateParseError, .minutesOrSecondsOutOfRange)
        }
        XCTAssertThrowsError(try CoordinateUtilities.parse("abc"))
    }

    func testDMSConversionRoundTrip() {
        for v in [24.713611, -46.675278, 0.000001, 89.999999, 23.999999] {
            let dms = CoordinateUtilities.toDMS(v)
            XCTAssertLessThan(dms.minutes, 60)
            XCTAssertLessThan(dms.seconds, 60)
            XCTAssertEqual(CoordinateUtilities.fromDMS(dms), v, accuracy: 1e-5)
        }
    }

    func testFormatThenParseRoundTrip() throws {
        let c = CLLocationCoordinate2D(latitude: 26.3927, longitude: 43.9732)
        for f in CoordinateFormat.allCases {
            let text = CoordinateUtilities.format(c, as: f)
            let parsed = try CoordinateUtilities.parse(text)
            XCTAssertEqual(parsed.latitude, c.latitude, accuracy: 1e-4, "format \(f)")
            XCTAssertEqual(parsed.longitude, c.longitude, accuracy: 1e-4, "format \(f)")
        }
    }
}

final class GeoMathTests: XCTestCase {
    let riyadh = CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)
    let jeddah = CLLocationCoordinate2D(latitude: 21.4858, longitude: 39.1925)

    func testDistance() {
        XCTAssertEqual(GeoMath.distance(riyadh, jeddah), 845_102, accuracy: 50)
        XCTAssertEqual(GeoMath.distance(riyadh, riyadh), 0, accuracy: 1e-6)
    }

    func testBearing() {
        XCTAssertEqual(GeoMath.bearing(from: riyadh, to: jeddah), 246.38, accuracy: 0.05)
        let north = GeoMath.destination(from: riyadh, distance: 1000, bearing: 0)
        // قد يكون الناتج 359.9999 بسبب دقة الأعداد العشرية، لذلك نقارن الفرق الزاوي
        XCTAssertEqual(GeoMath.angleDelta(from: 0, to: GeoMath.bearing(from: riyadh, to: north)), 0, accuracy: 0.01)
        XCTAssertEqual(GeoMath.cardinalName(0), "شمال")
        XCTAssertEqual(GeoMath.cardinalName(91), "شرق")
        XCTAssertEqual(GeoMath.cardinalName(225), "جنوب غرب")
        XCTAssertEqual(GeoMath.cardinalName(359), "شمال")
    }

    func testDestinationRoundTrip() {
        let p = GeoMath.destination(from: riyadh, distance: 12_345, bearing: 73)
        XCTAssertEqual(GeoMath.distance(riyadh, p), 12_345, accuracy: 0.5)
    }

    func testAngleDelta() {
        XCTAssertEqual(GeoMath.angleDelta(from: 350, to: 10), 20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.angleDelta(from: 10, to: 350), -20, accuracy: 1e-9)
        XCTAssertEqual(GeoMath.angleDelta(from: 0, to: 180), 180, accuracy: 1e-9)
    }

    func testTileEstimate() {
        let n = GeoMath.estimatedTileCount(sw: .init(latitude: 24, longitude: 46), ne: .init(latitude: 25, longitude: 47), minZoom: 0, maxZoom: 10)
        XCTAssertGreaterThan(n, 0)
        XCTAssertLessThan(n, 2000)
    }
}

final class TrackAccumulatorTests: XCTestCase {
    private func point(_ lat: Double, _ lon: Double, t: TimeInterval, acc: Double = 5, speed: Double? = nil) -> TrackPoint {
        TrackPoint(lat: lat, lon: lon, time: Date(timeIntervalSince1970: t), speed: speed, hAcc: acc)
    }

    func testRejectsPoorAccuracyAndJumps() {
        var acc = TrackAccumulator()
        XCTAssertNil(acc.append(point(24, 46, t: 0)))
        XCTAssertEqual(acc.append(point(24.001, 46, t: 10, acc: 200)), .poorAccuracy)
        XCTAssertEqual(acc.append(point(24.00001, 46, t: 11)), .tooClose)
        // 11 كم في ثانيتين = قفزة غير منطقية
        XCTAssertEqual(acc.append(point(24.1, 46, t: 12)), .implausibleJump)
        XCTAssertEqual(acc.append(point(24.001, 46, t: 0)), .outOfOrder)
        XCTAssertEqual(acc.points.count, 1)
    }

    func testDistanceMovingTimeAndSegments() {
        var acc = TrackAccumulator()
        // نقطة كل 10 ثوانٍ وكل نحو 111 مترًا (≈ 11 م/ث)
        for i in 0..<5 { acc.append(point(24 + Double(i) * 0.001, 46, t: Double(i) * 10)) }
        XCTAssertEqual(acc.distance, 4 * 111.2, accuracy: 2)
        XCTAssertEqual(acc.movingSeconds, 40, accuracy: 0.001)
        XCTAssertEqual(acc.segments.count, 1)

        acc.markPaused()
        // بعد الإيقاف المؤقت، النقطة البعيدة لا تُحتسب مسافتها ولا تعد قفزة
        acc.append(point(24.05, 46, t: 600))
        acc.append(point(24.051, 46, t: 610))
        XCTAssertEqual(acc.segments.count, 2)
        XCTAssertEqual(acc.distance, 5 * 111.2, accuracy: 3)
    }

    func testStationaryTimeIsNotMoving() {
        var acc = TrackAccumulator()
        acc.append(point(24, 46, t: 0))
        acc.append(point(24.00004, 46, t: 100)) // 4.4 م في 100 ث = توقف
        XCTAssertEqual(acc.movingSeconds, 0, accuracy: 0.001)
    }
}

final class GPXServiceTests: XCTestCase {
    func testExportImportRoundTrip() throws {
        let pts = [
            TrackPoint(lat: 24.1, lon: 46.1, alt: 600, time: Date(timeIntervalSince1970: 1_700_000_000), speed: 10, segment: 0),
            TrackPoint(lat: 24.2, lon: 46.2, alt: 610, time: Date(timeIntervalSince1970: 1_700_000_060), segment: 0),
            TrackPoint(lat: 24.3, lon: 46.3, time: Date(timeIntervalSince1970: 1_700_000_600), segment: 1)
        ]
        let xml = GPXService.export(trackName: "رحلة <الدهناء> & النفود", points: pts,
                                    waypoints: [.init(name: "مخيم", lat: 24.15, lon: 46.15, elevation: 605, notes: "قرب الشجرة")])
        XCTAssertTrue(xml.contains("&lt;الدهناء&gt; &amp;"))
        let doc = try GPXService.parse(data: Data(xml.utf8))
        XCTAssertEqual(doc.tracks.count, 1)
        XCTAssertEqual(doc.tracks[0].name, "رحلة <الدهناء> & النفود")
        XCTAssertEqual(doc.tracks[0].points.count, 3)
        XCTAssertEqual(doc.tracks[0].points[2].segment, 1)
        XCTAssertEqual(doc.tracks[0].points[0].alt ?? 0, 600, accuracy: 0.1)
        XCTAssertEqual(doc.tracks[0].points[1].time, pts[1].time)
        XCTAssertEqual(doc.waypoints.first?.name, "مخيم")
        XCTAssertEqual(doc.waypoints.first?.notes, "قرب الشجرة")
    }

    func testParsesRoutesAndNamespaces() throws {
        let xml = """
        <?xml version="1.0"?><gpx:gpx xmlns:gpx="http://www.topografix.com/GPX/1/1" version="1.1">
        <gpx:rte><gpx:name>طريق</gpx:name><gpx:rtept lat="24" lon="46"/><gpx:rtept lat="24.1" lon="46.1"/></gpx:rte></gpx:gpx>
        """
        let doc = try GPXService.parse(data: Data(xml.utf8))
        XCTAssertEqual(doc.tracks.first?.name, "طريق")
        XCTAssertEqual(doc.tracks.first?.points.count, 2)
    }

    func testRejectsInvalid() {
        XCTAssertThrowsError(try GPXService.parse(data: Data("<gpx><trk>".utf8)))
        XCTAssertThrowsError(try GPXService.parse(data: Data("<gpx version=\"1.1\"></gpx>".utf8)))
    }
}

final class NavigationEngineTests: XCTestCase {
    let a = Waypoint(name: "أ", coordinate: .init(latitude: 24, longitude: 46))
    let b = Waypoint(name: "ب", coordinate: .init(latitude: 24.1, longitude: 46))
    let c = Waypoint(name: "ج", coordinate: .init(latitude: 24.1, longitude: 46.1))

    func testLegsAndTotal() {
        let plan = NavigationPlan(origin: a, waypoints: [b], destination: c)
        let legs = NavigationEngine.legs(for: plan)
        XCTAssertEqual(legs.count, 2)
        XCTAssertEqual(legs[0].bearing, 0, accuracy: 0.01)
        XCTAssertEqual(legs[1].bearing, 90, accuracy: 0.1)
        XCTAssertEqual(NavigationEngine.totalDistance(for: plan), legs[0].distance + legs[1].distance, accuracy: 1e-6)
    }

    func testProgressAndArrival() {
        let plan = NavigationPlan(origin: a, waypoints: [b], destination: c)
        let p = NavigationEngine.progress(plan: plan, targetIndex: 0, current: a.coordinate, heading: 90, speed: 10)
        XCTAssertEqual(p.target.name, "ب")
        XCTAssertFalse(p.isFinalTarget)
        XCTAssertEqual(p.relativeBearing ?? 0, -90, accuracy: 0.1) // الهدف شمالًا والسيارة شرقًا = يسار
        XCTAssertTrue(NavigationEngine.instruction(for: p).contains("يسارًا"))
        XCTAssertGreaterThan(p.remainingDistance, p.distanceToTarget)
        XCTAssertNotNil(p.estimatedSeconds)

        let near = GeoMath.destination(from: b.coordinate, distance: 20, bearing: 180)
        let p2 = NavigationEngine.progress(plan: plan, targetIndex: 0, current: near, heading: nil, speed: nil)
        XCTAssertTrue(NavigationEngine.hasArrived(p2, accuracy: 5))
        XCTAssertNil(p2.estimatedSeconds)
    }

    func testPlanCodableForPersistence() throws {
        let plan = NavigationPlan(origin: nil, waypoints: [b], destination: c, mode: .road)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(NavigationPlan.self, from: data), plan)
    }
}

final class SearchNormalizationTests: XCTestCase {
    func testArabicNormalization() {
        XCTAssertEqual(SearchService.normalizeArabic("أَبُو"), "ابو")
        XCTAssertEqual(SearchService.normalizeArabic("روضة"), "روضه")
        XCTAssertEqual(SearchService.searchKey("الطُّوَيق"), "طويق")
        XCTAssertTrue(SearchService.searchKey("جبل طويق").contains(SearchService.searchKey("الطويق")))
    }

    func testGeoJSONParsingSkipsInvalid() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[46.1,24.1]},"properties":{"name":"مكان","kind":"mountain"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[46.1,124.1]},"properties":{"name":"خطأ"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[46.1,24.1]},"properties":{}}
        ]}
        """
        let entries = try SearchService.parseGeoJSON(Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .mountain)
        XCTAssertEqual(entries[0].lat, 24.1)
    }
}

final class PlaceKindFilterTests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let set: Set<PlaceKind> = [.valley, .rawdah]
        let raw = PlaceKind.encodeSet(set)
        XCTAssertEqual(raw, "rawdah,valley")
        XCTAssertEqual(PlaceKind.decodeSet(raw), set)
    }

    func testDecodeIgnoresUnknownAndNonMapKinds() {
        XCTAssertEqual(PlaceKind.decodeSet("rawdah,saved,all,xyz"), [.rawdah])
        XCTAssertTrue(PlaceKind.decodeSet("").isEmpty)
    }
}

final class RoadStepTests: XCTestCase {
    func testStepsCarryNextManeuverWithTurnAngle() {
        let a = CLLocationCoordinate2D(latitude: 24.0, longitude: 46.0)
        let b = CLLocationCoordinate2D(latitude: 24.01, longitude: 46.0)
        let c = CLLocationCoordinate2D(latitude: 24.01, longitude: 46.01)
        let steps = RoadRoutingService.buildSteps([
            (instruction: "", distance: 1100, coords: [a, b]),
            (instruction: "انعطف يمينًا إلى طريق الملك فهد", distance: 1000, coords: [b, c])
        ])
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].instruction, "انعطف يمينًا إلى طريق الملك فهد")
        XCTAssertEqual(steps[0].turnAngle ?? 0, 90, accuracy: 5)
        XCTAssertEqual(steps[1].instruction, "الوصول إلى الوجهة")
        XCTAssertNil(steps[1].turnAngle)
    }
}
