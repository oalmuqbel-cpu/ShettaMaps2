import SwiftUI
import UIKit

/// الهوية البصرية: برتقالي صحراوي، بني، بيج، أبيض — مع دعم الوضع الداكن والتباين العالي.
enum Theme {
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static let desertOrangeUI = dynamic(light: UIColor(red: 0.851, green: 0.510, blue: 0.169, alpha: 1),
                                        dark: UIColor(red: 0.945, green: 0.600, blue: 0.267, alpha: 1))
    static let brownUI = dynamic(light: UIColor(red: 0.420, green: 0.267, blue: 0.137, alpha: 1),
                                 dark: UIColor(red: 0.776, green: 0.584, blue: 0.408, alpha: 1))
    static let beigeUI = dynamic(light: UIColor(red: 0.965, green: 0.937, blue: 0.886, alpha: 1),
                                 dark: UIColor(red: 0.141, green: 0.110, blue: 0.086, alpha: 1))
    static let sandUI = dynamic(light: UIColor(red: 0.937, green: 0.890, blue: 0.812, alpha: 1),
                                dark: UIColor(red: 0.220, green: 0.176, blue: 0.137, alpha: 1))
    static let routeUI = UIColor(red: 0.851, green: 0.400, blue: 0.098, alpha: 1)
    static let trackUI = UIColor(red: 0.420, green: 0.267, blue: 0.137, alpha: 1)
    static let directLineUI = UIColor(red: 0.150, green: 0.380, blue: 0.780, alpha: 1)

    static let desertOrange = Color(uiColor: desertOrangeUI)
    static let brown = Color(uiColor: brownUI)
    static let beige = Color(uiColor: beigeUI)
    static let sand = Color(uiColor: sandUI)
    static let route = Color(uiColor: routeUI)
    static let track = Color(uiColor: trackUI)
    /// مساراتي السابقة عند عرضها كلها على الخريطة: أزرق مميز عن المسار الحالي والمستورد.
    static let myTracksUI = UIColor(red: 0.10, green: 0.42, blue: 0.85, alpha: 0.85)
    static let myTracks = Color(uiColor: myTracksUI)
    static let directLine = Color(uiColor: directLineUI)

    /// لون مؤشر دقة GPS.
    static func accuracyColor(_ meters: Double?) -> Color {
        guard let m = meters, m >= 0 else { return .gray }
        switch m {
        case ..<15: return .green
        case ..<50: return .orange
        default: return .red
        }
    }
}

/// نظام التصميم: مقاسات ومسافات وزوايا موحّدة لكل ما يطفو فوق الخريطة، حتى تتناسق الأحجام في الجوال والآيباد.
enum DS {
    /// مقاس كل زر عائم ومعلومة جانبية (عرض العمود).
    static let control: CGFloat = 46
    /// زاوية الأزرار المربعة الناعمة ومجموعاتها.
    static let controlRadius: CGFloat = 13
    /// زاوية البطاقات.
    static let cardRadius: CGFloat = 16
    /// المسافات.
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
    /// أقصى عرض للبطاقات العلوية على الشاشات الكبيرة (الآيباد) حتى لا تمتد بلا داعٍ.
    static let panelMaxWidth: CGFloat = 460
    static let actionBarMaxWidth: CGFloat = 620
    /// خط أيقونات الأزرار: وزن وحجم واحد في كل مكان.
    static let iconFont = Font.system(size: 17, weight: .semibold)
    /// ظل واحد لكل العناصر العائمة.
    static let shadow = Color.black.opacity(0.14)
}

/// بطاقة زجاجية للعناصر فوق الخريطة، مع دعم وضع التباين العالي للاستخدام تحت الشمس.
struct HUDCard: ViewModifier {
    @AppStorage(SettingsKeys.highContrast) private var highContrast = false
    var padding: CGFloat = 10
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                if highContrast {
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(Color(uiColor: .systemBackground))
                        .overlay(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).stroke(Color.primary, lineWidth: 2))
                } else {
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous).fill(.regularMaterial)
                }
            }
            .shadow(color: highContrast ? .clear : DS.shadow, radius: 8, y: 2)
    }
}

extension View {
    func hudCard(padding: CGFloat = 10) -> some View { modifier(HUDCard(padding: padding)) }

    /// خلفية موحّدة للأزرار والمعلومات العائمة (مربع ناعم الزوايا).
    func floatingSurface(active: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous)
            .fill(active ? AnyShapeStyle(Theme.desertOrange) : AnyShapeStyle(.regularMaterial)))
            .shadow(color: DS.shadow, radius: 6, y: 2)
    }
}

/// زر عائم موحّد لأدوات الخريطة.
struct MapControlButton: View {
    let systemImage: String
    let label: String
    var tint: Color = Theme.brown
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MapControlGlyph(systemImage: systemImage, tint: tint, isActive: isActive)
                .floatingSurface(active: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// أيقونة زر عائم بلا خلفية (تُستخدم داخل مجموعة أزرار).
struct MapControlGlyph: View {
    let systemImage: String
    var text: String? = nil
    var tint: Color = Theme.brown
    var isActive: Bool = false
    var body: some View {
        Group {
            if let text {
                Text(text).font(.system(size: 15, weight: .heavy, design: .rounded))
            } else {
                Image(systemName: systemImage).font(DS.iconFont)
            }
        }
        .frame(width: DS.control, height: DS.control)
        .foregroundStyle(isActive ? Color.white : tint)
        .contentShape(Rectangle())
    }
}

/// مجموعة أزرار متلاصقة بفواصل (مثل التكبير والتصغير)، بخلفية واحدة.
struct MapControlGroup: View {
    struct Item: Identifiable {
        let id: String
        let systemImage: String
        var text: String? = nil
        let label: String
        var isActive = false
        let action: () -> Void
    }
    let items: [Item]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().frame(width: DS.control - 14) }
                Button(action: item.action) {
                    MapControlGlyph(systemImage: item.systemImage, text: item.text, isActive: item.isActive)
                        .background(item.isActive ? Theme.desertOrange : Color.clear)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous))
        .floatingSurface()
    }
}

/// زر إجراء في الشريط السفلي للشاشة الرئيسية.
struct ActionTile: View {
    let systemImage: String
    let title: String
    var tint: Color = Theme.desertOrange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(DS.iconFont)
                    .foregroundStyle(tint)
                    .frame(height: 22)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
