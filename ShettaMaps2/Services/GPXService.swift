import Foundation
import CoreLocation

/// ملف GPX مستورد: مسارات ونقاط.
struct GPXDocument: Equatable {
    struct Track: Equatable {
        var name: String
        var points: [TrackPoint]
    }
    struct Point: Equatable {
        var name: String
        var lat: Double
        var lon: Double
        var elevation: Double?
        var notes: String?
    }
    var tracks: [Track] = []
    var waypoints: [Point] = []
}

enum GPXError: LocalizedError {
    case invalidXML(String)
    case empty
    var errorDescription: String? {
        switch self {
        case .invalidXML(let m): return "ملف GPX غير صالح: \(m)"
        case .empty: return "لا يحتوي الملف على مسارات أو نقاط."
        }
    }
}

/// تصدير واستيراد ملفات GPX 1.1 (معيار تبادل مفتوح تدعمه أغلب تطبيقات الملاحة).
enum GPXService {

    // MARK: - التصدير

    static func export(trackName: String, points: [TrackPoint], waypoints: [GPXDocument.Point] = []) -> String {
        var xml = header()
        for w in waypoints { xml += waypointXML(w) }
        xml += "  <trk>\n    <name>\(escape(trackName))</name>\n"
        let groups = Dictionary(grouping: points, by: \.segment).sorted { $0.key < $1.key }
        for (_, seg) in groups {
            xml += "    <trkseg>\n"
            for p in seg {
                xml += "      <trkpt lat=\"\(coord(p.lat))\" lon=\"\(coord(p.lon))\">"
                if let e = p.alt { xml += "<ele>\(String(format: "%.1f", e))</ele>" }
                xml += "<time>\(iso.string(from: p.time))</time>"
                if let s = p.speed { xml += "<extensions><speed>\(String(format: "%.2f", s))</speed></extensions>" }
                xml += "</trkpt>\n"
            }
            xml += "    </trkseg>\n"
        }
        xml += "  </trk>\n</gpx>\n"
        return xml
    }

    static func export(waypoints: [GPXDocument.Point], name: String) -> String {
        var xml = header(name: name)
        for w in waypoints { xml += waypointXML(w) }
        xml += "</gpx>\n"
        return xml
    }

    /// يكتب ملفًا مؤقتًا للمشاركة ويعيد مساره.
    static func writeTemporaryFile(_ xml: String, baseName: String) throws -> URL {
        let safe = baseName.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).gpx")
        try xml.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private static func header(name: String? = nil) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="ShettaMaps2" xmlns="http://www.topografix.com/GPX/1/1">

        """
        if let name { s += "  <metadata><name>\(escape(name))</name></metadata>\n" }
        return s
    }

    private static func waypointXML(_ w: GPXDocument.Point) -> String {
        var s = "  <wpt lat=\"\(coord(w.lat))\" lon=\"\(coord(w.lon))\">"
        if let e = w.elevation { s += "<ele>\(String(format: "%.1f", e))</ele>" }
        s += "<name>\(escape(w.name))</name>"
        if let n = w.notes, !n.isEmpty { s += "<desc>\(escape(n))</desc>" }
        return s + "</wpt>\n"
    }

    private static func coord(_ v: Double) -> String { String(format: "%.7f", v) }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - الاستيراد

    static func parse(data: Data) throws -> GPXDocument {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw GPXError.invalidXML(parser.parserError?.localizedDescription ?? "خطأ غير معروف")
        }
        let doc = delegate.document
        // نقاط المسار route (rte) تُعامل كمسار
        if doc.tracks.allSatisfy({ $0.points.isEmpty }) && doc.waypoints.isEmpty { throw GPXError.empty }
        return doc
    }

    static func parse(url: URL) throws -> GPXDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try parse(data: Data(contentsOf: url))
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    var document = GPXDocument()
    private var text = ""
    private var inTrack = false, inRoute = false
    private var trackName = ""
    private var trackPoints: [TrackPoint] = []
    private var segment = 0
    private var current: (lat: Double, lon: Double)?
    private var ele: Double?
    private var time: Date?
    private var speed: Double?
    private var name: String?
    private var desc: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let el = local(elementName)
        text = ""
        switch el {
        case "trk":
            inTrack = true; trackName = ""; trackPoints = []; segment = 0
        case "rte":
            inRoute = true; trackName = ""; trackPoints = []; segment = 0
        case "trkseg":
            if !trackPoints.isEmpty { segment += 1 }
        case "trkpt", "rtept", "wpt":
            if let la = attributes["lat"].flatMap({ Double($0) }), let lo = attributes["lon"].flatMap({ Double($0) }),
               (-90...90).contains(la), (-180...180).contains(lo) {
                current = (la, lo)
            } else {
                current = nil
            }
            ele = nil; time = nil; speed = nil; name = nil; desc = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let el = local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch el {
        case "ele": ele = Double(value)
        case "time":
            time = GPXService.iso.date(from: value) ?? GPXService.isoFractional.date(from: value)
        case "speed": speed = Double(value)
        case "desc", "cmt": if desc == nil { desc = value }
        case "name":
            if current != nil { name = value }
            else if inTrack || inRoute { trackName = value }
        case "trkpt", "rtept":
            if let c = current {
                // نقاط بلا وقت: نعطيها وقتًا متزايدًا للحفاظ على الترتيب
                let t = time ?? Date(timeIntervalSince1970: Double(trackPoints.count))
                trackPoints.append(TrackPoint(lat: c.lat, lon: c.lon, alt: ele, time: t, speed: speed,
                                              hAcc: nil, segment: segment))
            }
            current = nil
        case "wpt":
            if let c = current {
                document.waypoints.append(.init(name: name ?? "نقطة \(document.waypoints.count + 1)",
                                                lat: c.lat, lon: c.lon, elevation: ele, notes: desc))
            }
            current = nil
        case "trk", "rte":
            document.tracks.append(.init(name: trackName.isEmpty ? "مسار مستورد" : trackName, points: trackPoints))
            inTrack = false; inRoute = false; trackPoints = []
        default: break
        }
        text = ""
    }

    private func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
