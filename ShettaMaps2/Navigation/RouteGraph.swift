import Foundation
import CoreLocation

/// شبكة طرق القيادة لمنطقة (ملف samtroute من بيانات OpenStreetMap)، تُقرأ من الذاكرة المعيّنة دون نسخها،
/// ويُحسب عليها الطريق داخل الجوال بلا إنترنت (A* على زمن القيادة).
final class RouteGraph {
    enum GraphError: Error { case badFile }

    static let flagOneway: UInt8 = 1, flagReverse: UInt8 = 2, flagRoundabout: UInt8 = 4, flagToll: UInt8 = 8
    static let classNames = ["motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential",
                             "living_street", "motorway_link", "trunk_link", "primary_link", "secondary_link",
                             "tertiary_link", "service"]

    private let data: Data
    let vertexCount: Int, edgeCount: Int, directedCount: Int, geomCount: Int, namesBytes: Int
    let minLon: Double, minLat: Double, cell: Double
    let cols: Int, rows: Int
    private let oVert: Int, oFirst: Int, oDirected: Int, oInfo: Int, oGeom: Int, oNames: Int, oCellStart: Int, oCellItems: Int

    init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .alwaysMapped)
        guard d.count > 64, d.prefix(7) == Data("SAMTRT1".utf8) else { throw GraphError.badFile }
        data = d
        let u32 = { (o: Int) -> Int in Int(d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }) }
        let f64 = { (o: Int) -> Double in d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Double.self) } }
        vertexCount = u32(12); edgeCount = u32(16); directedCount = u32(20); geomCount = u32(24); namesBytes = u32(28)
        minLon = f64(32); minLat = f64(40); cell = f64(48); cols = u32(56); rows = u32(60)
        oVert = 64
        oFirst = oVert + vertexCount * 8
        oDirected = oFirst + (vertexCount + 1) * 4
        oInfo = oDirected + directedCount * 8
        oGeom = oInfo + edgeCount * 28
        oNames = oGeom + geomCount * 8
        oCellStart = oNames + namesBytes
        oCellItems = oCellStart + (cols * rows + 1) * 4
        guard oCellItems <= d.count else { throw GraphError.badFile }
    }

    // MARK: - القراءة

    @inline(__always) private func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
    @inline(__always) private func i32(_ o: Int) -> Int32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) } }
    @inline(__always) private func f32(_ o: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Float.self) } }
    @inline(__always) private func u8(_ o: Int) -> UInt8 { data[data.startIndex + o] }

    func coordinate(_ v: Int) -> CLLocationCoordinate2D {
        .init(latitude: Double(i32(oVert + v * 8)) / 1e6, longitude: Double(i32(oVert + v * 8 + 4)) / 1e6)
    }
    func outEdges(_ v: Int) -> Range<Int> { Int(u32(oFirst + v * 4))..<Int(u32(oFirst + (v + 1) * 4)) }
    func target(_ d: Int) -> Int { Int(u32(oDirected + d * 8)) }
    func infoRef(_ d: Int) -> (info: Int, reversed: Bool) {
        let x = u32(oDirected + d * 8 + 4)
        return (Int(x & 0x7FFF_FFFF), x & 0x8000_0000 != 0)
    }

    struct EdgeInfo {
        var length: Double
        var speedKmh: Double
        var roadClass: Int
        var flags: UInt8
        var nameOffset: Int
        var geomStart: Int
        var geomCount: Int
    }
    func info(_ i: Int) -> EdgeInfo {
        let o = oInfo + i * 28
        return EdgeInfo(length: Double(f32(o)), speedKmh: Double(u8(o + 4)), roadClass: Int(u8(o + 5)), flags: u8(o + 6),
                        nameOffset: Int(u32(o + 8)), geomStart: Int(u32(o + 12)), geomCount: Int(u32(o + 16)))
    }
    func name(_ off: Int) -> String {
        guard off > 0, off < namesBytes else { return "" }
        let start = data.startIndex + oNames + off
        var end = start
        while end < data.startIndex + oNames + namesBytes, data[end] != 0 { end += 1 }
        return String(decoding: data[start..<end], as: UTF8.self)
    }
    /// نقاط الحافة كاملة من رأس البداية إلى رأس النهاية باتجاه السير.
    func edgeCoordinates(from a: Int, to b: Int, info i: EdgeInfo, reversed: Bool) -> [CLLocationCoordinate2D] {
        var mid: [CLLocationCoordinate2D] = []
        mid.reserveCapacity(i.geomCount)
        for k in 0..<i.geomCount {
            let o = oGeom + (i.geomStart + k) * 8
            mid.append(.init(latitude: Double(i32(o)) / 1e6, longitude: Double(i32(o + 4)) / 1e6))
        }
        if reversed { mid.reverse() }
        return [coordinate(a)] + mid + [coordinate(b)]
    }

    var bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        (minLat, minLat + Double(rows) * cell, minLon, minLon + Double(cols) * cell)
    }
    func covers(_ c: CLLocationCoordinate2D) -> Bool {
        let b = bounds
        return c.latitude >= b.minLat && c.latitude <= b.maxLat && c.longitude >= b.minLon && c.longitude <= b.maxLon
    }

    // MARK: - أقرب طريق

    struct Snap {
        var info: Int
        var vertexA: Int, vertexB: Int        // بداية الحافة ونهايتها حسب الرسم
        var point: CLLocationCoordinate2D
        var distance: Double
        var fraction: Double                  // موقع النقطة على طول الحافة (0 عند A)
    }

    /// أقرب حافة إلى نقطة ضمن ~2 كم.
    func snap(_ p: CLLocationCoordinate2D, maxMeters: Double = 2_000) -> Snap? {
        let c0 = Int((p.longitude - minLon) / cell), r0 = Int((p.latitude - minLat) / cell)
        var candidates = Set<Int>()
        for ring in 0...2 {
            for r in (r0 - ring)...(r0 + ring) {
                for c in (c0 - ring)...(c0 + ring) where r >= 0 && c >= 0 && r < rows && c < cols {
                    let k = r * cols + c
                    let s = Int(u32(oCellStart + k * 4)), e = Int(u32(oCellStart + (k + 1) * 4))
                    for j in s..<e { candidates.insert(Int(u32(oCellItems + j * 4))) }
                }
            }
            if candidates.count >= 4 { break }
        }
        var best: Snap?
        for i in candidates {
            guard let (a, b) = endpoints(ofInfo: i) else { continue }
            let inf = info(i)
            let pts = edgeCoordinates(from: a, to: b, info: inf, reversed: false)
            var along = 0.0, total = 0.0
            for k in 0..<(pts.count - 1) { total += GeoMath.distance(pts[k], pts[k + 1]) }
            for k in 0..<(pts.count - 1) {
                let (q, t) = Self.project(p, pts[k], pts[k + 1])
                let d = GeoMath.distance(p, q)
                let segLen = GeoMath.distance(pts[k], pts[k + 1])
                if best == nil || d < best!.distance {
                    best = Snap(info: i, vertexA: a, vertexB: b, point: q, distance: d,
                                fraction: total > 0 ? (along + segLen * t) / total : 0)
                }
                along += segLen
            }
        }
        guard let best, best.distance <= maxMeters else { return nil }
        return best
    }

    /// رأسا الحافة كما رُسمت (مخزّنان في الملف).
    func endpoints(ofInfo i: Int) -> (Int, Int)? {
        guard i >= 0, i < edgeCount else { return nil }
        let o = oInfo + i * 28
        return (Int(u32(o + 20)), Int(u32(o + 24)))
    }

    static func project(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> (CLLocationCoordinate2D, Double) {
        let k = cos(a.latitude * .pi / 180)
        let ax = a.longitude * k, ay = a.latitude, bx = b.longitude * k, by = b.latitude
        let px = p.longitude * k, py = p.latitude
        let dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy
        guard len2 > 0 else { return (a, 0) }
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
        return (.init(latitude: ay + t * dy, longitude: (ax + t * dx) / k), t)
    }
}
