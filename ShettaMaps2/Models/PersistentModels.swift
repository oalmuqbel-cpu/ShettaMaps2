import Foundation
import SwiftData
import CoreLocation

// جميع الخصائص لها قيم افتراضية والعلاقات اختيارية لتكون متوافقة مع مزامنة CloudKit الاختيارية.

@Model
final class PlaceCategory {
    var id: UUID = UUID()
    var name: String = ""
    var iconName: String = "mappin"
    var colorHex: String = "D9822B"
    var sortOrder: Int = 0
    @Relationship(deleteRule: .nullify, inverse: \SavedPlace.category)
    var places: [SavedPlace]? = []

    init(name: String, iconName: String = "mappin", colorHex: String = "D9822B", sortOrder: Int = 0) {
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }

    /// التصنيفات الافتراضية عند أول تشغيل.
    static let defaults: [(String, String, String)] = [
        ("مخيمات", "tent", "D9822B"),
        ("جبال", "mountain.2", "6B4423"),
        ("أودية وشعبان", "water.waves", "3A7CA5"),
        ("فياض وروضات", "leaf", "4E8A3E"),
        ("آبار ومياه", "drop", "2C6E91"),
        ("نقاط تزود", "fuelpump", "B23A48"),
        ("عام", "mappin", "7A6A58")
    ]
}

@Model
final class SavedPlace {
    var id: UUID = UUID()
    var name: String = ""
    var notes: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var altitude: Double?
    var horizontalAccuracy: Double?
    var isFavorite: Bool = false
    /// عام: منشور في المشاركة المجتمعية. خاص (الافتراضي): يبقى على الجهاز فقط.
    var isPublic: Bool = false
    var publicID: String?
    var publicKind: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var category: PlaceCategory?
    /// صور المكان (خاصة): تُحفظ على الجهاز وتُزامن مع iCloud إن كانت المزامنة مفعّلة.
    @Relationship(deleteRule: .cascade, inverse: \PlacePhoto.place) var photos: [PlacePhoto]? = []

    init(name: String, coordinate: CLLocationCoordinate2D, notes: String = "", altitude: Double? = nil,
         horizontalAccuracy: Double? = nil, category: PlaceCategory? = nil) {
        self.name = name
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
        self.notes = notes
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.category = category
    }

    var coordinate: CLLocationCoordinate2D {
        get { .init(latitude: latitude, longitude: longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude; updatedAt = Date() }
    }

    var asWaypoint: Waypoint { Waypoint(id: id, name: name, coordinate: coordinate) }
}

@Model
final class RecordedTrack {
    var id: UUID = UUID()
    var name: String = ""
    var startedAt: Date = Date()
    var endedAt: Date?
    var distanceMeters: Double = 0
    var movingSeconds: Double = 0
    var elapsedSeconds: Double = 0
    var maxSpeed: Double = 0
    var pointCount: Int = 0
    /// false أثناء التسجيل؛ يسمح باستعادة مسار غير مكتمل بعد إغلاق مفاجئ للتطبيق.
    var isComplete: Bool = false
    var isImported: Bool = false
    /// معرّف المسار إن كان منشورًا في مسارات المجتمع.
    var publicID: String?
    @Attribute(.externalStorage) var pointsData: Data?
    var trip: Trip?

    init(name: String, startedAt: Date = Date()) {
        self.name = name
        self.startedAt = startedAt
    }

    var points: [TrackPoint] {
        get { TrackPointCodec.decode(pointsData) }
        set {
            pointsData = TrackPointCodec.encode(newValue)
            pointCount = newValue.count
        }
    }

    var averageMovingSpeed: Double {
        movingSeconds > 0 ? distanceMeters / movingSeconds : 0
    }
}

@Model
final class Trip {
    var id: UUID = UUID()
    var name: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var endedAt: Date?
    var isActive: Bool = false
    var startLatitude: Double?
    var startLongitude: Double?
    var startName: String = "نقطة البداية"
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    var destinationName: String = ""
    var stopsData: Data?
    var lastKnownLatitude: Double?
    var lastKnownLongitude: Double?
    var lastKnownAt: Date?
    var autoRecord: Bool = true
    @Relationship(deleteRule: .nullify, inverse: \RecordedTrack.trip)
    var tracks: [RecordedTrack]? = []

    init(name: String) {
        self.name = name
    }

    var startCoordinate: CLLocationCoordinate2D? {
        guard let a = startLatitude, let b = startLongitude else { return nil }
        return .init(latitude: a, longitude: b)
    }

    var destination: Waypoint? {
        guard let a = destinationLatitude, let b = destinationLongitude else { return nil }
        return Waypoint(name: destinationName.isEmpty ? "الوجهة" : destinationName,
                        coordinate: .init(latitude: a, longitude: b))
    }

    var lastKnownCoordinate: CLLocationCoordinate2D? {
        guard let a = lastKnownLatitude, let b = lastKnownLongitude else { return nil }
        return .init(latitude: a, longitude: b)
    }

    var stops: [Waypoint] {
        get {
            guard let stopsData else { return [] }
            return (try? JSONDecoder().decode([Waypoint].self, from: stopsData)) ?? []
        }
        set { stopsData = try? JSONEncoder().encode(newValue) }
    }

    var totalDistance: Double {
        (tracks ?? []).reduce(0) { $0 + $1.distanceMeters }
    }
}

@Model
final class PlacePhoto {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var place: SavedPlace?

    init(imageData: Data, thumbnailData: Data?) {
        self.imageData = imageData
        self.thumbnailData = thumbnailData
    }
}

enum AppSchema {
    static let models: [any PersistentModel.Type] = [PlaceCategory.self, SavedPlace.self, PlacePhoto.self, RecordedTrack.self, Trip.self]
}
