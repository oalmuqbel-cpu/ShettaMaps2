import SwiftUI

/// شاشة اختبار اتصال CarPlay ومزامنة الملاحة.
struct CarPlayDiagnosticsView: View {
    @EnvironmentObject private var carPlay: CarPlayConnectionMonitor
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var offline: OfflineMapManager

    var body: some View {
        List {
            Section("الحالة الآن") {
                row("الشاشة الرئيسية لـ CarPlay", carPlay.isConnected)
                row("لوحة CarPlay (Dashboard)", carPlay.isDashboardConnected)
                row("شاشة العدادات", carPlay.isInstrumentClusterConnected)
                LabeledContent("مرات الاتصال في هذه الجلسة", value: "\(carPlay.connectionCount)")
                row("خدمات الموقع", location.isAuthorized)
                row("التحديث في الخلفية", location.backgroundEnabled)
                row("الإنترنت", network.isOnline)
                if let c = location.location?.coordinate {
                    row("خريطة دون إنترنت لهذه المنطقة", offline.hasOfflineCoverage(at: c))
                }
                LabeledContent("الملاحة النشطة", value: navigation.snapshot.plan?.destination.name ?? "لا يوجد")
            }

            Section {
                Button("بدء ملاحة تجريبية إلى نقطة على بعد 2 كم شمالًا") {
                    guard let c = location.location?.coordinate else { return }
                    let target = GeoMath.destination(from: c, distance: 2000, bearing: 0)
                    navigation.navigate(to: Waypoint(name: "نقطة اختبار", coordinate: target))
                }
                .disabled(location.location == nil)
                Button("إنهاء الملاحة", role: .destructive) { navigation.stop() }
                    .disabled(!navigation.snapshot.isNavigating)
            } header: { Text("اختبار المزامنة") } footer: {
                Text("ابدأ الملاحة من الهاتف ثم تحقق من ظهورها فورًا على شاشة السيارة أو CarPlay Simulator، ثم افصل الاتصال وأعد وصله للتأكد من استعادة الجلسة.")
            }

            Section("متطلبات التشغيل") {
                Text("يظهر التطبيق على شاشة السيارة فقط بعد موافقة Apple على صلاحية CarPlay Navigation (com.apple.developer.carplay-maps) وتضمينها في ملف التوقيع. في محاكي Xcode تعمل الصلاحية محليًا للاختبار.")
                    .font(.footnote)
                Text("دعم لوحة CarPlay وشاشة العدادات يعتمد على السيارة؛ لا تدعمه كل السيارات.")
                    .font(.footnote)
            }

            Section("سجل الأحداث") {
                if carPlay.events.isEmpty { Text("لا توجد أحداث بعد").foregroundStyle(.secondary) }
                ForEach(carPlay.events) { e in
                    VStack(alignment: .leading) {
                        Text(e.text).font(.footnote)
                        Text(Fmt.dateTime.string(from: e.date)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("اختبار CarPlay")
    }

    private func row(_ title: String, _ ok: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
        }
    }
}
