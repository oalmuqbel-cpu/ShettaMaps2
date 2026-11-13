import Foundation
import SwiftData
import CoreLocation
import Combine

/// إدارة الرحلات البرية: نقطة البداية، نقاط التوقف، التسجيل التلقائي، آخر موقع معروف، والعودة للبداية.
@MainActor
final class TripManager: ObservableObject {
    @Published private(set) var activeTrip: Trip?

    private let context: ModelContext
    private let recorder: RouteRecordingManager
    private let navigation: SharedNavigationState
    private let location: LocationManager
    private var subscription: AnyCancellable?
    private var lastPersist = Date.distantPast

    init(context: ModelContext, recorder: RouteRecordingManager, navigation: SharedNavigationState, location: LocationManager) {
        self.context = context
        self.recorder = recorder
        self.navigation = navigation
        self.location = location
        let descriptor = FetchDescriptor<Trip>(predicate: #Predicate { $0.isActive == true })
        activeTrip = try? context.fetch(descriptor).first
        subscription = location.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] loc in self?.trackLastKnown(loc) }
    }

    // MARK: - دورة حياة الرحلة

    @discardableResult
    func startTrip(name: String, destination: Waypoint? = nil, autoRecord: Bool) -> Trip {
        if activeTrip != nil { endTrip() }
        let trip = Trip(name: name.isEmpty ? "رحلة \(Fmt.dateTime.string(from: Date()))" : name)
        trip.isActive = true
        trip.autoRecord = autoRecord
        if let c = location.location?.coordinate {
            trip.startLatitude = c.latitude
            trip.startLongitude = c.longitude
        }
        if let d = destination {
            trip.destinationLatitude = d.lat
            trip.destinationLongitude = d.lon
            trip.destinationName = d.name
        }
        context.insert(trip)
        try? context.save()
        activeTrip = trip
        if autoRecord, !recorder.isActive {
            recorder.start(name: trip.name, trip: trip)
        }
        if UserDefaults.standard.object(forKey: SettingsKeys.sunsetReminder) as? Bool ?? true, let c = location.location?.coordinate {
            SunsetReminder.schedule(at: c)
        }
        if let d = destination {
            navigation.start(NavigationPlan(origin: startWaypoint(of: trip), waypoints: trip.stops,
                                            destination: d, mode: .direct, tripID: trip.id))
        }
        return trip
    }

    func endTrip() {
        SunsetReminder.cancel()
        guard let trip = activeTrip else { return }
        if recorder.isActive, recorder.currentTrack?.trip?.id == trip.id { recorder.finish() }
        if navigation.plan?.tripID == trip.id { navigation.stop() }
        trip.isActive = false
        trip.endedAt = Date()
        try? context.save()
        activeTrip = nil
    }

    /// تعيين نقطة البداية يدويًا (مثلًا إذا بدأت الرحلة قبل وصول إشارة GPS).
    func setStart(_ c: CLLocationCoordinate2D, name: String = "نقطة البداية", for trip: Trip) {
        trip.startLatitude = c.latitude
        trip.startLongitude = c.longitude
        trip.startName = name
        try? context.save()
    }

    /// حذف نقطة البداية (مثلًا إذا حُفظت في مكان خاطئ).
    func clearStart(of trip: Trip) {
        trip.startLatitude = nil
        trip.startLongitude = nil
        try? context.save()
    }

    func addStop(_ w: Waypoint, to trip: Trip) {
        var s = trip.stops
        s.append(w)
        trip.stops = s
        try? context.save()
    }

    func removeStops(at offsets: IndexSet, from trip: Trip) {
        var s = trip.stops
        s.remove(atOffsets: offsets)
        trip.stops = s
        try? context.save()
    }

    func moveStops(from source: IndexSet, to destination: Int, in trip: Trip) {
        var s = trip.stops
        s.move(fromOffsets: source, toOffset: destination)
        trip.stops = s
        try? context.save()
    }

    func setDestination(_ w: Waypoint?, for trip: Trip) {
        trip.destinationLatitude = w?.lat
        trip.destinationLongitude = w?.lon
        trip.destinationName = w?.name ?? ""
        try? context.save()
    }

    /// يبدأ الملاحة عبر نقاط التوقف إلى الوجهة.
    func navigateTrip(_ trip: Trip, mode: GuidanceMode = .direct) {
        let stops = trip.stops
        guard let dest = trip.destination ?? stops.last else { return }
        let waypoints = trip.destination == nil ? Array(stops.dropLast()) : stops
        let origin = location.location.map { Waypoint(name: "موقعي", coordinate: $0.coordinate) }
        navigation.start(NavigationPlan(origin: origin, waypoints: waypoints, destination: dest, mode: mode, tripID: trip.id))
    }

    /// الرجوع إلى نقطة بداية الرحلة النشطة، أو آخر نقطة بداية مسجلة.
    @discardableResult
    func returnToStart(of trip: Trip? = nil) -> Bool {
        guard let t = trip ?? activeTrip, let start = startWaypoint(of: t) else { return false }
        navigation.navigate(to: start, mode: .direct, tripID: t.id)
        return true
    }

    func startWaypoint(of trip: Trip) -> Waypoint? {
        trip.startCoordinate.map { Waypoint(name: trip.startName, coordinate: $0) }
    }

    func delete(_ trip: Trip) {
        if trip.id == activeTrip?.id { endTrip() }
        context.delete(trip)
        try? context.save()
    }

    // MARK: - آخر موقع معروف

    private func trackLastKnown(_ loc: CLLocation) {
        guard let trip = activeTrip else { return }
        if trip.startLatitude == nil, loc.horizontalAccuracy < 50 {
            trip.startLatitude = loc.coordinate.latitude
            trip.startLongitude = loc.coordinate.longitude
        }
        trip.lastKnownLatitude = loc.coordinate.latitude
        trip.lastKnownLongitude = loc.coordinate.longitude
        trip.lastKnownAt = loc.timestamp
        if Date().timeIntervalSince(lastPersist) > 30 {
            try? context.save()
            lastPersist = Date()
        }
    }
}
