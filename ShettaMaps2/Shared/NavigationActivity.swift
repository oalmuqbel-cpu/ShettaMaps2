import Foundation
import ActivityKit

/// النشاط المباشر للملاحة (شاشة القفل والجزيرة الديناميكية). مشترك بين التطبيق وامتداد الودجت.
struct NavigationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// المسافة المتبقية حتى الوجهة النهائية (متر).
        var remaining: Double
        /// المسافة إلى النقطة الحالية (متر).
        var toTarget: Double
        var targetName: String
        /// اتجاه الهدف بالنسبة لاتجاه السير إن عُرف، وإلا الاتجاه الجغرافي.
        var arrowDegrees: Double
        var relative: Bool
        var cardinal: String
        var eta: Date?
        var arrived: Bool
    }
    var destination: String
}

enum ActivityFormat {
    static func distance(_ m: Double) -> String {
        if m < 1000 { return "\(Int((m / 10).rounded() * 10)) م" }
        if m < 10_000 { return String(format: "%.1f كم", m / 1000) }
        return "\(Int((m / 1000).rounded())) كم"
    }
}
