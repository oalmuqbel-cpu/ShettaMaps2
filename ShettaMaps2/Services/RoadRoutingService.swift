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
    static func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RoadRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            guard let r = response.routes.first else { throw RoadRoutingError.noRoute }
            let steps = buildSteps(r.steps.map { (instruction: $0.instructions, distance: $0.distance, coords: $0.polyline.coordinates) })
            return RoadRoute(coordinates: r.polyline.coordinates, steps: steps,
                             distance: r.distance, expectedTravelTime: r.expectedTravelTime)
        } catch let e as RoadRoutingError {
            throw e
        } catch let e as MKError where e.code == .serverFailure || e.code == .loadingThrottled {
            throw RoadRoutingError.offline
        } catch {
            throw RoadRoutingError.noRoute
        }
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
