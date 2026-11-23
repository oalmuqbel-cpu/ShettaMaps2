import Foundation
import MapKit

/// مقطع من الطريق. التعليمة هي المناورة التي تُنفَّذ عند نهاية المقطع (مثل «انعطف يمينًا إلى …»)،
/// والمسافة حتى تلك المناورة، وزاوية الانعطاف عندها (موجبة لليمين، nil عند الوصول).
struct RoadStep: Equatable {
    var instruction: String
    var distance: Double
    var endCoordinate: CLLocationCoordinate2D
    var turnAngle: Double? = nil
    var startCoordinate: CLLocationCoordinate2D? = nil

    static func == (a: RoadStep, b: RoadStep) -> Bool {
        a.instruction == b.instruction && a.distance == b.distance
            && a.endCoordinate.latitude == b.endCoordinate.latitude
            && a.endCoordinate.longitude == b.endCoordinate.longitude
    }
}

struct RoadRoute: Equatable {
    var coordinates: [CLLocationCoordinate2D]
    var steps: [RoadStep]
    var distance: Double
    var expectedTravelTime: TimeInterval
    /// اسم الطريق الرئيسي كما تعطيه الخدمة (مثل «طريق الملك فهد»).
    var name: String = ""
    /// المسافة المستقيمة الباقية من نهاية الطريق إلى الوجهة (إذا كانت الوجهة في البر بعيدًا عن أي طريق).
    var offRoadTail: Double = 0

    static func == (a: RoadRoute, b: RoadRoute) -> Bool {
        a.distance == b.distance && a.steps == b.steps && a.coordinates.count == b.coordinates.count
    }
}

enum RoadRoutingError: LocalizedError {
    case offline, noRoute
    var errorDescription: String? {
        switch self {
        case .offline: return "توجيهات الطرق تحتاج إلى الإنترنت. سيُستخدم الخط المباشر."
        case .noRoute: return "لا يوجد طريق معروف إلى هذه النقطة. سيُستخدم الخط المباشر كإرشاد جغرافي."
        }
    }
}

/// يطلب طريق قيادة من Apple Maps (MKDirections). يتطلب الإنترنت ولا يغطي الطرق الصحراوية غير المعبدة غالبًا.
enum RoadRoutingService {
    @MainActor
    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RoadRoute {
        guard let r = try await routes(from: from, to: to, alternatives: false).first else { throw RoadRoutingError.noRoute }
        return r
    }

    /// حتى ثلاثة طرق بديلة مرتبة من الأسرع: من شبكة الطرق المنزلة في الجوال أولًا (تعمل دون إنترنت،
    /// وهي الوحيدة في السعودية لأن Apple لا توفر توجيهات القيادة فيها)، وإلا من خدمة Apple حيث تتوفر.
    @MainActor
    static func routes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, alternatives: Bool = true) async throws -> [RoadRoute] {
        if let g = RouteGraphStore.shared.graph(covering: from, to) {
            let count = alternatives ? 3 : 1
            return try await Task.detached(priority: .userInitiated) {
                try OfflineRouter.routes(on: g, from: from, to: to, alternatives: count)
            }.value.map { withOffRoadTail($0, to: to) }
        }
        do {
            return try await appleRoutes(from: from, to: to, alternatives: alternatives).map { withOffRoadTail($0, to: to) }
        } catch {
            // في السعودية: لا توجيهات من Apple، فالمطلوب تنزيل طرق الملاحة للمنطقة
            if RouteGraphStore.shared.suggestedRegion(for: from, to) != nil || isSaudi(from) { throw OfflineRouter.RouterError.noGraph }
            throw error
        }
    }

    /// أبعد من هذا عن نهاية الطريق تُعد الوجهة خارج الطرق (في البر).
    static let offRoadThreshold: Double = 150

    /// إذا كانت الوجهة بعيدة عن نهاية الطريق: يُعلَّم المسار بأنه طريق ثم خط مستقيم، وتتغير آخر تعليمة لتوضح ذلك.
    static func withOffRoadTail(_ route: RoadRoute, to destination: CLLocationCoordinate2D) -> RoadRoute {
        guard let end = route.coordinates.last else { return route }
        let gap = GeoMath.distance(end, destination)
        guard gap > offRoadThreshold else { return route }
        var r = route
        r.offRoadTail = gap
        if !r.steps.isEmpty {
            r.steps[r.steps.count - 1].instruction = "نهاية الطريق: أكمل بخط مستقيم إلى الوجهة (\(Fmt.navDistance(gap)))"
        }
        return r
    }

    static func isSaudi(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude > 16 && c.latitude < 32.5 && c.longitude > 34.4 && c.longitude < 55.7
    }

    static func appleRoutes(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, alternatives: Bool) async throws -> [RoadRoute] {
        guard await NetworkMonitor.shared.isOnline else { throw RoadRoutingError.offline }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternatives
        do {
            let response = try await MKDirections(request: request).calculate()
            let list = response.routes.prefix(3).map { r in
                RoadRoute(coordinates: r.polyline.coordinates,
                          steps: buildSteps(r.steps.map { (instruction: $0.instructions, distance: $0.distance, coords: $0.polyline.coordinates) }),
                          distance: r.distance, expectedTravelTime: r.expectedTravelTime, name: r.name)
            }
            guard !list.isEmpty else { throw RoadRoutingError.noRoute }
            return list.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
        } catch let e as RoadRoutingError {
            throw e
        } catch {
            let ns = error as NSError
            appLog.error("Directions failed: \(ns.domain, privacy: .public) \(ns.code) \(ns.localizedDescription, privacy: .public)")
            if let e = error as? MKError, e.code == .serverFailure || e.code == .loadingThrottled { throw RoadRoutingError.offline }
            if ns.domain == NSURLErrorDomain { throw RoadRoutingError.offline }
            throw RoadRoutingError.noRoute
        }
    }

    /// موضع أقرب نقطة على خط الطريق، بالبحث للأمام من آخر موضع معروف (لتلوين الجزء المقطوع).
    static func progressIndex(on coords: [CLLocationCoordinate2D], from start: Int, at p: CLLocationCoordinate2D) -> Int {
        guard coords.count > 1 else { return 0 }
        var best = min(start, coords.count - 2), bestD = Double.greatestFiniteMagnitude
        let end = min(coords.count - 1, start + 400)
        for i in max(0, start - 5)..<end {
            let d = segmentDistance(p, coords[i], coords[i + 1])
            if d < bestD { bestD = d; best = i }
        }
        return bestD < 120 ? max(start, best) : start
    }
}

extension RoadRoutingService {
    /// يحدد المقطع الحالي: أقرب مقطع للموقع من المقطع الحالي فما بعده (لا يرجع للخلف)،
    /// حتى لا تعلق التعليمات إذا فاتت نقطة الانعطاف أو انقطعت إشارة GPS.
    static func currentStepIndex(steps: [RoadStep], from index: Int, at p: CLLocationCoordinate2D) -> Int {
        guard index < steps.count else { return index }
        var best = index, bestD = Double.greatestFiniteMagnitude
        for j in index..<steps.count {
            let s = steps[j]
            let d = s.startCoordinate.map { segmentDistance(p, $0, s.endCoordinate) } ?? GeoMath.distance(p, s.endCoordinate)
            if d < bestD - 1 { bestD = d; best = j }
        }
        // عند الوصول لنهاية المقطع ننتقل للتالي
        if best < steps.count, GeoMath.distance(p, steps[best].endCoordinate) < 40 { best += 1 }
        return max(index, best)
    }

    /// أقرب نقطة على قطعة مستقيمة إلى نقطة معطاة (تقريب مستوٍ يكفي للمسافات القصيرة).
    static func project(_ p: CLLocationCoordinate2D, onto a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let k = cos(a.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * k, dy = b.latitude - a.latitude
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return a }
        let t = max(0, min(1, (((p.longitude - a.longitude) * k) * dx + (p.latitude - a.latitude) * dy) / len2))
        return CLLocationCoordinate2D(latitude: a.latitude + t * (b.latitude - a.latitude),
                                      longitude: a.longitude + t * (b.longitude - a.longitude))
    }

    /// المسافة التقريبية (م) من نقطة إلى قطعة مستقيمة.
    static func segmentDistance(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let k = cos(a.latitude * .pi / 180) * 111_320.0
        let ax = a.longitude * k, ay = a.latitude * 110_540, bx = b.longitude * k, by = b.latitude * 110_540
        let px = p.longitude * k, py = p.latitude * 110_540
        let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(px - ax, py - ay) }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    /// يحوّل مقاطع Apple (تعليمة كل مقطع تخص بدايته) إلى مقاطع تحمل المناورة القادمة عند نهايتها مع زاوية الانعطاف.
    static func buildSteps(_ raw: [(instruction: String, distance: Double, coords: [CLLocationCoordinate2D])]) -> [RoadStep] {
        let legs = raw.filter { $0.coords.count >= 2 && $0.distance > 0 }
        guard !legs.isEmpty else { return [] }
        func startBearing(_ c: [CLLocationCoordinate2D]) -> Double? {
            guard let a = c.first, let b = c.dropFirst().first(where: { GeoMath.distance(a, $0) > 3 }) else { return nil }
            return GeoMath.bearing(from: a, to: b)
        }
        func endBearing(_ c: [CLLocationCoordinate2D]) -> Double? {
            guard let b = c.last, let a = c.dropLast().last(where: { GeoMath.distance($0, b) > 3 }) else { return nil }
            return GeoMath.bearing(from: a, to: b)
        }
        return legs.indices.map { i in
            let end = legs[i].coords.last!
            if i + 1 < legs.count {
                let next = legs[i + 1]
                var angle: Double?
                if let e = endBearing(legs[i].coords), let s = startBearing(next.coords) { angle = GeoMath.angleDelta(from: e, to: s) }
                let text = next.instruction.isEmpty ? "استمر في الطريق" : next.instruction
                return RoadStep(instruction: text, distance: legs[i].distance, endCoordinate: end, turnAngle: angle ?? 0,
                                startCoordinate: legs[i].coords.first)
            }
            return RoadStep(instruction: "الوصول إلى الوجهة", distance: legs[i].distance, endCoordinate: end, turnAngle: nil,
                            startCoordinate: legs[i].coords.first)
        }
    }
}

#if DEBUG
extension RoadRoutingService {
    static let sampleDestination = CLLocationCoordinate2D(latitude: 24.7530, longitude: 46.6990)
    /// مسار نموذجي في الرياض لالتقاط لقطات التوجيه منعطفًا بمنعطف على المحاكي (نسخة التطوير فقط).
    static func sampleRoute() -> RoadRoute {
        typealias C = CLLocationCoordinate2D
        let legs: [(instruction: String, distance: Double, coords: [C])] = [
            ("", 820, [C(latitude: 24.7136, longitude: 46.6753), C(latitude: 24.7210, longitude: 46.6745)]),
            ("انعطف يمينًا إلى طريق العروبة", 1260, [C(latitude: 24.7210, longitude: 46.6745), C(latitude: 24.7215, longitude: 46.6870)]),
            ("انعطف يسارًا إلى طريق الملك عبدالعزيز", 3400, [C(latitude: 24.7215, longitude: 46.6870), C(latitude: 24.7520, longitude: 46.6890)]),
            ("انعطف يمينًا نحو نقطة اللقاء", 1010, [C(latitude: 24.7520, longitude: 46.6890), sampleDestination])
        ]
        let steps = buildSteps(legs)
        return RoadRoute(coordinates: legs.flatMap(\.coords), steps: steps, distance: legs.reduce(0) { $0 + $1.distance },
                         expectedTravelTime: 720)
    }
}
#endif

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
