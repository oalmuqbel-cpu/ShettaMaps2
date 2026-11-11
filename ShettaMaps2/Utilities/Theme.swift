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

/// بطاقة زجاجية للعناصر فوق الخريطة، مع دعم وضع التباين العالي للاستخدام تحت الشمس.
struct HUDCard: ViewModifier {
    @AppStorage(SettingsKeys.highContrast) private var highContrast = false
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background {
                if highContrast {
                    RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .systemBackground))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary, lineWidth: 2))
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                }
            }
            .shadow(color: .black.opacity(highContrast ? 0 : 0.15), radius: 6, y: 2)
    }
}

extension View {
    func hudCard() -> some View { modifier(HUDCard()) }
}

/// زر دائري موحّد لأدوات الخريطة.
struct MapControlButton: View {
    let systemImage: String
    let label: String
    var tint: Color = Theme.brown
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(isActive ? Color.white : tint)
                .background(Circle().fill(isActive ? AnyShapeStyle(Theme.desertOrange) : AnyShapeStyle(.regularMaterial)))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        }
        .accessibilityLabel(label)
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
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
