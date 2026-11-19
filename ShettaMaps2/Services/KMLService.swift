import Foundation

/// استيراد ملفات KML/KMZ (Google Earth وخرائط Google «خرائطي»): النقاط تصبح أماكن محفوظة
/// والخطوط والمسارات تصبح مسارات. الناتج بنفس شكل ملف GPX ليمر بمسار الاستيراد نفسه.
enum KMLService {
    enum KMLError: LocalizedError {
        case invalid(String), empty, noKML
        var errorDescription: String? {
            switch self {
            case .invalid(let m): return "ملف KML غير صالح: \(m)"
            case .empty: return "لا يحتوي الملف على نقاط أو مسارات."
            case .noKML: return "لا يوجد ملف KML داخل أرشيف KMZ."
            }
        }
    }

    static func parse(url: URL) throws -> GPXDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return url.pathExtension.lowercased() == "kmz" ? try parseKMZ(data) : try parse(data: data)
    }

    static func parseKMZ(_ data: Data) throws -> GPXDocument {
        let entries = try ZipReader.entries(data).filter { $0.name.lowercased().hasSuffix(".kml") && !$0.name.hasPrefix("__MACOSX") }
        // doc.kml هو المعتاد، وإلا أول ملف KML
        guard let e = entries.first(where: { $0.name.lowercased() == "doc.kml" }) ?? entries.first else { throw KMLError.noKML }
        return try parse(data: ZipReader.read(e, from: data))
    }

    static func parse(data: Data) throws -> GPXDocument {
        let d = Delegate()
        let p = XMLParser(data: data)
        p.shouldProcessNamespaces = true
        p.delegate = d
        guard p.parse() else { throw KMLError.invalid(p.parserError?.localizedDescription ?? "") }
        let doc = GPXDocument(tracks: d.tracks, waypoints: d.points)
        guard !doc.tracks.isEmpty || !doc.waypoints.isEmpty else { throw KMLError.empty }
        return doc
    }

    /// «lon,lat[,alt] lon,lat…»
    static func coordinates(_ s: String) -> [(lat: Double, lon: Double, alt: Double?)] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).compactMap { tuple in
            let v = tuple.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count >= 2, (-90...90).contains(v[1]), (-180...180).contains(v[0]) else { return nil }
            return (v[1], v[0], v.count > 2 && v[2] != 0 ? v[2] : nil)
        }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var tracks: [GPXDocument.Track] = []
        var points: [GPXDocument.Point] = []

        private var text = ""
        private var inPlacemark = false
        private var name = ""
        private var desc = ""
        private var pointCoords: [(lat: Double, lon: Double, alt: Double?)] = []
        private var lines: [[TrackPoint]] = []
        private var context: String?          // Point / LineString / LinearRing
        private var gxCoords: [String] = []
        private var gxWhen: [Date] = []
        private var inTrack = false
        private let iso = ISO8601DateFormatter()
        private let isoFrac: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
        }()
        private let now = Date()

        func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch el {
            case "Placemark":
                inPlacemark = true; name = ""; desc = ""; pointCoords = []; lines = []
            case "Point", "LineString", "LinearRing": context = el
            case "Track": inTrack = true; gxCoords = []; gxWhen = []
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }

        func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch el {
            case "name" where inPlacemark && name.isEmpty: name = t
            case "description" where inPlacemark: desc = Self.stripHTML(t)
            case "coordinates":
                let c = KMLService.coordinates(t)
                if context == "Point" { pointCoords += c.prefix(1) }
                else if context == "LineString" {
                    lines.append(c.map { TrackPoint(lat: $0.lat, lon: $0.lon, alt: $0.alt, time: now) })
                }
            case "Point", "LineString", "LinearRing": context = nil
            case "when" where inTrack:
                if let d = isoFrac.date(from: t) ?? iso.date(from: t) { gxWhen.append(d) }
            case "coord" where inTrack: gxCoords.append(t)
            case "Track":
                inTrack = false
                var pts: [TrackPoint] = []
                for (i, s) in gxCoords.enumerated() {
                    let v = s.split(separator: " ").compactMap { Double($0) }
                    guard v.count >= 2 else { continue }
                    pts.append(TrackPoint(lat: v[1], lon: v[0], alt: v.count > 2 ? v[2] : nil,
                                          time: i < gxWhen.count ? gxWhen[i] : now))
                }
                if !pts.isEmpty { lines.append(pts) }
            case "Placemark":
                inPlacemark = false
                let title = name.isEmpty ? "مستورد" : String(name.prefix(80))
                for c in pointCoords {
                    points.append(.init(name: title, lat: c.lat, lon: c.lon, elevation: c.alt, notes: desc.isEmpty ? nil : desc))
                }
                // خطوط متعددة في علامة واحدة (MultiGeometry) تصير أجزاء لمسار واحد
                var merged: [TrackPoint] = []
                for (seg, line) in lines.enumerated() where line.count >= 2 {
                    merged += line.map { var p = $0; p.segment = seg; return p }
                }
                if merged.count >= 2 { tracks.append(.init(name: title, points: merged)) }
            default: break
            }
            text = ""
        }

        static func stripHTML(_ s: String) -> String {
            var out = s.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return String(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        }
    }
}
