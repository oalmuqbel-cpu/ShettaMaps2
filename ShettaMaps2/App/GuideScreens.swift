#if DEBUG
import SwiftUI
import CoreLocation
import SwiftData

/// لالتقاط صور دليل الاستخدام آليًا على المحاكي فقط (نسخة التطوير): يفتح شاشة محددة عبر الوسيط -GuideScreen <اسم>.
@MainActor
enum GuideScreens {
    static var requested: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GuideScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// سجل خطوات اللقطات (يقرؤه خادم البناء).
    static func glog(_ m: String) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("guide.log")
        let line = "\(Date()) \(m)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    static func applyIfRequested(router: AppRouter, mapManager: MapManager) async {
        glog("apply \(requested ?? "-")")
        guard let screen = requested else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let env = AppEnvironment.shared
        let here = CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753)  // ثابت حتى لا يعتمد على موقع المحاكي الافتراضي
        UserDefaults.standard.set("", forKey: SettingsKeys.landmarkKinds)
        // كل لقطة تبدأ من إعدادات العرض الافتراضية
        let d = UserDefaults.standard
        d.set(UserMarkerStyle.dot.rawValue, forKey: SettingsKeys.userMarkerStyle)
        d.set(AppearanceMode.light.rawValue, forKey: SettingsKeys.appearanceMode)
        d.set(false, forKey: SettingsKeys.showMyTracks)
        d.set(false, forKey: SettingsKeys.showCoverage)
        d.set(false, forKey: SettingsKeys.showRainMap)
        mapManager.layer = .standard
        AppearanceController.shared.update()
        switch screen {
        case "map":
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            mapManager.send(.focus(here, spanMeters: 40_000))
        case "record":
            mapManager.send(.focus(here, spanMeters: 8_000))
            env.recorder.start(trip: nil)
        case "places":
            seedPlaces(around: here)
            router.selectedSection = .places
        case "filter":
            UserDefaults.standard.set("rawdah,valley", forKey: SettingsKeys.landmarkKinds)
            mapManager.send(.focus(here, spanMeters: 160_000))
        case "pick":
            mapManager.send(.focus(here, spanMeters: 20_000))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            mapManager.pickedCoordinate = GeoMath.destination(from: here, distance: 3_000, bearing: 45)
        case "search":
            router.pendingSearchQuery = "روضة"
            router.mapSheet = .search
        case "coords":
            router.pendingCoordinateText = "24 42.816 ش 46 40.518 ق"
            router.mapSheet = .coordinates
        case "save":
            router.mapSheet = .savePlace(GeoMath.destination(from: here, distance: 2_000, bearing: 80))
        case "offline":
            mapManager.send(.focus(here, spanMeters: 15_000))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            router.mapSheet = .offlineMaps
        case "trips":
            if env.trips.activeTrip == nil { _ = env.trips.startTrip(name: "طلعة البر", autoRecord: false) }
            router.mapSheet = .trips
        case "tracks":
            router.selectedSection = .tracks
        case "settings":
            router.selectedSection = .settings
        // لقطات التحقق من الميزات الجديدة
        case "vehicle":
            UserDefaults.standard.set(UserMarkerStyle.suv.rawValue, forKey: SettingsKeys.userMarkerStyle)
            UserDefaults.standard.set(UserMarkerColor.sand.rawValue, forKey: SettingsKeys.userMarkerColor)
            mapManager.send(.focus(here, spanMeters: 1_500))
        case "caravan":
            UserDefaults.standard.set(UserMarkerStyle.caravan.rawValue, forKey: SettingsKeys.userMarkerStyle)
            UserDefaults.standard.set(UserMarkerColor.white.rawValue, forKey: SettingsKeys.userMarkerColor)
            mapManager.send(.focus(here, spanMeters: 1_500))
        case "map3d":
            mapManager.send(.focus(here, spanMeters: 3_000))
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            mapManager.send(.pitch(true))
        case "mytracks":
            seedTracks(around: here)
            UserDefaults.standard.set(true, forKey: SettingsKeys.showMyTracks)
            mapManager.send(.focus(here, spanMeters: 30_000))
        case "tripstops":
            let pts = demoTrackPoints(around: here, bearing: 40, legs: 3)
            router.shownTrack = ShownTrack(name: "طلعة البر", segments: TrackAccumulator.segments(of: pts), stops: TrackStops.stops(from: pts))
            mapManager.send(.fit(pts.map(\.coordinate)))
        case "pintap":
            UserDefaults.standard.set("rawdah", forKey: SettingsKeys.landmarkKinds)
            mapManager.send(.focus(here, spanMeters: 160_000))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            mapManager.selectedPin = .init(id: "g-demo", title: "روضة خريم", subtitle: "روضة",
                                           coordinate: .init(latitude: 25.3815, longitude: 47.2780), kind: .landmark, symbol: "leaf")
        case "dirt":
            UserDefaults.standard.set(true, forKey: SettingsKeys.showDirtRoads)
            UserDefaults.standard.set(true, forKey: SettingsKeys.showDetectedRoads)
            mapManager.send(.focus(.init(latitude: 25.18, longitude: 46.60), spanMeters: 9_000))
        case "dirtsat":
            mapManager.layer = .hybrid
            UserDefaults.standard.set(true, forKey: SettingsKeys.showDirtRoads)
            mapManager.send(.focus(.init(latitude: 25.18, longitude: 46.60), spanMeters: 9_000))
        case "coverage":
            UserDefaults.standard.set(Carrier.stc.rawValue, forKey: SettingsKeys.coverageCarrier)
            UserDefaults.standard.set(true, forKey: SettingsKeys.showCoverage)
            UserDefaults.standard.set(false, forKey: SettingsKeys.coverageOnlyMine)
            CoverageService.shared.injectDemo(around: here)
            mapManager.send(.focus(here, spanMeters: 9_000))
        case "safetrip":
            router.mapSheet = .safeTrip
        case "following":
            FollowService.shared.injectDemo(around: here)
            mapManager.send(.focus(here, spanMeters: 20_000))
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            router.mapSheet = .following
        case "followmap":
            FollowService.shared.injectDemo(around: here)
            mapManager.send(.focus(here, spanMeters: 20_000))
        case "emergency":
            router.mapSheet = .emergency
        case "regions":
            router.mapSheet = .offlineMaps
        case "regioninstall":
            // تحقق شامل: تنزيل منطقة جاهزة (الوسطى) وتثبيتها ثم عرضها بالخطوط والرموز المحلية
            let rp = RegionPackService.shared
            await rp.loadManifest()
            if let p = rp.manifest?.regions.first(where: { $0.id == "central" }) {
                if !rp.isInstalled(p) { rp.download(p) }
                for _ in 0..<160 where !rp.isInstalled(p) { try? await Task.sleep(nanoseconds: 1_000_000_000) }
                if let t = OfflineMapManager.shared.regionTileset(id: p.id) { OfflineMapManager.shared.selectedTilesetID = t.id }
            }
            mapManager.layer = .offline
            mapManager.send(.focus(here, spanMeters: 12_000))
        case "towns":
            UserDefaults.standard.set("town,service", forKey: SettingsKeys.landmarkKinds)
            mapManager.send(.focus(.init(latitude: 25.45, longitude: 45.9), spanMeters: 60_000))
        case "rain":
            UserDefaults.standard.set(true, forKey: SettingsKeys.showRainMap)
            UserDefaults.standard.set(false, forKey: RainNowService.modeKey)
            mapManager.layer = .hybrid
            mapManager.send(.focus(.init(latitude: 22.5, longitude: 44.0), spanMeters: 1_800_000))
        case "weather":
            await WeatherService.shared.refresh(at: here, force: true)
            router.mapSheet = .weather
        case "convoy":
            let members = FollowService.shared.injectDemoConvoy(around: here)
            SafeTripManager.shared.injectDemoConvoy(watchers: members)
            router.mapSheet = .convoy
        case "elevation":
            seedTracks(around: here)
            router.selectedSection = .tracks
        case "nightsky":
            await WeatherService.shared.refresh(at: here, force: true)
            router.mapSheet = .weather
        case "proximity":
            UserDefaults.standard.set(true, forKey: ProximityAlerts.savedKey)
            UserDefaults.standard.set(true, forKey: ProximityAlerts.waterKey)
            router.selectedSection = .settings
        case "reserves":
            await ReserveService.shared.refresh(force: true)
            UserDefaults.standard.set(true, forKey: SettingsKeys.showReserves)
            mapManager.layer = .hybrid
            mapManager.send(.focus(.init(latitude: 25.9, longitude: 46.6), spanMeters: 260_000))
        case "reserveinfo":
            await ReserveService.shared.refresh(force: true)
            if let r = ReserveService.shared.reserves.first(where: { $0.name.contains("الإمام عبدالعزيز بن محمد") })
                ?? ReserveService.shared.reserves.first {
                mapManager.send(.focus(r.labelPoint, spanMeters: 120_000))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                router.mapSheet = .reserve(r.id)
            }
        case "routepreview", "roadnav":
            glog("start \(screen)")
            await RouteGraphStore.shared.installForGuide("central")
            glog("graph installed=\(RouteGraphStore.shared.isInstalled("central"))")
            mapManager.layer = .standard
            let dest = Waypoint(name: "مهرجان الجنادرية", coordinate: .init(latitude: 24.7840, longitude: 46.8020))
            if screen == "routepreview" {
                env.navigation.previewRoutes(to: dest)
            } else {
                do {
                    let routes = try await RoadRoutingService.routes(from: here, to: dest.coordinate)
                    glog("routes \(routes.count) first=\(Int(routes[0].distance))m steps=\(routes[0].steps.count)")
                    env.navigation.start(NavigationPlan(origin: Waypoint(name: "موقعي", coordinate: here), waypoints: [],
                                                        destination: dest, mode: .road), presetRoute: routes[0])
                    glog("navigating=\(env.navigation.snapshot.isNavigating) road=\(env.navigation.snapshot.roadRoute != nil)")
                    mapManager.send(.followCourse)
                } catch { glog("route error \(error)") }
            }
        case "night":
            UserDefaults.standard.set(AppearanceMode.dark.rawValue, forKey: SettingsKeys.appearanceMode)
            AppearanceController.shared.update()
            mapManager.send(.focus(here, spanMeters: 20_000))
        default:
            break
        }
    }

    /// نقاط مسار تجريبي بعدة مقاطع (وقفات) لعرض علامات البداية والنهاية والوقفات.
    static func demoTrackPoints(around c: CLLocationCoordinate2D, bearing: Double, legs: Int) -> [TrackPoint] {
        var pts: [TrackPoint] = []
        var p = c
        var t = Date().addingTimeInterval(-4 * 3600)
        for seg in 0..<legs {
            for i in 0..<40 {
                p = GeoMath.destination(from: p, distance: 120, bearing: bearing + Double(seg) * 35 + sin(Double(i) / 5) * 12)
                let n = Double(seg * 40 + i)
                pts.append(TrackPoint(lat: p.latitude, lon: p.longitude, alt: 640 + 35 * sin(n / 9) + n * 0.6, time: t, speed: 8, hAcc: 5, segment: seg))
                t = t.addingTimeInterval(15)
            }
            t = t.addingTimeInterval(25 * 60)
            p = GeoMath.destination(from: p, distance: 60, bearing: 90)
        }
        return pts
    }

    private static func seedTracks(around c: CLLocationCoordinate2D) {
        let ctx = AppEnvironment.shared.container.mainContext
        guard ((try? ctx.fetchCount(FetchDescriptor<RecordedTrack>())) ?? 0) == 0 else { return }
        for (i, b) in [20.0, 140.0, 250.0].enumerated() {
            let start = GeoMath.destination(from: c, distance: 2_000 + Double(i) * 1_500, bearing: b)
            let pts = demoTrackPoints(around: start, bearing: b, legs: 2)
            let t = RecordedTrack(name: "مسار \(i + 1)", startedAt: pts.first?.time ?? Date())
            t.points = pts
            t.isComplete = true
            ctx.insert(t)
        }
        try? ctx.save()
    }

    private static func seedPlaces(around c: CLLocationCoordinate2D) {
        let ctx = AppEnvironment.shared.container.mainContext
        guard ((try? ctx.fetchCount(FetchDescriptor<SavedPlace>())) ?? 0) == 0 else { return }
        for (name, d, b, fav, pub) in [("المخيم", 9_000.0, 60.0, true, false), ("نقطة التزود", 4_200.0, 200.0, false, false),
                                       ("روضة الربيع", 15_000.0, 300.0, true, true), ("الاستراحة", 12_000.0, 120.0, false, false)] {
            let p = SavedPlace(name: name, coordinate: GeoMath.destination(from: c, distance: d, bearing: b))
            p.isFavorite = fav
            p.isPublic = pub
            ctx.insert(p)
        }
        try? ctx.save()
    }
}
#endif
