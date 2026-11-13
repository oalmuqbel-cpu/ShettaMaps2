import SwiftUI
import SwiftData
import CoreLocation
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var carPlay: CarPlayConnectionMonitor
    @AppStorage(SettingsKeys.batteryMode) private var batteryRaw = BatteryMode.balanced.rawValue
    @AppStorage(SettingsKeys.autoRecordTrips) private var autoRecord = true
    @AppStorage(SettingsKeys.autoPauseMinutes) private var autoPauseMinutes = 15.0
    @AppStorage(SettingsKeys.highContrast) private var highContrast = false
    @AppStorage(SettingsKeys.coordinateFormat) private var formatRaw = CoordinateFormat.decimal.rawValue
    @AppStorage(SettingsKeys.iCloudSync) private var iCloudSync = false
    @AppStorage(SettingsKeys.weakGPSThreshold) private var weakThreshold = 50.0

    @State private var backupURL: URL?
    @State private var restoring = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("الموقع") {
                LabeledContent("الإذن", value: authorizationText)
                LabeledContent("الدقة", value: location.isFullAccuracy ? "كاملة" : "تقريبية")
                if location.authorization == .authorizedWhenInUse {
                    Button("السماح بالموقع دائمًا (للتسجيل في الخلفية)") { location.requestAlwaysIfNeeded() }
                }
                Button("فتح إعدادات النظام") { location.openSystemSettings() }
                NavigationLink("الأقمار الصناعية والاتصال") { SatelliteInfoView() }
            }

            Section {
                Picker("وضع التتبع", selection: $batteryRaw) {
                    ForEach(BatteryMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: batteryRaw) { _, _ in location.applyBatteryMode() }
                Text(BatteryMode(rawValue: batteryRaw)?.detail ?? "").font(.caption).foregroundStyle(.secondary)
                Stepper("تنبيه ضعف GPS عند دقة أسوأ من \(Int(weakThreshold)) م", value: $weakThreshold, in: 20...200, step: 10)
            } header: { Text("البطارية والدقة") }

            Section("الرحلات والعرض") {
                Toggle("تسجيل المسار تلقائيًا عند بدء رحلة", isOn: $autoRecord)
                Picker("إيقاف التسجيل عند الوقوف", selection: $autoPauseMinutes) {
                    Text("بدون").tag(0.0)
                    ForEach([5.0, 10, 15, 30], id: \.self) { Text("بعد \(Int($0)) دقيقة").tag($0) }
                }
                Toggle("تباين عالٍ للاستخدام تحت الشمس", isOn: $highContrast)
                Picker("صيغة الإحداثيات", selection: $formatRaw) {
                    ForEach(CoordinateFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }

            Section {
                NavigationLink("مصدر الخرائط دون إنترنت") { MapSourceSettingsView() }
                NavigationLink("الخرائط المحفوظة") { OfflineMapsView() }
            } header: { Text("الخرائط") }

            Section {
                Toggle("المزامنة عبر iCloud بين أجهزتك", isOn: $iCloudSync)
                LabeledContent("الحالة", value: AppEnvironment.shared.isCloudSyncActive ? "مفعلة" : "التخزين محلي فقط")
                if let n = AppEnvironment.shared.storageNotice { Text(n).font(.caption).foregroundStyle(.orange) }
            } header: { Text("المزامنة") } footer: {
                Text("اختيارية وتعمل عبر حسابك الخاص في iCloud (CloudKit)؛ تبقى البيانات على جهازك وتعمل دون إنترنت، وتُزامن عند توفر الاتصال. يتطلب تفعيلها إعادة تشغيل التطبيق وإضافة قدرة iCloud في المشروع.")
            }

            Section("النسخ الاحتياطي") {
                Button { makeBackup() } label: { Label("إنشاء نسخة احتياطية ومشاركتها", systemImage: "externaldrive.badge.plus") }
                Button { restoring = true } label: { Label("استعادة من نسخة احتياطية", systemImage: "externaldrive.badge.timemachine") }
            }

            Section("المجتمع") {
                NavigationLink("المشاركة المجتمعية") { CommunitySettingsView() }
            }

            Section("CarPlay") {
                NavigationLink("حالة الاتصال والاختبار") { CarPlayDiagnosticsView() }
                LabeledContent("الحالة", value: carPlay.isConnected ? "متصل" : "غير متصل")
            }

            Section("الخصوصية") {
                Text("تُحفظ مواقعك ومساراتك ورحلاتك على جهازك فقط. لا يُرسل أي مكان إلى خادم إلا إذا اخترت له «عام» عند الحفظ، وحينها يُرسل الاسم والإحداثيات والنوع والملاحظات فقط دون أي معلومات عنك. عند استخدام خرائط الإنترنت أو البحث عبر الإنترنت أو توجيهات الطرق، تُرسل Apple أو مزوّد الخرائط الطلبات اللازمة لتلك الخدمة فقط.")
                    .font(.footnote)
            }

            Section("حول") {
                LabeledContent("الإصدار", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                Text("محرك الخرائط دون إنترنت: MapLibre Native (رخصة BSD-2). الخرائط دون إنترنت: OpenFreeMap. الخرائط عبر الإنترنت: Apple MapKit.").font(.footnote)
                Text("أسماء الأماكن المعروفة: © OpenStreetMap contributors، متاحة بموجب رخصة Open Database License (ODbL).").font(.footnote)
            }
        }
        .navigationTitle("الإعدادات")
        .sheet(item: Binding(get: { backupURL.map(ShareItem.init) }, set: { backupURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $restoring, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                do {
                    let s = try BackupService.restore(from: url, context: context)
                    message = "تمت الاستعادة: \(s.places) موقع، \(s.tracks) مسار، \(s.trips) رحلة. تم تجاهل \(s.skipped) عنصر موجود مسبقًا."
                } catch { message = "تعذّرت الاستعادة: \(error.localizedDescription)" }
            }
        }
        .alert("النسخ الاحتياطي", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var authorizationText: String {
        switch location.authorization {
        case .authorizedAlways: return "دائمًا"
        case .authorizedWhenInUse: return "أثناء الاستخدام"
        case .denied: return "مرفوض"
        case .restricted: return "مقيد"
        case .notDetermined: return "لم يُحدد"
        @unknown default: return "غير معروف"
        }
    }

    private func makeBackup() {
        do { backupURL = try BackupService.makeBackup(context: context) }
        catch { message = "تعذّر إنشاء النسخة: \(error.localizedDescription)" }
    }
}

/// توضيح الفرق بين استقبال إشارات الأقمار الصناعية وصور الأقمار الصناعية والاتصال الفضائي.
struct SatelliteInfoView: View {
    @EnvironmentObject private var location: LocationManager

    var body: some View {
        List {
            Section("استقبال إشارات تحديد الموقع") {
                Text("يحدد الآيفون موقعك عبر شريحة استقبال أنظمة الملاحة بالأقمار الصناعية (مثل GPS وGLONASS وGalileo وBeiDou حسب الجهاز). هذا الاستقبال لا يحتاج إلى إنترنت أو شبكة جوال، لذلك تعمل الإحداثيات والتسجيل والملاحة في الصحراء.")
                Text("لا يتيح نظام iOS للتطبيقات معرفة عدد الأقمار أو قوة الإشارة لكل قمر، لذلك يعرض التطبيق الدقة الأفقية التي يقدرها النظام بالأمتار.")
                    .foregroundStyle(.secondary)
                if let loc = location.location {
                    LabeledContent("الدقة الحالية", value: Fmt.accuracy(loc.horizontalAccuracy))
                    LabeledContent("جودة الإشارة", value: location.gpsQuality.title)
                    if location.isSimulatedLocation {
                        Label("الموقع الحالي محاكى برمجيًا (وضع تطوير أو جهاز ملحق).", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("صور الأقمار الصناعية") {
                Text("طبقة «أقمار صناعية» صور جوية تقدمها Apple Maps عبر الإنترنت، وهي منفصلة تمامًا عن تحديد الموقع، ولا تتوفر دون اتصال.")
            }
            Section("الاتصال الفضائي") {
                Text("بعض أجهزة الآيفون تدعم ميزات Apple للاتصال عبر الأقمار الصناعية (مثل طوارئ SOS ومشاركة الموقع في تطبيق «تحديد الموقع») في الدول المدعومة. هذه الميزات تابعة لنظام iOS وحده، ولا يستطيع هذا التطبيق أو أي تطبيق آخر تفعيلها أو استخدامها لنقل البيانات أو الاتصال بالإنترنت.")
                Text("في حالة الطوارئ استخدم ميزات النظام أو أرقام الطوارئ المحلية.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("الأقمار الصناعية")
    }
}
