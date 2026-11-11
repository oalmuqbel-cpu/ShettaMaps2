import Foundation
import MapKit

struct RoadStep: Equatable {
    var instruction: String
    var distance: Double
    var endCoordinate: CLLocationCoordinate2D

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
            let steps = r.steps.compactMap { step -> RoadStep? in
                let n = step.polyline.pointCount
                guard n > 0, !step.instructions.isEmpty else { return nil }
                var end = CLLocationCoordinate2D()
                step.polyline.getCoordinates(&end, range: NSRange(location: n - 1, length: 1))
                return RoadStep(instruction: step.instructions, distance: step.distance, endCoordinate: end)
            }
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

extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
