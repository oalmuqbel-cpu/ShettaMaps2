import SwiftUI
import UIKit

/// شكل علامة موقعي على الخريطة. المركبات مرسومة من الأعلى وتدور مع اتجاه السير.
enum UserMarkerStyle: String, CaseIterable, Identifiable {
    case dot, arrow, sedan, suv, pickup, openJeep, caravan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dot: return "النقطة الافتراضية"
        case .arrow: return "سهم اتجاه"
        case .sedan: return "سيارة"
        case .suv: return "جيب"
        case .pickup: return "جيب غمارة"
        case .openJeep: return "جيب مكشوف"
        case .caravan: return "سيارة مع كرفان"
        }
    }
    /// الحجم الطبيعي للرسمة (العرض × الطول) بالنقاط.
    var canvasSize: CGSize {
        switch self {
        case .dot, .arrow: return CGSize(width: 34, height: 34)
        case .sedan: return CGSize(width: 26, height: 46)
        case .suv, .openJeep: return CGSize(width: 28, height: 46)
        case .pickup: return CGSize(width: 28, height: 52)
        case .caravan: return CGSize(width: 32, height: 84)
        }
    }
    static var current: UserMarkerStyle {
        UserMarkerStyle(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.userMarkerStyle) ?? "") ?? .dot
    }
}

enum UserMarkerColor: String, CaseIterable, Identifiable {
    case white, black, sand, red, blue, green, gray
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: return "أبيض"
        case .black: return "أسود"
        case .sand: return "رملي"
        case .red: return "أحمر"
        case .blue: return "أزرق"
        case .green: return "أخضر"
        case .gray: return "رمادي"
        }
    }
    var color: Color {
        switch self {
        case .white: return Color(white: 0.97)
        case .black: return Color(white: 0.16)
        case .sand: return Color(red: 0.85, green: 0.74, blue: 0.55)
        case .red: return Color(red: 0.75, green: 0.13, blue: 0.13)
        case .blue: return Color(red: 0.13, green: 0.33, blue: 0.70)
        case .green: return Color(red: 0.22, green: 0.42, blue: 0.25)
        case .gray: return Color(white: 0.62)
        }
    }
    static var current: UserMarkerColor {
        UserMarkerColor(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.userMarkerColor) ?? "") ?? .white
    }
}

/// رسم علامة الموقع متجهة للأعلى (الشمال قبل التدوير).
struct VehicleMarkerView: View {
    let style: UserMarkerStyle
    let color: UserMarkerColor

    var body: some View {
        let size = style.canvasSize
        Canvas { ctx, _ in draw(&ctx) }
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .accessibilityLabel("موقعي: \(style.title)")
    }

    private var body1: Color { color.color }
    private let outline = Color.black.opacity(0.75)
    private let glass = Color(red: 0.16, green: 0.22, blue: 0.30)
    private let tire = Color(white: 0.08)

    private func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private func fillStroke(_ ctx: inout GraphicsContext, _ p: Path, _ fill: Color, line: CGFloat = 1.2) {
        ctx.fill(p, with: .color(fill))
        ctx.stroke(p, with: .color(outline), lineWidth: line)
    }

    private func wheels(_ ctx: inout GraphicsContext, x: CGFloat, w: CGFloat, ys: [CGFloat]) {
        for y in ys {
            ctx.fill(rr(x - 2, y, 3, 8, 1), with: .color(tire))
            ctx.fill(rr(x + w - 1, y, 3, 8, 1), with: .color(tire))
        }
    }

    private func headlights(_ ctx: inout GraphicsContext, x: CGFloat, w: CGFloat, y: CGFloat) {
        let lamp = Color(red: 1.0, green: 0.93, blue: 0.62)
        ctx.fill(rr(x + 2, y, 5, 2.4, 1), with: .color(lamp))
        ctx.fill(rr(x + w - 7, y, 5, 2.4, 1), with: .color(lamp))
    }

    private func draw(_ ctx: inout GraphicsContext) {
        switch style {
        case .dot:
            let c = Path(ellipseIn: CGRect(x: 7, y: 7, width: 20, height: 20))
            ctx.fill(c, with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: 10, y: 10, width: 14, height: 14)), with: .color(.blue))
        case .arrow:
            var p = Path()
            p.move(to: CGPoint(x: 17, y: 2))
            p.addLine(to: CGPoint(x: 31, y: 31))
            p.addLine(to: CGPoint(x: 17, y: 24))
            p.addLine(to: CGPoint(x: 3, y: 31))
            p.closeSubpath()
            fillStroke(&ctx, p, color == .white ? Color(red: 0.85, green: 0.45, blue: 0.12) : body1, line: 1.6)
        case .sedan:
            drawSedan(&ctx, x: 3, y: 1, w: 20, h: 44)
        case .suv:
            drawSUV(&ctx, x: 3, y: 1, w: 22, h: 44, spare: true)
        case .pickup:
            drawPickup(&ctx)
        case .openJeep:
            drawOpenJeep(&ctx)
        case .caravan:
            drawSUV(&ctx, x: 5, y: 1, w: 22, h: 40, spare: false)
            // وصلة السحب ثم الكرفان خلف السيارة
            ctx.fill(rr(14.5, 41, 3, 6, 1), with: .color(Color(white: 0.25)))
            let trailer = rr(2, 47, 28, 36, 4)
            fillStroke(&ctx, trailer, Color(white: 0.95))
            ctx.fill(rr(5, 50, 22, 4, 1.5), with: .color(color == .white ? Color(red: 0.62, green: 0.35, blue: 0.15) : body1))
            ctx.fill(rr(9, 58, 14, 9, 2), with: .color(Color(white: 0.80)))
            ctx.fill(rr(0, 62, 2.5, 8, 1), with: .color(tire))
            ctx.fill(rr(29.5, 62, 2.5, 8, 1), with: .color(tire))
        }
    }

    private func drawSedan(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        wheels(&ctx, x: x, w: w, ys: [y + 7, y + h - 14])
        fillStroke(&ctx, rr(x, y, w, h, 7), body1)
        headlights(&ctx, x: x, w: w, y: y + 1.5)
        // الزجاج الأمامي والسقف والزجاج الخلفي
        var wind = Path()
        wind.move(to: CGPoint(x: x + 3, y: y + 17)); wind.addLine(to: CGPoint(x: x + w - 3, y: y + 17))
        wind.addLine(to: CGPoint(x: x + w - 5, y: y + 12)); wind.addLine(to: CGPoint(x: x + 5, y: y + 12)); wind.closeSubpath()
        ctx.fill(wind, with: .color(glass))
        ctx.fill(rr(x + 4, y + 18, w - 8, 14, 3), with: .color(body1.opacity(0.85)))
        ctx.stroke(rr(x + 4, y + 18, w - 8, 14, 3), with: .color(outline.opacity(0.4)), lineWidth: 0.6)
        ctx.fill(rr(x + 4.5, y + 33, w - 9, 5, 2), with: .color(glass))
        ctx.fill(rr(x - 1.5, y + 15, 2, 2.5, 1), with: .color(outline))
        ctx.fill(rr(x + w - 0.5, y + 15, 2, 2.5, 1), with: .color(outline))
    }

    private func drawSUV(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, spare: Bool) {
        wheels(&ctx, x: x, w: w, ys: [y + 6, y + h - 13])
        fillStroke(&ctx, rr(x, y, w, h, 4), body1)
        headlights(&ctx, x: x, w: w, y: y + 1.5)
        // شبك أمامي
        for i in 0..<3 { ctx.fill(rr(x + w / 2 - 4 + CGFloat(i) * 3, y + 1.6, 1.4, 2.6, 0.5), with: .color(outline.opacity(0.7))) }
        ctx.fill(rr(x + 2.5, y + 11, w - 5, 5.5, 1.5), with: .color(glass))
        // سقف مع حمّال
        let roof = rr(x + 3, y + 17.5, w - 6, h - 25, 2)
        ctx.fill(roof, with: .color(body1.opacity(0.88)))
        ctx.stroke(roof, with: .color(outline.opacity(0.5)), lineWidth: 0.7)
        for i in 0..<4 {
            let yy = y + 20 + CGFloat(i) * (h - 30) / 3
            ctx.fill(rr(x + 4, yy, w - 8, 1.1, 0.5), with: .color(outline.opacity(0.55)))
        }
        ctx.fill(rr(x + 3.5, y + h - 7, w - 7, 3.5, 1), with: .color(glass))
        if spare {
            let s = Path(ellipseIn: CGRect(x: x + w / 2 - 4.5, y: y + h - 4, width: 9, height: 5))
            ctx.fill(s, with: .color(tire))
        }
        ctx.fill(rr(x - 1.5, y + 12, 2, 2.5, 1), with: .color(outline))
        ctx.fill(rr(x + w - 0.5, y + 12, 2, 2.5, 1), with: .color(outline))
    }

    private func drawPickup(_ ctx: inout GraphicsContext) {
        let x: CGFloat = 3, y: CGFloat = 1, w: CGFloat = 22, h: CGFloat = 50
        wheels(&ctx, x: x, w: w, ys: [y + 6, y + h - 14])
        fillStroke(&ctx, rr(x, y, w, h, 4), body1)
        headlights(&ctx, x: x, w: w, y: y + 1.5)
        ctx.fill(rr(x + 2.5, y + 11, w - 5, 5.5, 1.5), with: .color(glass))
        ctx.fill(rr(x + 3, y + 17, w - 6, 9, 2), with: .color(body1.opacity(0.88)))
        ctx.fill(rr(x + 3.5, y + 26.5, w - 7, 2.5, 1), with: .color(glass))
        // الصندوق الخلفي
        let bed = rr(x + 2.5, y + 31, w - 5, h - 33, 1.5)
        ctx.fill(bed, with: .color(Color(white: 0.25)))
        ctx.stroke(bed, with: .color(body1), lineWidth: 1.4)
        ctx.fill(rr(x - 1.5, y + 12, 2, 2.5, 1), with: .color(outline))
        ctx.fill(rr(x + w - 0.5, y + 12, 2, 2.5, 1), with: .color(outline))
    }

    private func drawOpenJeep(_ ctx: inout GraphicsContext) {
        let x: CGFloat = 3, y: CGFloat = 1, w: CGFloat = 22, h: CGFloat = 42
        wheels(&ctx, x: x, w: w, ys: [y + 5, y + h - 12])
        fillStroke(&ctx, rr(x, y, w, h, 3), body1)
        // شبك بفتحات عمودية
        for i in 0..<5 { ctx.fill(rr(x + 4.5 + CGFloat(i) * 2.8, y + 1.6, 1.3, 3.2, 0.5), with: .color(outline.opacity(0.8))) }
        ctx.fill(Path(ellipseIn: CGRect(x: x + 1.5, y: y + 1.5, width: 3.5, height: 3.5)), with: .color(Color(red: 1, green: 0.93, blue: 0.62)))
        ctx.fill(Path(ellipseIn: CGRect(x: x + w - 5, y: y + 1.5, width: 3.5, height: 3.5)), with: .color(Color(red: 1, green: 0.93, blue: 0.62)))
        ctx.fill(rr(x + 2.5, y + 11, w - 5, 2.2, 1), with: .color(glass))
        // مقصورة مكشوفة: مقاعد وقوس حماية
        let cab = rr(x + 2.5, y + 14, w - 5, h - 20, 2)
        ctx.fill(cab, with: .color(Color(white: 0.22)))
        ctx.fill(rr(x + 4, y + 17, 6, 6, 1.5), with: .color(Color(white: 0.45)))
        ctx.fill(rr(x + w - 10, y + 17, 6, 6, 1.5), with: .color(Color(white: 0.45)))
        ctx.fill(rr(x + 4, y + 27, w - 8, 5, 1.5), with: .color(Color(white: 0.45)))
        ctx.fill(rr(x + 2, y + 24.5, w - 4, 1.6, 0.8), with: .color(Color(white: 0.75)))
        let s = Path(ellipseIn: CGRect(x: x + w / 2 - 4.5, y: y + h - 3, width: 9, height: 5))
        ctx.fill(s, with: .color(tire))
    }
}

enum VehicleMarkerImage {
    /// صورة بدقة الشاشة للاستخدام في خريطة MapLibre.
    @MainActor static func make(style: UserMarkerStyle, color: UserMarkerColor) -> UIImage? {
        let r = ImageRenderer(content: VehicleMarkerView(style: style, color: color).padding(3))
        r.scale = UIScreen.main.scale
        return r.uiImage
    }
}

/// اختيار شكل علامة الموقع ولونها من الإعدادات.
struct UserMarkerSettingsView: View {
    @AppStorage(SettingsKeys.userMarkerStyle) private var styleRaw = UserMarkerStyle.dot.rawValue
    @AppStorage(SettingsKeys.userMarkerColor) private var colorRaw = UserMarkerColor.white.rawValue

    private var style: UserMarkerStyle { UserMarkerStyle(rawValue: styleRaw) ?? .dot }
    private var color: UserMarkerColor { UserMarkerColor(rawValue: colorRaw) ?? .white }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                    ForEach(UserMarkerStyle.allCases) { s in
                        Button { styleRaw = s.rawValue } label: {
                            VStack(spacing: 8) {
                                VehicleMarkerView(style: s, color: color)
                                    .frame(height: 86)
                                Text(s.title).font(.caption).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12)
                                .fill(s == style ? Theme.desertOrange.opacity(0.18) : Color(.secondarySystemBackground)))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .stroke(s == style ? Theme.desertOrange : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(s == style ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            } header: { Text("الشكل") } footer: {
                Text("المركبة تدور مع اتجاه سيرك، وعند الوقوف تتبع اتجاه البوصلة.")
            }
            if style != .dot {
                Section("اللون") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(UserMarkerColor.allCases) { c in
                                Button { colorRaw = c.rawValue } label: {
                                    VStack(spacing: 4) {
                                        Circle().fill(c.color).frame(width: 34, height: 34)
                                            .overlay(Circle().stroke(c == color ? Theme.desertOrange : Color.secondary.opacity(0.4),
                                                                     lineWidth: c == color ? 3 : 1))
                                        Text(c.title).font(.caption2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("شكل موقعي على الخريطة")
    }
}
