import Foundation
import MapKit

/// مقطع من الطريق. التعليمة هي المناورة التي تُنفَّذ عند نهاية المقطع (مثل «انعطف يمينًا إلى …»)،
/// والمسافة حتى تلك المناورة، وزاوية الانعطاف عندها (موجبة لليمين، nil عند الوصول).
struct RoadStep: Equatable {
    var instruction: String
    var distance: Double
    var endCoordinate: CLLocationCoordinate2D
    var turnAngle: Double? = nil

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
                return RoadStep(instruction: text, distance: legs[i].distance, endCoordinate: end, turnAngle: angle ?? 0)
            }
            return RoadStep(instruction: "الوصول إلى الوجهة", distance: legs[i].distance, endCoordinate: end, turnAngle: nil)
        }
    }
}

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
