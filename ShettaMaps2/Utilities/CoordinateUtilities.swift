import Foundation
import CoreLocation

/// صيغ عرض الإحداثيات المدعومة.
enum CoordinateFormat: String, CaseIterable, Identifiable, Codable {
    case decimal      // 24.713600, 46.675300
    case dms          // 24° 42′ 48.96″ ش  46° 40′ 31.08″ ق
    case ddm          // 24° 42.816′ ش  46° 40.518′ ق

    var id: String { rawValue }
    var title: String {
        switch self {
        case .decimal: return "درجات عشرية"
        case .dms: return "درجات ودقائق وثوانٍ"
        case .ddm: return "درجات ودقائق عشرية"
        }
    }
}

enum CoordinateParseError: Error, Equatable, LocalizedError {
    case empty
    case unrecognized
    case latitudeOutOfRange
    case longitudeOutOfRange
    case minutesOrSecondsOutOfRange

    var errorDescription: String? {
        switch self {
        case .empty: return "أدخل الإحداثيات."
        case .unrecognized: return "تعذّر فهم صيغة الإحداثيات. مثال: 24.7136, 46.6753"
        case .latitudeOutOfRange: return "خط العرض يجب أن يكون بين ‎-90 و 90."
        case .longitudeOutOfRange: return "خط الطول يجب أن يكون بين ‎-180 و 180."
        case .minutesOrSecondsOutOfRange: return "الدقائق والثواني يجب أن تكون أقل من 60."
        }
    }
}

/// أدوات تحليل الإحداثيات وتحويلها وتنسيقها. منطق خالص قابل للاختبار.
enum CoordinateUtilities {

    // MARK: - التطبيع

    /// يحوّل الأرقام العربية والفارسية إلى لاتينية، ويوحّد الفواصل والرموز.
    static func normalize(_ input: String) -> String {
        var s = ""
        for ch in input {
            switch ch {
            case "٠"..."٩":
                let v = ch.unicodeScalars.first!.value - 0x0660
                s.append(Character(String(v)))
            case "۰"..."۹":
                let v = ch.unicodeScalars.first!.value - 0x06F0
                s.append(Character(String(v)))
            case "٫": s.append(".")          // الفاصلة العشرية العربية
            case "،", "؛", ";": s.append(",") // الفاصلة العربية
            case "º", "˚": s.append("°")
            case "′", "‘", "’", "´": s.append("'")
            case "″", "“", "”": s.append("\"")
            case "\u{200F}", "\u{200E}", "\u{061C}": continue // علامات الاتجاه
            default: s.append(ch)
            }
        }
        // الكلمات العربية للاتجاهات تُختصر إلى حرف واحد قبل التحليل
        for (word, letter) in [("شمالا", "ش"), ("شمال", "ش"), ("جنوبا", "ج"), ("جنوب", "ج"),
                               ("شرقا", "ق"), ("شرق", "ق"), ("غربا", "غ"), ("غرب", "غ")] {
            s = s.replacingOccurrences(of: word, with: letter)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - التحليل

    /// يحلل نصًا يحتوي على خطي العرض والطول بأي صيغة مدعومة.
    /// يقبل: عشري، درجات ودقائق، درجات ودقائق وثوانٍ، مع حروف N/S/E/W أو ش/ج/ق/غ.
    static func parse(_ raw: String) throws -> CLLocationCoordinate2D {
        let text = normalize(raw)
        guard !text.isEmpty else { throw CoordinateParseError.empty }

        let parts = splitPair(text)
        guard parts.count == 2 else { throw CoordinateParseError.unrecognized }

        var first = try parseComponent(parts[0])
        var second = try parseComponent(parts[1])

        // إذا حُدد نصف الكرة صراحةً بحرف شرق/غرب للأول، نبدّل الترتيب.
        if first.axis == .longitude || second.axis == .latitude {
            swap(&first, &second)
        }
        let lat = first.value
        let lon = second.value
        guard (-90...90).contains(lat) else { throw CoordinateParseError.latitudeOutOfRange }
        guard (-180...180).contains(lon) else { throw CoordinateParseError.longitudeOutOfRange }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// تحليل مكوّن واحد (خط عرض أو طول).
    static func parseComponent(_ raw: String) throws -> ParsedComponent {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var sign: Double = 1
        var axis: Axis = .unknown

        // حروف الاتجاه (لاتينية أو عربية) في البداية أو النهاية
        let hemispheres: [(String, Double, Axis)] = [
            ("N", 1, .latitude), ("S", -1, .latitude), ("E", 1, .longitude), ("W", -1, .longitude),
            ("ش", 1, .latitude), ("ج", -1, .latitude), ("ق", 1, .longitude), ("غ", -1, .longitude)
        ]
        let upper = s.uppercased()
        for (token, sg, ax) in hemispheres {
            if upper.hasSuffix(token) {
                s = String(s.dropLast(token.count)); sign = sg; axis = ax; break
            }
            if upper.hasPrefix(token) {
                s = String(s.dropFirst(token.count)); sign = sg; axis = ax; break
            }
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("-") { sign = -sign; s.removeFirst() }
        if s.hasPrefix("+") { s.removeFirst() }

        // استخرج الأرقام بالترتيب
        let numbers = s
            .replacingOccurrences(of: "°", with: " ")
            .replacingOccurrences(of: "'", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { $0 == " " })
            .map(String.init)

        guard !numbers.isEmpty, numbers.count <= 3 else { throw CoordinateParseError.unrecognized }
        let values = try numbers.map { str -> Double in
            guard let v = Double(str), v.isFinite, v >= 0 else { throw CoordinateParseError.unrecognized }
            return v
        }
        var deg = values[0]
        if values.count >= 2 {
            guard deg == deg.rounded() else { throw CoordinateParseError.unrecognized }
            let minutes = values[1]
            guard minutes < 60 else { throw CoordinateParseError.minutesOrSecondsOutOfRange }
            if values.count == 3 {
                guard minutes == minutes.rounded() else { throw CoordinateParseError.unrecognized }
                let seconds = values[2]
                guard seconds < 60 else { throw CoordinateParseError.minutesOrSecondsOutOfRange }
                deg += minutes / 60 + seconds / 3600
            } else {
                deg += minutes / 60
            }
        }
        return ParsedComponent(value: deg * sign, axis: axis)
    }

    enum Axis { case latitude, longitude, unknown }
    struct ParsedComponent { var value: Double; var axis: Axis }

    /// يقسم النص إلى جزأين: بفاصلة، أو بعد حرف اتجاه، أو بمسافة بين رقمين عشريين.
    private static func splitPair(_ text: String) -> [String] {
        let byComma = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if byComma.count == 2 { return byComma }

        // التقسيم بعد حرف اتجاه لاتيني أو عربي مثل: 24 42 49 N 46 40 31 E
        // أو قبل حرف الاتجاه الثاني إذا كتبت الحروف قبل الأرقام: N24 42 49 E46 40 31
        let latMarkers: Set<Character> = ["N", "S", "n", "s", "ش", "ج"]
        let lonMarkers: Set<Character> = ["E", "W", "e", "w", "ق", "غ"]
        let hasDigit: (Substring) -> Bool = { $0.contains(where: { $0.isNumber }) }
        if let idx = text.firstIndex(where: { latMarkers.contains($0) }) {
            if hasDigit(text[..<idx]) {
                let after = text.index(after: idx)
                let a = String(text[..<after]).trimmingCharacters(in: .whitespaces)
                let b = String(text[after...]).trimmingCharacters(in: .whitespaces)
                if !a.isEmpty && hasDigit(Substring(b)) { return [a, b] }
            } else if let lonIdx = text.firstIndex(where: { lonMarkers.contains($0) }), lonIdx > idx {
                let a = String(text[..<lonIdx]).trimmingCharacters(in: .whitespaces)
                let b = String(text[lonIdx...]).trimmingCharacters(in: .whitespaces)
                if hasDigit(Substring(a)) && hasDigit(Substring(b)) { return [a, b] }
            }
        }
        // رقمان مفصولان بمسافة: 24.7136 46.6753
        let tokens = text.split(separator: " ").map(String.init)
        if tokens.count == 2 { return tokens }
        // صيغة الدرجات مع رموز ومسافات: نقسم على عدد الرموز °
        let degreeIdx = text.indices.filter { text[$0] == "°" }
        if degreeIdx.count == 2 {
            let cut = degreeIdx[1]
            // ابحث عن آخر مسافة قبل الدرجة الثانية
            if let space = text[..<cut].lastIndex(of: " ") {
                return [String(text[..<space]), String(text[text.index(after: space)...])]
            }
        }
        return byComma
    }

    // MARK: - التحويل والتنسيق

    struct DMS: Equatable {
        var degrees: Int
        var minutes: Int
        var seconds: Double
        var isNegative: Bool
    }

    static func toDMS(_ value: Double) -> DMS {
        let a = abs(value)
        var d = Int(a)
        var m = Int((a - Double(d)) * 60)
        var s = (a - Double(d) - Double(m) / 60) * 3600
        // تصحيح التقريب: 59.9999 ثانية
        if s >= 59.995 { s = 0; m += 1 }
        if m >= 60 { m = 0; d += 1 }
        return DMS(degrees: d, minutes: m, seconds: max(0, s), isNegative: value < 0)
    }

    static func fromDMS(_ dms: DMS) -> Double {
        let v = Double(dms.degrees) + Double(dms.minutes) / 60 + dms.seconds / 3600
        return dms.isNegative ? -v : v
    }

    static func format(_ c: CLLocationCoordinate2D, as format: CoordinateFormat) -> String {
        let latH = c.latitude >= 0 ? "ش" : "ج"
        let lonH = c.longitude >= 0 ? "ق" : "غ"
        switch format {
        case .decimal:
            return String(format: "%.6f, %.6f", c.latitude, c.longitude)
        case .dms:
            let la = toDMS(c.latitude), lo = toDMS(c.longitude)
            return String(format: "%d° %02d′ %05.2f″ %@   %d° %02d′ %05.2f″ %@",
                          la.degrees, la.minutes, la.seconds, latH,
                          lo.degrees, lo.minutes, lo.seconds, lonH)
        case .ddm:
            let lat = abs(c.latitude), lon = abs(c.longitude)
            let latD = Int(lat), lonD = Int(lon)
            return String(format: "%d° %06.3f′ %@   %d° %06.3f′ %@",
                          latD, (lat - Double(latD)) * 60, latH,
                          lonD, (lon - Double(lonD)) * 60, lonH)
        }
    }

    /// صيغة لاتينية قياسية للنسخ والمشاركة مع تطبيقات أخرى.
    static func shareString(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.6f,%.6f", c.latitude, c.longitude)
    }

    static func isValid(_ c: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(c) && !(c.latitude == 0 && c.longitude == 0)
    }
}
