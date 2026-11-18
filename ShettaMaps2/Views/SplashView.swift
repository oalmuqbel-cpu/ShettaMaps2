import SwiftUI

/// شاشة البداية: تكمل شاشة الإطلاق (نفس الخلفية والشعار في المنتصف) ثم يظهر الاسم ومؤشر التحميل،
/// وتختفي بانسياب بعد تجهيز الخريطة.
struct SplashView: View {
    @State private var showTitle = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            Image("LaunchLogo")
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("سَمْت")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.brown)
                Text("الملاحة البرية")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProgressView().padding(.top, 14).tint(Theme.desertOrange)
            }
            .offset(y: 150)
            .opacity(showTitle ? 1 : 0)
        }
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { showTitle = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("سَمْت، جارٍ التحميل")
    }
}
