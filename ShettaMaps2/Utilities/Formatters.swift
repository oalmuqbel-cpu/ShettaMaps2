import Foundation

/// تنسيق المسافات والمدد والسرعات بالعربية (وحدات مترية).
enum Fmt {
    private static let arabic = Locale(identifier: "ar")

    static func distance(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        if meters < 1000 {
            return "\(Int(meters.rounded())) م"
        }
        let km = meters / 1000
        return km < 100 ? String(format: "%.2f كم", km) : String(format: "%.0f كم", km)
    }

    /// مسافة الملاحة على الطرق بصيغة مقرّبة مثل تطبيقات القيادة: «150 م»، «1.9 كم»، «24 كم».
    static func navDistance(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "—" }
        if meters < 1000 {
            let step: Double = meters < 100 ? 10 : 50
            return "\(Int(max(step, (meters / step).rounded() * step))) م"
        }
        let km = meters / 1000
        return km < 10 ? String(format: "%.1f كم", km) : "\(Int(km.rounded())) كم"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    /// مدة الرحلة بأسلوب تطبيقات الملاحة: «13 د» أو «1 س 6 د».
    static func tripDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(max(1, m)) د" }
        return m % 60 == 0 ? "\(m / 60) س" : "\(m / 60) س \(m % 60) د"
    }

    /// السرعة من متر/ثانية إلى كم/س.
    static func speed(_ mps: Double?) -> String {
        guard let mps, mps >= 0, mps.isFinite else { return "—" }
        return String(format: "%.0f كم/س", mps * 3.6)
    }

    static func bearing(_ deg: Double) -> String {
        "\(Int(GeoMath.normalizeDegrees(deg).rounded()) % 360)° \(GeoMath.cardinalName(deg))"
    }

    static func accuracy(_ meters: Double?) -> String {
        guard let meters, meters >= 0 else { return "غير متوفرة" }
        return "± \(Int(meters.rounded())) م"
    }

    static func altitude(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return "\(Int(meters.rounded())) م"
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = arabic
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = arabic
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
