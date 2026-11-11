import Foundation
import SwiftData

/// نسخ احتياطي واستعادة لكل بيانات المستخدم في ملف JSON واحد يبقى على جهازه.
enum BackupService {
    struct Backup: Codable {
        var version = 1
        var createdAt = Date()
        var categories: [Category]
        var places: [Place]
        var tracks: [Track]
        var trips: [TripDTO]

        struct Category: Codable { var id: UUID; var name: String; var icon: String; var color: String; var order: Int }
        struct Place: Codable {
            var id: UUID; var name: String; var notes: String; var lat: Double; var lon: Double
            var alt: Double?; var favorite: Bool; var created: Date; var categoryID: UUID?
        }
        struct Track: Codable {
            var id: UUID; var name: String; var started: Date; var ended: Date?
            var distance: Double; var moving: Double; var elapsed: Double; var maxSpeed: Double
            var points: [TrackPoint]; var tripID: UUID?
        }
        struct TripDTO: Codable {
            var id: UUID; var name: String; var notes: String; var created: Date; var ended: Date?
            var startLat: Double?; var startLon: Double?; var startName: String
            var destLat: Double?; var destLon: Double?; var destName: String
            var stops: [Waypoint]
        }
    }

    struct ImportSummary { var places = 0; var tracks = 0; var trips = 0; var skipped = 0 }

    @MainActor
    static func makeBackup(context: ModelContext) throws -> URL {
        let cats = try context.fetch(FetchDescriptor<PlaceCategory>())
        let places = try context.fetch(FetchDescriptor<SavedPlace>())
        let tracks = try context.fetch(FetchDescriptor<RecordedTrack>(predicate: #Predicate { $0.isComplete == true }))
        let trips = try context.fetch(FetchDescriptor<Trip>())

        let backup = Backup(
            categories: cats.map { .init(id: $0.id, name: $0.name, icon: $0.iconName, color: $0.colorHex, order: $0.sortOrder) },
            places: places.map { .init(id: $0.id, name: $0.name, notes: $0.notes, lat: $0.latitude, lon: $0.longitude,
                                       alt: $0.altitude, favorite: $0.isFavorite, created: $0.createdAt, categoryID: $0.category?.id) },
            tracks: tracks.map { .init(id: $0.id, name: $0.name, started: $0.startedAt, ended: $0.endedAt,
                                       distance: $0.distanceMeters, moving: $0.movingSeconds, elapsed: $0.elapsedSeconds,
                                       maxSpeed: $0.maxSpeed, points: $0.points, tripID: $0.trip?.id) },
            trips: trips.map { .init(id: $0.id, name: $0.name, notes: $0.notes, created: $0.createdAt, ended: $0.endedAt,
                                     startLat: $0.startLatitude, startLon: $0.startLongitude, startName: $0.startName,
                                     destLat: $0.destinationLatitude, destLon: $0.destinationLongitude,
                                     destName: $0.destinationName, stops: $0.stops) })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(backup)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShettaMaps2-Backup-\(f.string(from: Date())).json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// استعادة دون حذف البيانات الحالية؛ العناصر الموجودة بنفس المعرّف تُتجاهل.
    @MainActor
    static func restore(from url: URL, context: ModelContext) throws -> ImportSummary {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: Data(contentsOf: url))

        var summary = ImportSummary()
        let existingCats = try context.fetch(FetchDescriptor<PlaceCategory>())
        var catByID = Dictionary(existingCats.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for c in backup.categories where catByID[c.id] == nil {
            if let sameName = existingCats.first(where: { $0.name == c.name }) {
                catByID[c.id] = sameName; continue
            }
            let cat = PlaceCategory(name: c.name, iconName: c.icon, colorHex: c.color, sortOrder: c.order)
            cat.id = c.id
            context.insert(cat)
            catByID[c.id] = cat
        }

        let placeIDs = Set(try context.fetch(FetchDescriptor<SavedPlace>()).map(\.id))
        for p in backup.places {
            guard !placeIDs.contains(p.id) else { summary.skipped += 1; continue }
            let place = SavedPlace(name: p.name, coordinate: .init(latitude: p.lat, longitude: p.lon), notes: p.notes,
                                   altitude: p.alt, category: p.categoryID.flatMap { catByID[$0] })
            place.id = p.id
            place.isFavorite = p.favorite
            place.createdAt = p.created
            context.insert(place)
            summary.places += 1
        }

        let existingTrips = try context.fetch(FetchDescriptor<Trip>())
        var tripByID = Dictionary(existingTrips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in backup.trips where tripByID[t.id] == nil {
            let trip = Trip(name: t.name)
            trip.id = t.id; trip.notes = t.notes; trip.createdAt = t.created; trip.endedAt = t.ended ?? t.created
            trip.startLatitude = t.startLat; trip.startLongitude = t.startLon; trip.startName = t.startName
            trip.destinationLatitude = t.destLat; trip.destinationLongitude = t.destLon; trip.destinationName = t.destName
            trip.stops = t.stops
            trip.isActive = false
            context.insert(trip)
            tripByID[t.id] = trip
            summary.trips += 1
        }

        let trackIDs = Set(try context.fetch(FetchDescriptor<RecordedTrack>()).map(\.id))
        for t in backup.tracks {
            guard !trackIDs.contains(t.id) else { summary.skipped += 1; continue }
            let track = RecordedTrack(name: t.name, startedAt: t.started)
            track.id = t.id; track.endedAt = t.ended
            track.distanceMeters = t.distance; track.movingSeconds = t.moving
            track.elapsedSeconds = t.elapsed; track.maxSpeed = t.maxSpeed
            track.points = t.points
            track.isComplete = true
            track.trip = t.tripID.flatMap { tripByID[$0] }
            context.insert(track)
            summary.tracks += 1
        }
        try context.save()
        return summary
    }
}
