import XCTest
import SwiftUI
@testable import ShettaMaps2

/// يتحقق برسم فعلي أن إبرة البوصلة تشير إلى الشمال الصحيح، وأن الواجهة العربية (من اليمين لليسار) لا تعكس الدوران.
@MainActor
final class CompassRenderingTests: XCTestCase {

    /// مركز البكسلات الحمراء (إبرة الشمال) بالنسبة لمركز الصورة: x موجب = يمين، y موجب = أسفل.
    private func redCentroid(_ view: some View, size: CGFloat = 120) -> CGPoint? {
        let r = ImageRenderer(content: view.frame(width: size, height: size).background(Color.white))
        r.scale = 1
        guard let cg = r.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let rr = Int(data[i]), gg = Int(data[i + 1]), bb = Int(data[i + 2])
                if rr > 170 && gg < 90 && bb < 90 { sx += Double(x); sy += Double(y); n += 1 }
            }
        }
        guard n > 5 else { return nil }
        // بيانات CGContext تبدأ من أعلى الصورة
        return CGPoint(x: sx / n - Double(w) / 2, y: sy / n - Double(h) / 2)
    }

    private func dial(_ heading: Double) -> some View {
        CompassDial(heading: heading).frame(width: 54, height: 54)
            .environment(\.layoutDirection, .rightToLeft)   // نفس بيئة التطبيق العربية
    }

    /// اكتُشف بهذا الاختبار: في الواجهة العربية يعكس SwiftUI اتجاه rotationEffect، وكان هذا سبب خطأ البوصلة وسهم الملاحة.
    func testRotationIsMirroredInRightToLeftWithoutFix() {
        let bar = Rectangle().fill(Color.red).frame(width: 8, height: 40).offset(y: -20)
            .frame(width: 100, height: 100)
            .rotationEffect(.degrees(90))
            .environment(\.layoutDirection, .rightToLeft)
        let c = redCentroid(bar)
        XCTAssertNotNil(c)
        XCTAssertLessThan(c!.x, -10)
    }

    /// الحل المستخدم في التطبيق: تثبيت اتجاه الرسم من اليسار لليمين حول الدوران.
    func testRotationCorrectWhenWrappedLeftToRight() {
        let bar = Rectangle().fill(Color.red).frame(width: 8, height: 40).offset(y: -20)
            .frame(width: 100, height: 100)
            .rotationEffect(.degrees(90))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.layoutDirection, .rightToLeft)
        let c = redCentroid(bar)
        XCTAssertNotNil(c)
        // دوران +90 (مع عقارب الساعة): الخط الذي كان للأعلى يصبح لليمين
        XCTAssertGreaterThan(c!.x, 10)
    }

    /// سهم الملاحة: هدف على يمينك (+90) يجب أن يشير السهم لليمين.
    func testNavigationArrowPointsRightForTargetOnRight() {
        let arrow = Rectangle().fill(Color.red).frame(width: 8, height: 30).offset(y: -15)
            .frame(width: 80, height: 80)
            .rotationEffect(.degrees(90))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.layoutDirection, .rightToLeft)
        XCTAssertGreaterThan(redCentroid(arrow)!.x, 10)
    }

    func testNeedlePointsNorthWhenFacingNorth() {
        let c = redCentroid(dial(0))
        XCTAssertNotNil(c)
        XCTAssertLessThan(c!.y, -3, "عند الاتجاه شمالًا يجب أن تكون الإبرة الحمراء للأعلى")
        XCTAssertLessThan(abs(c!.x), 3)
    }

    func testNeedlePointsLeftWhenFacingEast() {
        // مواجهة الشرق: الشمال على يسار المستخدم
        let c = redCentroid(dial(90))
        XCTAssertNotNil(c)
        XCTAssertLessThan(c!.x, -3, "عند مواجهة الشرق يجب أن تشير الإبرة الحمراء لليسار")
    }

    func testNeedlePointsRightWhenFacingWest() {
        let c = redCentroid(dial(270))
        XCTAssertNotNil(c)
        XCTAssertGreaterThan(c!.x, 3, "عند مواجهة الغرب يجب أن تشير الإبرة الحمراء لليمين")
    }

    func testNeedlePointsDownWhenFacingSouth() {
        let c = redCentroid(dial(180))
        XCTAssertNotNil(c)
        XCTAssertGreaterThan(c!.y, 3)
    }
}
