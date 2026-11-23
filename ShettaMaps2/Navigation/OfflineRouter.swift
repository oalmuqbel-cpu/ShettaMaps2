import Foundation
import CoreLocation

/// حساب طريق القيادة داخل الجوال على شبكة طرق OpenStreetMap (A* على زمن القيادة)، مع طرق بديلة وتعليمات عربية.
enum OfflineRouter {
    enum RouterError: LocalizedError {
        case noGraph, notOnRoad, noRoute
        var errorDescription: String? {
            switch self {
            case .noGraph: return "نزّل «طرق الملاحة» لهذه المنطقة من الخرائط دون إنترنت حتى يُحسب الطريق."
            case .notOnRoad: return "نقطة البداية أو الوجهة بعيدة عن الطرق المعروفة. استخدم الخط المباشر."
            case .noRoute: return "لا يوجد طريق قيادة معروف بين النقطتين. استخدم الخط المباشر."
            }
        }
    }

    /// سرعة الحد الأعلى للتقدير المتفائل (م/ث) — تبقي A* صحيحًا.
    static let maxSpeed = 130.0 / 3.6

    private struct Endpoint { var vertex: Int; var cost: Double; var coords: [CLLocationCoordinate2D] }

    /// حتى ثلاثة طرق، الأسرع أولًا.
    static func routes(on g: RouteGraph, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, alternatives: Int = 3) throws -> [RoadRoute] {
        guard let s = g.snap(from), let t = g.snap(to) else { throw RouterError.notOnRoad }
        var penalties: [Int: Double] = [:]
        var out: [RoadRoute] = []
        var usedSets: [Set<Int>] = []
        for attempt in 0..<(alternatives + 2) {
            guard let path = search(g, s, t, penalties: penalties) else { break }
            let infos = Set(path.directed.map { g.infoRef($0).info })
            // نرفض البديل المطابق تقريبًا لطريق سابق
            let similar = usedSets.contains { prev in
                Double(prev.intersection(infos).count) / Double(max(1, infos.count)) > 0.75
            }
            if !similar, let route = build(g, path: path, from: s, to: t) {
                if let fastest = out.first, route.expectedTravelTime > fastest.expectedTravelTime * 1.5 { break }
                out.append(route); usedSets.append(infos)
                if out.count >= alternatives { break }
            }
            for i in infos { penalties[i, default: 1] *= 1.6 }
            if attempt == 0, out.isEmpty { break }
        }
        guard !out.isEmpty else { throw RouterError.noRoute }
        return out.sorted { $0.expectedTravelTime < $1.expectedTravelTime }
    }

    // MARK: - البحث

    struct Path { var start: Int; var directed: [Int]; var end: Int; var cost: Double }

    private static func edgeTime(_ i: RouteGraph.EdgeInfo, fraction: Double = 1) -> Double {
        i.length * fraction / max(1.4, i.speedKmh / 3.6)
    }

    /// بداية: من نقطة الانطلاق إلى رأسي حافتها حسب اتجاه السير المسموح.
    private static func exits(_ g: RouteGraph, _ s: RouteGraph.Snap) -> [Endpoint] {
        let inf = g.info(s.info)
        let full = g.edgeCoordinates(from: s.vertexA, to: s.vertexB, info: inf, reversed: false)
        let oneway = inf.flags & RouteGraph.flagOneway != 0, rev = inf.flags & RouteGraph.flagReverse != 0
        var out: [Endpoint] = []
        if !oneway || !rev { // نحو B
            out.append(Endpoint(vertex: s.vertexB, cost: edgeTime(inf, fraction: 1 - s.fraction),
                                coords: [s.point] + tail(full, after: s.fraction)))
        }
        if !oneway || rev { // نحو A
            out.append(Endpoint(vertex: s.vertexA, cost: edgeTime(inf, fraction: s.fraction),
                                coords: [s.point] + tail(full.reversed(), after: 1 - s.fraction)))
        }
        return out
    }

    /// نهاية: من رأسي حافة الوجهة إلى نقطة الوجهة.
    private static func entries(_ g: RouteGraph, _ t: RouteGraph.Snap) -> [Endpoint] {
        let inf = g.info(t.info)
        let full = g.edgeCoordinates(from: t.vertexA, to: t.vertexB, info: inf, reversed: false)
        let oneway = inf.flags & RouteGraph.flagOneway != 0, rev = inf.flags & RouteGraph.flagReverse != 0
        var out: [Endpoint] = []
        if !oneway || !rev { // من A باتجاه الرسم
            out.append(Endpoint(vertex: t.vertexA, cost: edgeTime(inf, fraction: t.fraction),
                                coords: head(full, upTo: t.fraction) + [t.point]))
        }
        if !oneway || rev { // من B بعكس الرسم
            out.append(Endpoint(vertex: t.vertexB, cost: edgeTime(inf, fraction: 1 - t.fraction),
                                coords: head(full.reversed(), upTo: 1 - t.fraction) + [t.point]))
        }
        return out
    }

    /// النقاط بعد نسبة معينة من طول الخط (بدون النقطة المسقطة نفسها).
    private static func tail(_ c: [CLLocationCoordinate2D], after f: Double) -> [CLLocationCoordinate2D] {
        let total = zip(c, c.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0, $1.1) }
        var acc = 0.0
        var out: [CLLocationCoordinate2D] = []
        for k in 1..<c.count {
            acc += GeoMath.distance(c[k - 1], c[k])
            if acc > total * f { out.append(c[k]) }
        }
        return out.isEmpty ? [c.last!] : out
    }
    private static func head(_ c: [CLLocationCoordinate2D], upTo f: Double) -> [CLLocationCoordinate2D] {
        let total = zip(c, c.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0, $1.1) }
        var acc = 0.0
        var out: [CLLocationCoordinate2D] = [c[0]]
        for k in 1..<c.count {
            acc += GeoMath.distance(c[k - 1], c[k])
            if acc < total * f { out.append(c[k]) }
        }
        return out
    }

    private struct Heap {
        var items: [(Double, Int32)] = []
        mutating func push(_ e: (Double, Int32)) {
            items.append(e); var i = items.count - 1
            while i > 0 { let p = (i - 1) / 2; if items[p].0 <= items[i].0 { break }; items.swapAt(p, i); i = p }
        }
        mutating func pop() -> (Double, Int32)? {
            guard !items.isEmpty else { return nil }
            let top = items[0]; let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last; var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1; var m = i
                    if l < items.count, items[l].0 < items[m].0 { m = l }
                    if r < items.count, items[r].0 < items[m].0 { m = r }
                    if m == i { break }; items.swapAt(m, i); i = m
                }
            }
            return top
        }
    }

    private static func search(_ g: RouteGraph, _ s: RouteGraph.Snap, _ t: RouteGraph.Snap, penalties: [Int: Double]) -> (directed: [Int], start: Endpoint, end: Endpoint, cost: Double)? {
        let starts = exits(g, s), ends = entries(g, t)
        let goal = t.point
        let n = g.vertexCount
        var dist = [Float](repeating: .infinity, count: n)
        var prev = [Int32](repeating: -1, count: n)
        var startOf = [Int8](repeating: -1, count: n)
        var heap = Heap()
        func h(_ v: Int) -> Double { GeoMath.distance(g.coordinate(v), goal) / maxSpeed }
        for (k, e) in starts.enumerated() where Double(dist[e.vertex]) > e.cost {
            dist[e.vertex] = Float(e.cost); startOf[e.vertex] = Int8(k)
            heap.push((e.cost + h(e.vertex), Int32(e.vertex)))
        }
        var endCost: [Int: (Double, Int)] = [:]
        for (k, e) in ends.enumerated() { endCost[e.vertex] = (e.cost, k) }
        var best: (cost: Double, vertex: Int, end: Int)?
        // نفس الحافة للبداية والوجهة (مسافة قصيرة على الطريق نفسه)
        var settled = 0
        while let (f, v32) = heap.pop() {
            let v = Int(v32)
            if let b = best, f >= b.cost { break }
            let gv = Double(dist[v])
            if f - h(v) > gv + 0.01 { continue }
            settled += 1
            if settled > 4_000_000 { break }
            if let (c, k) = endCost[v], best == nil || gv + c < best!.cost { best = (gv + c, v, k) }
            for d in g.outEdges(v) {
                let (i, _) = g.infoRef(d)
                let inf = g.info(i)
                let w = edgeTime(inf) * (penalties[i] ?? 1)
                let u = g.target(d)
                let nd = gv + w
                if nd < Double(dist[u]) {
                    dist[u] = Float(nd); prev[u] = Int32(d); startOf[u] = startOf[v]
                    heap.push((nd + h(u), Int32(u)))
                }
            }
        }
        guard let b = best else { return nil }
        // إعادة بناء المسار
        var directed: [Int] = []
        var v = b.vertex
        var guardCount = 0
        while prev[v] >= 0, guardCount < 2_000_000 {
            let d = Int(prev[v]); directed.append(d)
            // مصدر الحافة الموجهة: نجده من رأسي الحافة
            let (i, rev) = g.infoRef(d)
            guard let (a, bb) = g.endpoints(ofInfo: i) else { return nil }
            v = rev ? bb : a
            guardCount += 1
        }
        directed.reverse()
        let sk = Int(startOf[b.vertex]); guard sk >= 0 else { return nil }
        return (directed, starts[sk], ends[b.end], b.cost)
    }

    // MARK: - البناء والتعليمات

    private struct Leg {
        var name: String
        var roadClass: Int
        var roundabout: Bool
        var coords: [CLLocationCoordinate2D]
        var length: Double
        var exitsPassed: Int = 0
    }

    private static func build(_ g: RouteGraph, path: (directed: [Int], start: Endpoint, end: Endpoint, cost: Double),
                              from s: RouteGraph.Snap, to t: RouteGraph.Snap) -> RoadRoute? {
        var legs: [Leg] = []
        func add(name: String, cls: Int, roundabout: Bool, coords: [CLLocationCoordinate2D], exits: Int = 0) {
            let len = zip(coords, coords.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0, $1.1) }
            if var last = legs.last, last.name == name, last.roundabout == roundabout,
               (!name.isEmpty || last.roadClass == cls) {
                last.coords += coords.dropFirst(); last.length += len; last.exitsPassed += exits
                legs[legs.count - 1] = last
            } else {
                legs.append(Leg(name: name, roadClass: cls, roundabout: roundabout, coords: coords, length: len, exitsPassed: exits))
            }
        }
        let sInfo = g.info(s.info)
        add(name: g.name(sInfo.nameOffset), cls: sInfo.roadClass, roundabout: sInfo.flags & RouteGraph.flagRoundabout != 0,
            coords: path.start.coords)
        for d in path.directed {
            let (i, rev) = g.infoRef(d)
            guard let (a, b) = g.endpoints(ofInfo: i) else { return nil }
            let inf = g.info(i)
            let from = rev ? b : a, to = rev ? a : b
            let ra = inf.flags & RouteGraph.flagRoundabout != 0
            // المخارج المتجاوزة داخل الدوار: حواف خارجة غير دوارية من رأس البداية
            var exits = 0
            if ra {
                for od in g.outEdges(from) where g.info(g.infoRef(od).info).flags & RouteGraph.flagRoundabout == 0 { exits += 1 }
            }
            add(name: g.name(inf.nameOffset), cls: inf.roadClass, roundabout: ra,
                coords: g.edgeCoordinates(from: from, to: to, info: inf, reversed: rev), exits: exits)
        }
        let tInfo = g.info(t.info)
        add(name: g.name(tInfo.nameOffset), cls: tInfo.roadClass, roundabout: tInfo.flags & RouteGraph.flagRoundabout != 0,
            coords: path.end.coords)
        legs = legs.filter { $0.coords.count >= 2 && $0.length > 0.5 }
        guard !legs.isEmpty else { return nil }

        // تعليمة كل مقطع تخص بدايته (نفس صيغة خدمة Apple)، ثم buildSteps يحولها للمناورة عند نهاية المقطع السابق
        var raw: [(instruction: String, distance: Double, coords: [CLLocationCoordinate2D])] = []
        for (k, leg) in legs.enumerated() {
            var text = ""
            if k > 0 {
                let prevLeg = legs[k - 1]
                if leg.roundabout {
                    // نجمع المناورة مع المقطع التالي للدوار
                    let next = k + 1 < legs.count ? legs[k + 1] : nil
                    let exitNo = max(1, leg.exitsPassed)
                    text = "عند الدوار، خذ المخرج \(ordinal(exitNo))" + (next.map { roadName($0).isEmpty ? "" : " إلى \(roadName($0))" } ?? "")
                } else if prevLeg.roundabout {
                    text = "اخرج من الدوار" + (roadName(leg).isEmpty ? "" : " إلى \(roadName(leg))")
                } else {
                    text = maneuver(from: prevLeg, to: leg)
                }
            }
            raw.append((text, leg.length, leg.coords))
        }
        let coords = legs.flatMap { $0.coords }
        let distance = legs.reduce(0) { $0 + $1.length }
        let main = Dictionary(grouping: legs.filter { !$0.name.isEmpty }, by: \.name)
            .mapValues { $0.reduce(0) { $0 + $1.length } }.max { $0.value < $1.value }?.key ?? ""
        return RoadRoute(coordinates: coords, steps: RoadRoutingService.buildSteps(raw), distance: distance,
                         expectedTravelTime: path.cost, name: main)
    }

    static func ordinal(_ n: Int) -> String {
        ["الأول", "الثاني", "الثالث", "الرابع", "الخامس", "السادس"][min(max(n, 1), 6) - 1]
    }

    private static func roadName(_ l: Leg) -> String { l.name }

    private static func maneuver(from a: Leg, to b: Leg) -> String {
        let angle = turnAngle(a.coords, b.coords)
        let target = b.name.isEmpty ? "" : " إلى \(b.name)"
        let isLink = (8...12).contains(b.roadClass), fromLink = (8...12).contains(a.roadClass)
        if isLink && !fromLink { return "اسلك المخرج" + (angle > 15 ? " يمينًا" : angle < -15 ? " يسارًا" : "") + target }
        if fromLink && !isLink && b.roadClass <= 2 { return "اندمج في الطريق" + target }
        switch abs(angle) {
        case ..<20: return b.name.isEmpty ? "استمر في الطريق" : "استمر إلى \(b.name)"
        case ..<55: return (angle > 0 ? "انحرف يمينًا" : "انحرف يسارًا") + target
        case ..<145: return (angle > 0 ? "انعطف يمينًا" : "انعطف يسارًا") + target
        default: return "استدر للخلف" + target
        }
    }

    /// زاوية الانعطاف بين نهاية مقطع وبداية الذي يليه (موجبة لليمين).
    static func turnAngle(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Double {
        guard let e = a.last, let ap = a.dropLast().last(where: { GeoMath.distance($0, e) > 8 }) ?? a.dropLast().last,
              let s = b.first, let bn = b.dropFirst().first(where: { GeoMath.distance(s, $0) > 8 }) ?? b.dropFirst().first else { return 0 }
        return GeoMath.angleDelta(from: GeoMath.bearing(from: ap, to: e), to: GeoMath.bearing(from: s, to: bn))
    }
}
