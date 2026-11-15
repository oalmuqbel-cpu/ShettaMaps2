import UIKit
import CarPlay
import MapKit
import SwiftData
import Combine

/// قوائم CarPlay: الوجهات، البحث، الطبقات، والمزيد. مصممة لتُستخدم كاملة من شاشة السيارة دون الحاجة للهاتف.
extension CarPlayTemplateManager {

    // MARK: - أدوات مشتركة

    var here: CLLocationCoordinate2D? { env.location.location?.coordinate }

    /// يقصّ الأقسام لتلتزم بحدود السيارة (عدد العناصر والأقسام).
    func capped(_ sections: [CPListSection]) -> [CPListSection] {
        var remaining = Int(CPListTemplate.maximumItemCount)
        var out: [CPListSection] = []
        for s in sections.prefix(Int(CPListTemplate.maximumSectionCount)) where remaining > 0 {
            let items = Array(s.items.prefix(remaining))
            remaining -= items.count
            out.append(CPListSection(items: items, header: s.header, sectionIndexTitle: nil))
        }
        return out
    }

    func push(_ title: String, _ sections: [CPListSection], empty: String = "لا توجد عناصر") -> CPListTemplate {
        let t = CPListTemplate(title: title, sections: capped(sections))
        t.emptyViewTitleVariants = [empty]
        interfaceController.pushTemplate(t, animated: true, completion: nil)
        return t
    }

    func symbol(_ name: String, tint: UIColor? = nil) -> UIImage? {
        let img = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        guard let tint else { return img }
        return img?.withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// صورة حالة لعنصر يُفعَّل ويُطفأ.
    func checkImage(_ on: Bool) -> UIImage? {
        on ? symbol("checkmark.circle.fill", tint: .systemGreen) : symbol("circle", tint: .systemGray)
    }

    func distanceText(to c: CLLocationCoordinate2D) -> String? {
        guard let here else { return nil }
        return "\(Fmt.distance(GeoMath.distance(here, c))) · \(GeoMath.cardinalName(GeoMath.bearing(from: here, to: c)))"
    }

    func navItem(_ name: String, detail: String?, icon: String, coordinate: CLLocationCoordinate2D, id: UUID? = nil) -> CPListItem {
        let item = CPListItem(text: name, detailText: distanceText(to: coordinate) ?? detail, image: symbol(icon))
        let w = Waypoint(id: id ?? UUID(), name: name, coordinate: coordinate)
        item.handler = { [weak self] _, done in
            self?.preview(w)
            done()
        }
        return item
    }

    func folder(_ title: String, detail: String? = nil, icon: String, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail, image: symbol(icon), accessoryImage: nil, accessoryType: .disclosureIndicator)
        item.handler = { _, done in action(); done() }
        return item
    }

    func savedPlaces() -> [SavedPlace] {
        (try? env.container.mainContext.fetch(FetchDescriptor<SavedPlace>())) ?? []
    }

    func sortByDistance(_ list: [SavedPlace]) -> [SavedPlace] {
        guard let here else { return list.sorted { $0.name < $1.name } }
        return list.sorted { GeoMath.distance(here, $0.coordinate) < GeoMath.distance(here, $1.coordinate) }
    }

    func placeItems(_ list: [SavedPlace]) -> [CPListItem] {
        sortByDistance(list).map {
            navItem($0.name, detail: $0.category?.name, icon: $0.category?.iconName ?? "mappin", coordinate: $0.coordinate, id: $0.id)
        }
    }

    // MARK: - المعاينة قبل الملاحة

    /// يعرض الوجهة على الخريطة مع زر «ابدأ» (أسلوب CarPlay القياسي). أثناء الملاحة يطلب تأكيد تغيير الوجهة.
    func preview(_ w: Waypoint) {
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        if env.navigation.snapshot.isNavigating {
            let change = CPAlertAction(title: "تغيير الوجهة", style: .default) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
                self?.env.navigation.navigate(to: w)
            }
            let cancel = CPAlertAction(title: "إلغاء", style: .cancel) { [weak self] _ in
                self?.interfaceController.dismissTemplate(animated: true, completion: nil)
            }
            interfaceController.presentTemplate(CPAlertTemplate(titleVariants: ["الملاحة إلى \(w.name)؟"], actions: [change, cancel]),
                                                animated: true, completion: nil)
            return
        }
        previewWaypoint = w
        let origin = MKMapItem(placemark: MKPlacemark(coordinate: here ?? w.coordinate))
        origin.name = "موقعي"
        let dest = MKMapItem(placemark: MKPlacemark(coordinate: w.coordinate))
        dest.name = w.name
        let summary = distanceText(to: w.coordinate) ?? w.name
        // خياران: عبر الطرق (عند توفر الإنترنت) أو خط مباشر للصحراء
        var choices: [CPRouteChoice] = []
        if env.network.isOnline {
            let road = CPRouteChoice(summaryVariants: ["عبر الطرق", "طرق"],
                                     additionalInformationVariants: ["تعليمات منعطف بمنعطف من خرائط Apple عند توفر طريق"],
                                     selectionSummaryVariants: ["عبر الطرق · \(summary)"])
            road.userInfo = GuidanceMode.road.rawValue
            choices.append(road)
        }
        let direct = CPRouteChoice(summaryVariants: ["خط مباشر", "مباشر"],
                                   additionalInformationVariants: ["اتجاه ومسافة فقط، وليس طريقًا مضمونًا. يعمل دون إنترنت"],
                                   selectionSummaryVariants: ["خط مباشر · \(summary)"])
        direct.userInfo = GuidanceMode.direct.rawValue
        choices.append(direct)
        let trip = CPTrip(origin: origin, destination: dest, routeChoices: choices)
        mapTemplate.showTripPreviews([trip], textConfiguration: CPTripPreviewTextConfiguration(
            startButtonTitle: "ابدأ", additionalRoutesButtonTitle: "خيارات", overviewButtonTitle: nil))
        mapViewController.showPreview(w.coordinate)
        updateBarButtons()
    }

    func cancelPreview() {
        mapTemplate.hideTripPreviews()
        previewWaypoint = nil
        mapViewController.showPreview(nil)
        updateBarButtons()
    }

    // MARK: - الوجهات

    func showDestinations() {
        let places = savedPlaces()
        var sections: [CPListSection] = []

        // الرحلة النشطة
        var tripItems: [CPListItem] = []
        if let trip = env.trips.activeTrip {
            if let start = trip.startCoordinate {
                let item = CPListItem(text: "العودة إلى نقطة البداية", detailText: distanceText(to: start),
                                      image: symbol("arrow.uturn.backward.circle"))
                item.handler = { [weak self] _, done in
                    self?.env.trips.returnToStart(of: trip)
                    self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
                    done()
                }
                tripItems.append(item)
            }
            if !trip.stops.isEmpty || trip.destination != nil {
                let item = CPListItem(text: "الملاحة عبر نقاط التوقف", detailText: "\(trip.stops.count) توقف",
                                      image: symbol("point.3.connected.trianglepath.dotted"))
                item.handler = { [weak self] _, done in
                    self?.env.trips.navigateTrip(trip)
                    self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
                    done()
                }
                tripItems.append(item)
            }
        }
        if !tripItems.isEmpty { sections.append(CPListSection(items: tripItems, header: "الرحلة النشطة", sectionIndexTitle: nil)) }

        // الأخيرة: وجهة سابقة بلمستين («ابدأ» بعدها)
        let recents = RecentDestinations.load().prefix(3).map {
            navItem($0.name, detail: nil, icon: "clock.arrow.circlepath", coordinate: $0.coordinate, id: $0.id)
        }
        if !recents.isEmpty { sections.append(CPListSection(items: Array(recents), header: "الأخيرة", sectionIndexTitle: nil)) }

        // المفضلة مباشرة (الأقرب أولًا)
        let favorites = places.filter(\.isFavorite)
        if !favorites.isEmpty {
            var fav = Array(placeItems(favorites).prefix(4))
            if favorites.count > 4 {
                fav.append(folder("كل المفضلة", detail: "\(favorites.count)", icon: "star.fill") { [weak self] in
                    guard let self else { return }
                    _ = self.push("المفضلة", [CPListSection(items: self.placeItems(favorites))])
                })
            }
            sections.append(CPListSection(items: fav, header: "المفضلة", sectionIndexTitle: nil))
        }

        // المواقع المحفوظة
        var saved: [CPListItem] = []
        if !places.isEmpty {
            saved.append(folder("كل مواقعي (الأقرب أولًا)", detail: "\(places.count)", icon: "mappin.and.ellipse") { [weak self] in
                guard let self else { return }
                _ = self.push("مواقعي", [CPListSection(items: self.placeItems(places))])
            })
            saved.append(folder("حسب التصنيف", icon: "folder") { [weak self] in self?.showCategories(places) })
        }
        if saved.isEmpty {
            saved.append(CPListItem(text: "لا توجد مواقع محفوظة", detailText: "احفظ موقعك من «المزيد» أو من الهاتف"))
        }
        sections.append(CPListSection(items: saved, header: "المواقع المحفوظة", sectionIndexTitle: nil))

        // أماكن قريبة
        var nearby: [CPListItem] = [
            folder("أماكن قريبة حسب النوع", icon: "binoculars") { [weak self] in self?.showNearbyKinds() },
            folder("أقرب محطات الوقود", icon: "fuelpump.fill") { [weak self] in self?.showNearby(.fuel) }
        ]
        if CommunityService.shared.isEnabled {
            nearby.append(folder("مشاركات المجتمع القريبة", icon: "person.2.fill") { [weak self] in self?.showCommunityNearby() })
        }
        nearby.append(folder("بدايات مساراتي السابقة", icon: "point.topleft.down.to.point.bottomright.curvepath") { [weak self] in
            self?.showTracks()
        })
        sections.append(CPListSection(items: nearby, header: "استكشاف", sectionIndexTitle: nil))

        _ = push("الوجهات", sections, empty: "لا توجد وجهات")
    }

    func showCategories(_ places: [SavedPlace]) {
        var groups: [String: [SavedPlace]] = [:]
        var icons: [String: String] = [:]
        for p in places {
            let name = p.category?.name ?? "بدون تصنيف"
            groups[name, default: []].append(p)
            icons[name] = p.category?.iconName ?? "mappin"
        }
        let items = groups.keys.sorted().map { name in
            folder(name, detail: "\(groups[name]?.count ?? 0)", icon: icons[name] ?? "mappin") { [weak self] in
                guard let self else { return }
                _ = self.push(name, [CPListSection(items: self.placeItems(groups[name] ?? []))])
            }
        }
        _ = push("حسب التصنيف", [CPListSection(items: items)])
    }

    func showNearbyKinds() {
        let kinds: [PlaceKind] = [.nafud, .rawdah, .mountain, .valley, .water, .cave, .camp, .shaib, .landmark, .fuel]
        let items = kinds.map { k in folder(k.title, icon: k.icon) { [weak self] in self?.showNearby(k) } }
        _ = push("أماكن قريبة", [CPListSection(items: items)])
    }

    func showNearby(_ kind: PlaceKind) {
        guard let here else {
            _ = push(kind.title, [], empty: "بانتظار تحديد موقعك")
            return
        }
        let list = SearchService.shared.nearest(kind, to: here, count: 12)
        let items = list.map { pair -> CPListItem in
            let e = pair.0
            return navItem(e.name, detail: kind.title, icon: kind.icon, coordinate: .init(latitude: e.lat, longitude: e.lon))
        }
        _ = push(kind.title, [CPListSection(items: items)], empty: "لا توجد أماكن معروفة من هذا النوع")
    }

    func showCommunityNearby() {
        guard let here else { _ = push("مشاركات المجتمع", [], empty: "بانتظار تحديد موقعك"); return }
        let sw = CLLocationCoordinate2D(latitude: here.latitude - 0.6, longitude: here.longitude - 0.6)
        let ne = CLLocationCoordinate2D(latitude: here.latitude + 0.6, longitude: here.longitude + 0.6)
        let list = CommunityService.shared.places(in: sw, ne)
            .sorted { GeoMath.distance(here, $0.coordinate) < GeoMath.distance(here, $1.coordinate) }
            .prefix(12)
        let items = list.map { navItem($0.name, detail: $0.kind.title, icon: "person.2.fill", coordinate: $0.coordinate) }
        _ = push("مشاركات المجتمع", [CPListSection(items: Array(items))], empty: "لا توجد مشاركات قريبة")
    }

    func showTracks() {
        var d = FetchDescriptor<RecordedTrack>(predicate: #Predicate { $0.isComplete },
                                               sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        d.fetchLimit = 12
        let tracks = (try? env.container.mainContext.fetch(d)) ?? []
        let items: [CPListItem] = tracks.compactMap { t in
            guard let first = t.points.first?.coordinate else { return nil }
            let name = t.name.isEmpty ? "مسار \(Fmt.dateTime.string(from: t.startedAt))" : t.name
            return navItem("بداية: \(name)", detail: Fmt.distance(t.distanceMeters), icon: "flag.fill", coordinate: first)
        }
        _ = push("مساراتي السابقة", [CPListSection(items: items)], empty: "لا توجد مسارات مسجلة")
    }

    // MARK: - البحث

    func showSearch() {
        let t = CPSearchTemplate()
        t.delegate = self
        interfaceController.pushTemplate(t, animated: true, completion: nil)
    }

    func searchItems(_ text: String) -> [CPListItem] {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var results = SearchService.shared.searchLocal(q, kind: .all, places: savedPlaces(), near: here, limit: 12)
        if CommunityService.shared.isEnabled {
            results += CommunityService.shared.search(q, near: here).prefix(4)
        }
        return results.prefix(Int(CPListTemplate.maximumItemCount)).map { r in
            let item = CPListItem(text: r.name, detailText: distanceText(to: r.coordinate) ?? r.subtitle,
                                  image: symbol(r.source == .saved ? "mappin" : r.kind.icon))
            item.userInfo = r.waypoint
            return item
        }
    }

    // MARK: - الطبقات

    func showLayers() {
        let t = CPListTemplate(title: "الطبقات", sections: capped(layerSections()))
        layersTemplate = t
        interfaceController.pushTemplate(t, animated: true, completion: nil)
    }

    func reloadLayers() {
        layersTemplate?.updateSections(capped(layerSections()))
    }

    func layerSections() -> [CPListSection] {
        let offline = env.offlineMaps
        let current = mapViewController.engine

        var types: [CPListItem] = []
        for e in [CarPlayMapEngine.mapKitStandard, .mapKitTerrain, .mapKitSatellite] {
            let item = CPListItem(text: e.title, detailText: env.network.isOnline ? nil : "يتطلب الإنترنت",
                                  image: checkImage(current == e))
            item.handler = { [weak self] _, done in
                self?.mapViewController.setEngine(e)
                self?.reloadLayers()
                done()
            }
            types.append(item)
        }
        let vectorOn = current == .offline && offline.selectedTilesetID == nil
        let vector = CPListItem(text: "دون إنترنت: خريطة الطرق", detailText: offlineDetail(tileset: nil), image: checkImage(vectorOn))
        vector.handler = { [weak self] _, done in
            self?.env.offlineMaps.selectedTilesetID = nil
            self?.mapViewController.setEngine(.offline, force: true)
            self?.reloadLayers()
            done()
        }
        types.append(vector)
        // ملفات الخرائط المستوردة (مثل صور أقمار صناعية دون إنترنت)
        for t in offline.tilesets {
            let on = current == .offline && offline.selectedTilesetID == t.id
            let item = CPListItem(text: "دون إنترنت: \(t.name)", detailText: offlineDetail(tileset: t), image: checkImage(on))
            let id = t.id
            item.handler = { [weak self] _, done in
                self?.env.offlineMaps.selectedTilesetID = id
                self?.mapViewController.setEngine(.offline, force: true)
                self?.reloadLayers()
                done()
            }
            types.append(item)
        }

        let layers: [CPListItem] = [
            toggle("أسماء الأماكن المعروفة", SettingsKeys.showLandmarks, true),
            toggle("الردميات والطرق الترابية", SettingsKeys.showDirtRoads, true),
            toggle("طرق مرصودة من الأقمار الصناعية", SettingsKeys.showDetectedRoads, true),
            toggle("مشاركات المجتمع", SettingsKeys.showCommunity, true),
            toggle("مساراتي السابقة", SettingsKeys.showMyTracks, false),
            toggle("تغطية الشبكة", SettingsKeys.showCoverage, false),
            toggle("الأمطار المتوقعة", SettingsKeys.showRainMap, false)
        ]

        let northUp = CarPlaySettings.northUp
        let heading = CPListItem(text: "اتجاه الخريطة", detailText: northUp ? "الشمال للأعلى" : "مع اتجاه السير",
                                 image: symbol(northUp ? "location.north.line" : "location.north.line.fill"))
        heading.handler = { [weak self] _, done in
            CarPlaySettings.toggle(CarPlaySettings.northUpKey, false)
            self?.reloadLayers()
            done()
        }
        let kinds = CarPlaySettings.landmarkKinds
        let kindsItem = folder("أنواع الأماكن الظاهرة", detail: kinds.isEmpty ? "الكل" : "\(kinds.count) أنواع", icon: "line.3.horizontal.decrease.circle") {
            [weak self] in self?.showLandmarkKinds()
        }

        return [
            CPListSection(items: types, header: "نوع الخريطة", sectionIndexTitle: nil),
            CPListSection(items: layers, header: "على الخريطة", sectionIndexTitle: nil),
            CPListSection(items: [heading, kindsItem], header: "العرض", sectionIndexTitle: nil)
        ]
    }

    func offlineDetail(tileset: LocalTileset?) -> String {
        guard let here else { return "الخرائط المنزلة" }
        if let t = tileset { return t.contains(here) ? "يغطي موقعك" : "خارج موقعك الحالي" }
        let covered = env.offlineMaps.regions.contains { $0.state == .complete && $0.contains(here) }
        return covered ? "منزلة لموقعك" : "لا توجد منطقة منزلة هنا"
    }

    func toggle(_ title: String, _ key: String, _ fallback: Bool) -> CPListItem {
        let on = CarPlaySettings.bool(key, fallback)
        let item = CPListItem(text: title, detailText: on ? "ظاهرة" : "مخفية", image: checkImage(on))
        item.handler = { [weak self] _, done in
            CarPlaySettings.toggle(key, fallback)
            self?.reloadLayers()
            done()
        }
        return item
    }

    func showLandmarkKinds() {
        let t = CPListTemplate(title: "أنواع الأماكن", sections: kindSections())
        interfaceController.pushTemplate(t, animated: true, completion: nil)
        kindsTemplate = t
    }

    func kindSections() -> [CPListSection] {
        let selected = CarPlaySettings.landmarkKinds
        let all = CPListItem(text: "كل الأنواع", detailText: nil, image: checkImage(selected.isEmpty))
        all.handler = { [weak self] _, done in
            UserDefaults.standard.set("", forKey: SettingsKeys.landmarkKinds)
            self?.reloadKinds()
            done()
        }
        let items = PlaceKind.mapKinds.map { k in
            let item = CPListItem(text: k.title, detailText: nil, image: checkImage(selected.contains(k)))
            item.handler = { [weak self] _, done in
                var s = CarPlaySettings.landmarkKinds
                if s.contains(k) { s.remove(k) } else { s.insert(k) }
                UserDefaults.standard.set(PlaceKind.encodeSet(s), forKey: SettingsKeys.landmarkKinds)
                self?.reloadKinds()
                done()
            }
            return item
        }
        return capped([CPListSection(items: [all] + items)])
    }

    func reloadKinds() {
        kindsTemplate?.updateSections(kindSections())
        reloadLayers()
    }

    // MARK: - المزيد

    func showMore() {
        let t = CPListTemplate(title: "المزيد", sections: capped(moreSections()))
        moreTemplate = t
        interfaceController.pushTemplate(t, animated: true, completion: nil)
        if let c = here { Task { [weak self] in await WeatherService.shared.refresh(at: c); self?.reloadMore() } }
    }

    func reloadMore() { moreTemplate?.updateSections(capped(moreSections())) }

    func moreSections() -> [CPListSection] {
        var location: [CPListItem] = []
        if let loc = env.location.location {
            location.append(CPListItem(text: "موقعي الحالي",
                                       detailText: "\(CoordinateUtilities.shareString(loc.coordinate)) · \(Fmt.accuracy(loc.horizontalAccuracy))",
                                       image: symbol("location")))
            let save = CPListItem(text: "حفظ الموقع الحالي", detailText: "يُحفظ باسم تلقائي ويمكن تعديله من الهاتف",
                                  image: symbol("mappin.and.ellipse"))
            save.handler = { [weak self] _, done in self?.quickSave(loc); done() }
            location.append(save)
        }
        let rec = env.recorder
        let recordItem = CPListItem(text: rec.isActive ? "إنهاء تسجيل المسار" : "بدء تسجيل المسار",
                                    detailText: rec.isActive ? "\(Fmt.distance(rec.distance)) · \(Fmt.duration(rec.elapsed))" : nil,
                                    image: symbol(rec.isActive ? "stop.circle" : "record.circle", tint: rec.isActive ? .systemRed : nil))
        recordItem.handler = { [weak self] _, done in
            guard let self else { done(); return }
            if self.env.recorder.isActive { self.env.recorder.finish() } else { self.env.recorder.start(trip: self.env.trips.activeTrip) }
            self.interfaceController.popToRootTemplate(animated: true, completion: nil)
            done()
        }
        location.append(recordItem)
        if env.navigation.snapshot.isNavigating {
            let overview = CPListItem(text: "عرض المسار كاملًا", detailText: nil, image: symbol("point.topleft.down.to.point.bottomright.curvepath"))
            overview.handler = { [weak self] _, done in
                self?.interfaceController.popToRootTemplate(animated: true, completion: nil)
                self?.mapViewController.showWholeRoute()
                done()
            }
            location.append(overview)
        }

        let download = CPListItem(text: "تنزيل المنطقة الظاهرة",
                                  detailText: env.network.isOnline ? "الخريطة مع الردميات والطبقات" : "يتطلب الإنترنت",
                                  image: symbol("arrow.down.circle"))
        download.handler = { [weak self] _, done in self?.confirmDownload(); done() }
        let regionsCount = env.offlineMaps.regions.count + env.offlineMaps.tilesets.count
        let regions = folder("الخرائط المنزلة", detail: "\(regionsCount)", icon: "map") { [weak self] in self?.showRegions() }

        var weatherItems: [CPListItem] = []
        if let r = WeatherService.shared.report {
            let n = r.now
            weatherItems.append(CPListItem(
                text: "\(Int(n.temperature.rounded()))° · \(WeatherText.describe(n.weatherCode))",
                detailText: "رياح \(Int(n.windSpeed.rounded())) كم/س \(WeatherText.windFrom(n.windDirection))",
                image: symbol(WeatherText.icon(n.weatherCode))))
            if let w = WeatherText.dustWarning(n) {
                weatherItems.append(CPListItem(text: w, detailText: nil, image: symbol("exclamationmark.triangle.fill", tint: .systemOrange)))
            }
        } else {
            weatherItems.append(CPListItem(text: "الطقس", detailText: env.network.isOnline ? "جارٍ التحميل" : "يتطلب الإنترنت",
                                           image: symbol("cloud.sun")))
        }

        // إعدادات القيادة (مشتركة مع الهاتف)
        let voiceOn = VoicePrompter.enabled
        let voice = CPListItem(text: "الإرشاد الصوتي", detailText: voiceOn ? "مفعّل" : "متوقف", image: checkImage(voiceOn))
        voice.handler = { [weak self] _, done in
            UserDefaults.standard.set(!VoicePrompter.enabled, forKey: VoicePrompter.enabledKey)
            self?.reloadMore(); done()
        }
        let alertOn = SpeedAlertSettings.enabled
        let speed = CPListItem(text: "تنبيه تجاوز حد السرعة", detailText: alertOn ? "مفعّل" : "متوقف", image: checkImage(alertOn))
        speed.handler = { [weak self] _, done in
            UserDefaults.standard.set(!SpeedAlertSettings.enabled, forKey: SpeedAlertSettings.enabledKey)
            self?.reloadMore(); done()
        }
        let margin = CPListItem(text: "ينبّه عند", detailText: SpeedAlertSettings.marginText(SpeedAlertSettings.margin) + " · اضغط للتغيير",
                                image: symbol("gauge.with.dots.needle.50percent"))
        margin.handler = { [weak self] _, done in
            UserDefaults.standard.set(SpeedAlertSettings.nextMargin(), forKey: SpeedAlertSettings.marginKey)
            self?.reloadMore(); done()
        }
        var driving = [voice, speed]
        if alertOn { driving.append(margin) }

        return [
            CPListSection(items: location, header: "الموقع والتسجيل", sectionIndexTitle: nil),
            CPListSection(items: driving, header: "القيادة", sectionIndexTitle: nil),
            CPListSection(items: [download, regions], header: "الخرائط دون إنترنت", sectionIndexTitle: nil),
            CPListSection(items: weatherItems, header: "الطقس الآن", sectionIndexTitle: nil)
        ]
    }

    func quickSave(_ loc: CLLocation) {
        let ctx = env.container.mainContext
        let place = SavedPlace(name: "موقع من السيارة \(Fmt.dateTime.string(from: Date()))", coordinate: loc.coordinate,
                               altitude: loc.verticalAccuracy >= 0 ? loc.altitude : nil, horizontalAccuracy: loc.horizontalAccuracy)
        ctx.insert(place)
        try? ctx.save()
        mapViewController.refreshOverlays(force: true)
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        presentAlert(title: "تم حفظ الموقع", subtitle: CoordinateUtilities.shareString(loc.coordinate), duration: 4)
    }

    // MARK: - التنزيل من السيارة

    func confirmDownload() {
        guard env.network.isOnline else {
            presentListAlert("لا يوجد اتصال بالإنترنت", "نزّل الخرائط قبل الخروج من التغطية.")
            return
        }
        guard let r = mapViewController.visibleRegion else { return }
        // منطقة بحجم مناسب حول وسط الخريطة الظاهرة (حد المصدر المجاني)
        let half = min(r.span.latitudeDelta, 1.0) / 2, halfLon = min(r.span.longitudeDelta, 1.0) / 2
        let sw = CLLocationCoordinate2D(latitude: r.center.latitude - half, longitude: r.center.longitude - halfLon)
        let ne = CLLocationCoordinate2D(latitude: r.center.latitude + half, longitude: r.center.longitude + halfLon)
        let km = Int((GeoMath.distance(sw, CLLocationCoordinate2D(latitude: sw.latitude, longitude: ne.longitude)) / 1000).rounded())
        let go = CPAlertAction(title: "تنزيل", style: .default) { [weak self] _ in
            guard let self else { return }
            self.interfaceController.dismissTemplate(animated: true, completion: nil)
            let name = "من السيارة \(Fmt.dateTime.string(from: Date()))"
            Task {
                do {
                    try await OfflinePackageService.shared.downloadRegionAuto(name: name, sw: sw, ne: ne)
                    self.reloadMore()
                    self.presentListAlert("بدأ التنزيل", "تابع التقدم من «الخرائط المنزلة». تُنزَّل الردميات والطبقات معها.")
                } catch {
                    self.presentListAlert("تعذّر التنزيل", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                }
            }
        }
        let cancel = CPAlertAction(title: "إلغاء", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: ["تنزيل منطقة بعرض \(km) كم تقريبًا حول وسط الخريطة؟",
                                                                            "تنزيل المنطقة الظاهرة؟"],
                                                            actions: [go, cancel]), animated: true, completion: nil)
    }

    /// تنبيه يظهر فوق أي قائمة مفتوحة.
    func presentListAlert(_ title: String, _ message: String) {
        let ok = CPAlertAction(title: "حسنًا", style: .cancel) { [weak self] _ in
            self?.interfaceController.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: ["\(title): \(message)", title], actions: [ok]),
                                            animated: true, completion: nil)
    }

    func showRegions() {
        env.offlineMaps.refreshRegions()
        let t = CPListTemplate(title: "الخرائط المنزلة", sections: capped(regionSections()))
        t.emptyViewTitleVariants = ["لا توجد خرائط منزلة"]
        t.emptyViewSubtitleVariants = ["اختر «تنزيل المنطقة الظاهرة» قبل الخروج من التغطية"]
        regionsTemplate = t
        interfaceController.pushTemplate(t, animated: true, completion: nil)
    }

    func reloadRegions() { regionsTemplate?.updateSections(capped(regionSections())) }

    func regionSections() -> [CPListSection] {
        let offline = env.offlineMaps
        let regions: [CPListItem] = offline.regions.map { r in
            let status: String
            switch r.state {
            case .complete: status = "مكتملة · \(Fmt.bytes(Int64(r.bytes)))"
            case .downloading: status = "جارٍ التنزيل \(Int(r.fraction * 100))٪"
            case .paused, .interrupted: status = "متوقفة \(Int(r.fraction * 100))٪ — تُستأنف من الهاتف"
            default: status = "جارٍ القراءة"
            }
            let item = CPListItem(text: r.name, detailText: status, image: symbol(r.state == .complete ? "checkmark.circle" : "arrow.down.circle"))
            let sw = r.sw, ne = r.ne
            item.handler = { [weak self] _, done in
                guard let self else { done(); return }
                self.env.offlineMaps.selectedTilesetID = nil
                self.mapViewController.setEngine(.offline, force: true)
                self.mapViewController.fit([sw, ne])
                self.interfaceController.popToRootTemplate(animated: true, completion: nil)
                done()
            }
            return item
        }
        let files: [CPListItem] = offline.tilesets.map { t in
            let item = CPListItem(text: t.name, detailText: "ملف \(t.format.uppercased()) · تكبير \(t.minZoom)–\(t.maxZoom)", image: symbol("photo"))
            let id = t.id
            let sw = CLLocationCoordinate2D(latitude: t.swLat, longitude: t.swLon), ne = CLLocationCoordinate2D(latitude: t.neLat, longitude: t.neLon)
            item.handler = { [weak self] _, done in
                guard let self else { done(); return }
                self.env.offlineMaps.selectedTilesetID = id
                self.mapViewController.setEngine(.offline, force: true)
                self.mapViewController.fit([sw, ne])
                self.interfaceController.popToRootTemplate(animated: true, completion: nil)
                done()
            }
            return item
        }
        var sections: [CPListSection] = []
        if !regions.isEmpty { sections.append(CPListSection(items: regions, header: "مناطق منزلة", sectionIndexTitle: nil)) }
        if !files.isEmpty { sections.append(CPListSection(items: files, header: "ملفات خرائط (مثل الأقمار الصناعية)", sectionIndexTitle: nil)) }
        return sections
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlayTemplateManager: CPSearchTemplateDelegate {
    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                                    completionHandler: @escaping ([CPListItem]) -> Void) {
        MainActor.assumeIsolated { completionHandler(searchItems(searchText)) }
    }

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                                    completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            if let w = item.userInfo as? Waypoint { preview(w) }
            completionHandler()
        }
    }
}
