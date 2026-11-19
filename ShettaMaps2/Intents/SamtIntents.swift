import AppIntents
import CoreLocation
import SwiftData

// MARK: - اختصارات Siri

/// أفضل موقع متاح: من مدير الموقع إن كان يعمل، وإلا آخر موقع يحتفظ به النظام.
@MainActor
private func currentLocation() -> CLLocation? {
    LocationManager.shared.location ?? CLLocationManager().location
}

struct SaveMyLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "احفظ موقعي"
    static let description = IntentDescription("يحفظ موقعك الحالي في الأماكن المحفوظة.")
    static let openAppWhenRun = false

    @Parameter(title: "الاسم") var name: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let loc = currentLocation(), loc.horizontalAccuracy >= 0 else {
            return .result(dialog: "لم أتمكن من تحديد موقعك الآن. افتح سَمْت وحاول مرة أخرى.")
        }
        let ctx = AppEnvironment.shared.container.mainContext
        let general = try? ctx.fetch(FetchDescriptor<PlaceCategory>(predicate: #Predicate { $0.name == "عام" })).first
        let title = name?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? name! : "موقع \(Fmt.dateTime.string(from: Date()))"
        ctx.insert(SavedPlace(name: title, coordinate: loc.coordinate, altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil,
                              horizontalAccuracy: loc.horizontalAccuracy, category: general))
        try ctx.save()
        return .result(dialog: "حفظت موقعك باسم «\(title)»، بدقة \(Fmt.distance(loc.horizontalAccuracy)).")
    }
}

struct RemainingDistanceIntent: AppIntent {
    static let title: LocalizedStringResource = "كم باقي على الوجهة"
    static let description = IntentDescription("يخبرك بالمسافة والاتجاه المتبقيين في الملاحة الحالية.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let s = SharedNavigationState.shared.snapshot
        guard s.isNavigating, let p = s.progress else {
            return .result(dialog: "لا توجد ملاحة نشطة الآن.")
        }
        if s.status == .arrived { return .result(dialog: "وصلت إلى \(p.target.name).") }
        var text = "باقي \(Fmt.distance(p.remainingDistance)) على \(s.plan?.destination.name ?? p.target.name)"
        text += "، والاتجاه \(GeoMath.cardinalName(p.bearingToTarget))"
        if let sec = p.estimatedSeconds, sec > 0 { text += "، تقريبًا \(Fmt.duration(sec))" }
        return .result(dialog: "\(text).")
    }
}

struct WhereAmIIntent: AppIntent {
    static let title: LocalizedStringResource = "وين أنا"
    static let description = IntentDescription("يخبرك بأقرب بلدة واتجاهها، ويعطيك إحداثياتك.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let loc = currentLocation() else {
            return .result(value: "", dialog: "لم أتمكن من تحديد موقعك الآن.")
        }
        let coords = CoordinateUtilities.format(loc.coordinate, as: .decimal)
        var text = ""
        if let (town, m) = SearchService.shared.nearest(.town, to: loc.coordinate, count: 1).first {
            let dir = GeoMath.cardinalName(GeoMath.bearing(from: .init(latitude: town.lat, longitude: town.lon), to: loc.coordinate))
            text = "أنت على بعد \(Fmt.distance(m)) \(dir) \(town.name). "
        }
        text += "إحداثياتك \(coords)."
        return .result(value: coords, dialog: "\(text)")
    }
}

struct StopNavigationIntent: AppIntent {
    static let title: LocalizedStringResource = "أوقف الملاحة"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard SharedNavigationState.shared.snapshot.isNavigating else { return .result(dialog: "لا توجد ملاحة نشطة.") }
        SharedNavigationState.shared.stop()
        return .result(dialog: "أوقفت الملاحة.")
    }
}

// MARK: - الملاحة إلى مكان محفوظ

struct SavedPlaceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "مكان محفوظ"
    static let defaultQuery = SavedPlaceQuery()
    var id: UUID
    var name: String
    var lat: Double
    var lon: Double
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

struct SavedPlaceQuery: EntityStringQuery {
    @MainActor private func all() -> [SavedPlaceEntity] {
        let ctx = AppEnvironment.shared.container.mainContext
        let places = (try? ctx.fetch(FetchDescriptor<SavedPlace>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        return places.map { SavedPlaceEntity(id: $0.id, name: $0.name, lat: $0.latitude, lon: $0.longitude) }
    }
    @MainActor func entities(for identifiers: [UUID]) async throws -> [SavedPlaceEntity] {
        all().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [SavedPlaceEntity] {
        let key = SearchService.searchKey(string)
        return all().filter { SearchService.searchKey($0.name).contains(key) }
    }
    @MainActor func suggestedEntities() async throws -> [SavedPlaceEntity] { Array(all().prefix(20)) }
}

struct NavigateToPlaceIntent: AppIntent {
    static let title: LocalizedStringResource = "ودّني لمكان محفوظ"
    static let description = IntentDescription("يبدأ الملاحة المباشرة إلى أحد أماكنك المحفوظة.")
    static let openAppWhenRun = true

    @Parameter(title: "المكان") var place: SavedPlaceEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SharedNavigationState.shared.navigate(to: Waypoint(name: place.name, coordinate: .init(latitude: place.lat, longitude: place.lon)))
        return .result(dialog: "بدأت الملاحة إلى \(place.name).")
    }
}

struct SamtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveMyLocationIntent(), phrases: [
            "احفظ موقعي في \(.applicationName)", "\(.applicationName) احفظ موقعي", "سجل موقعي في \(.applicationName)"
        ], shortTitle: "احفظ موقعي", systemImageName: "mappin.and.ellipse")
        AppShortcut(intent: RemainingDistanceIntent(), phrases: [
            "كم باقي في \(.applicationName)", "\(.applicationName) كم باقي", "كم باقي على الوجهة في \(.applicationName)"
        ], shortTitle: "كم باقي", systemImageName: "flag.checkered")
        AppShortcut(intent: WhereAmIIntent(), phrases: [
            "وين أنا في \(.applicationName)", "\(.applicationName) وين أنا", "إحداثياتي في \(.applicationName)"
        ], shortTitle: "وين أنا", systemImageName: "location")
        AppShortcut(intent: NavigateToPlaceIntent(), phrases: [
            "ودّني \(\.$place) في \(.applicationName)", "\(.applicationName) ودّني \(\.$place)", "ملاحة إلى مكان في \(.applicationName)"
        ], shortTitle: "ودّني لمكان", systemImageName: "location.north.line")
        AppShortcut(intent: StopNavigationIntent(), phrases: [
            "أوقف الملاحة في \(.applicationName)", "\(.applicationName) أوقف الملاحة"
        ], shortTitle: "أوقف الملاحة", systemImageName: "stop.circle")
    }
}
