import SwiftUI
import CoreLocation

// MARK: - الرحلة الآمنة

struct SafeTripView: View {
    @EnvironmentObject private var safeTrip: SafeTripManager
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var network: NetworkMonitor
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.emergencyNumber) private var emergencyNumber = ""
    @AppStorage("safeTrip.lastName") private var name = ""
    @State private var contact = ""
    @State private var hours = 6
    @State private var composing = false
    @State private var shareText: String?
    @State private var confirmEnd = false
    @State private var sendArrival = false

    var body: some View {
        Form {
            if let s = safeTrip.state {
                activeSection(s)
            } else {
                setupSection
            }
        }
        .navigationTitle("الرحلة الآمنة")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        .onAppear { if contact.isEmpty { contact = emergencyNumber } }
        .sheet(isPresented: $composing) {
            MessageComposer(recipients: [safeTrip.state?.contact ?? contact].filter { !$0.isEmpty }, body: safeTrip.message)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $sendArrival) {
            MessageComposer(recipients: [contact].filter { !$0.isEmpty }, body: "وصلت بالسلامة، وأنهيت الرحلة الآمنة. شكرًا لمتابعتك.")
                .ignoresSafeArea()
        }
        .sheet(item: Binding(get: { shareText.map { ShareText(text: $0) } }, set: { shareText = $0?.text })) {
            ShareSheet(items: [$0.text])
        }
        .confirmationDialog("إنهاء الرحلة الآمنة؟", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("وصلت بالسلامة، أنهِ الرحلة") {
                contact = safeTrip.state?.contact ?? contact
                Task {
                    await safeTrip.end()
                    if MessageComposer.canSend, !contact.isEmpty { sendArrival = true }
                }
            }
            Button("تراجع", role: .cancel) {}
        } message: {
            Text("تظهر في صفحة المتابعة أنك وصلت، ويتوقف تحديث الموقع.")
        }
    }

    private var setupSection: some View {
        Group {
            Section {
                Text("قبل أن تدخل منطقة بلا شبكة: ترسل رابط متابعة لشخص تثق به. كلما التقط جوالك الإنترنت ولو لثوانٍ، يتحدث آخر موقع لك في الرابط. وإذا مرت المدة التي تحددها دون تحديث، تظهر له صفحة المتابعة تنبيهًا واضحًا مع آخر موقع معروف.")
                    .font(.callout)
            }
            Section("البيانات") {
                TextField("اسمك كما يظهر في الصفحة (اختياري)", text: $name)
                TextField("رقم جوال جهة الاتصال", text: $contact)
                    .keyboardType(.phonePad)
                    .environment(\.layoutDirection, .leftToRight)
                Picker("التنبيه إذا لم يتحدث موقعي خلال", selection: $hours) {
                    ForEach([2, 3, 6, 9, 12, 24, 48], id: \.self) { Text("\($0) ساعات").tag($0) }
                }
            }
            Section {
                Button {
                    safeTrip.start(name: name, contact: contact, hours: hours, location: location.location)
                    if MessageComposer.canSend { composing = true } else { shareText = safeTrip.message }
                } label: {
                    Label("ابدأ الرحلة الآمنة وأرسل الرابط", systemImage: "shield.lefthalf.filled")
                }
                .disabled(location.location == nil)
                if !network.isOnline {
                    Text("أنت الآن دون إنترنت: يمكنك البدء، وسيُرفع الموقع ويعمل الرابط عند أول اتصال.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("لا يرسل التطبيق رسائل بنفسه؛ ترسل الرابط أنت مرة واحدة قبل الانطلاق. يُرفع آخر موقع فقط، ولا يراه إلا من معه الرابط.")
            }
        }
    }

    @ViewBuilder
    private func activeSection(_ s: SafeTripManager.State) -> some View {
        Section("الحالة") {
            LabeledContent("بدأت", value: Fmt.dateTime.string(from: s.startedAt))
            if let t = s.lastUploadAt {
                LabeledContent("آخر تحديث للموقع", value: Fmt.dateTime.string(from: t))
            } else {
                LabeledContent("آخر تحديث للموقع", value: "بانتظار الاتصال")
            }
            LabeledContent("مدة التنبيه", value: "\(s.hours) ساعات دون تحديث")
            if !s.contact.isEmpty {
                LabeledContent("جهة الاتصال", value: s.contact).environment(\.layoutDirection, .leftToRight)
            }
            if let e = safeTrip.lastError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        }
        Section {
            Button { Task { await safeTrip.upload(force: true) } } label: {
                Label(safeTrip.isUploading ? "جارٍ التحديث…" : "تحديث موقعي الآن", systemImage: "arrow.clockwise")
            }
            .disabled(!network.isOnline || safeTrip.isUploading)
            Button { if MessageComposer.canSend { composing = true } else { shareText = safeTrip.message } } label: {
                Label("إعادة إرسال الرابط", systemImage: "message")
            }
            if let link = safeTrip.link {
                ShareLink(item: link) { Label("مشاركة الرابط", systemImage: "square.and.arrow.up") }
                Link(destination: link) { Label("فتح صفحة المتابعة", systemImage: "safari") }
            }
        }
        Section {
            Button(role: .destructive) { confirmEnd = true } label: {
                Label("وصلت بالسلامة، أنهِ الرحلة", systemImage: "checkmark.shield")
            }
        }
    }
}

// MARK: - الطوارئ وإنجاد

/// أرقام الطوارئ وفريق إنجاد للبحث والإنقاذ، مع إرسال الموقع.
/// المصدر: حساب الجمعية الرسمي في X ‏(@enjad911) وصفحة تطبيقها في App Store.
enum EmergencyContacts {
    static let unified = "911"
    static let enjadUnified = "920018911"
    static let enjadMobile = "0507911999"
    static let enjadWhatsApp = "966507911999"
    static let enjadX = URL(string: "https://x.com/enjad911")!
}

struct EmergencyView: View {
    @EnvironmentObject private var location: LocationManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(SettingsKeys.emergencyNumber) private var emergencyNumber = ""
    @State private var smsTo: String?

    private var locationText: String {
        if let l = location.location { return LocationMessage.text(for: l) }
        if let last = location.lastKnownCoordinate {
            return "آخر موقع معروف لي: " + CoordinateUtilities.shareString(last.0)
        }
        return "لم يتحدد موقعي بعد."
    }

    var body: some View {
        List {
            Section {
                callRow(title: "الطوارئ الموحد", number: EmergencyContacts.unified, icon: "phone.fill", tint: .red)
            } footer: {
                Text("رقم الطوارئ الموحد في المملكة.")
            }

            Section {
                callRow(title: "الرقم الموحد", number: EmergencyContacts.enjadUnified, icon: "phone.fill", tint: Theme.desertOrange)
                callRow(title: "الجوال", number: EmergencyContacts.enjadMobile, icon: "phone", tint: Theme.desertOrange)
                Button {
                    smsTo = EmergencyContacts.enjadMobile
                } label: {
                    Label("إرسال موقعي برسالة نصية", systemImage: "message.fill")
                }
                Button {
                    let text = locationText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://wa.me/\(EmergencyContacts.enjadWhatsApp)?text=\(text)") { openURL(url) }
                } label: {
                    Label("إرسال موقعي عبر واتساب", systemImage: "bubble.left.and.text.bubble.right")
                }
                Link(destination: EmergencyContacts.enjadX) {
                    Label("حساب الفريق في X ‏(@enjad911)", systemImage: "link")
                }
            } header: {
                Text("فريق إنجاد للبحث والإنقاذ")
            } footer: {
                Text("جمعية تطوعية تبحث عن التائهين في البر وتساعد العالقين. الرسالة النصية تصل بإشارة الجوال دون إنترنت، أما واتساب فيحتاج إنترنت.")
            }

            Section {
                if emergencyNumber.isEmpty {
                    Text("لم تحدد رقمًا بعد. يمكنك تحديده من الإعدادات.").foregroundStyle(.secondary)
                } else {
                    callRow(title: "اتصال", number: emergencyNumber, icon: "phone", tint: Theme.brown)
                    Button { smsTo = emergencyNumber } label: { Label("إرسال موقعي برسالة نصية", systemImage: "message") }
                }
            } header: { Text("رقمي للطوارئ") }

            Section("موقعي الحالي") {
                Text(locationText).font(.footnote).textSelection(.enabled)
            }
        }
        .navigationTitle("الطوارئ والمساعدة")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        .sheet(item: Binding(get: { smsTo.map { ShareText(text: $0) } }, set: { smsTo = $0?.text })) { to in
            if MessageComposer.canSend {
                MessageComposer(recipients: [to.text], body: locationText).ignoresSafeArea()
            } else {
                ShareSheet(items: [locationText])
            }
        }
    }

    private func callRow(title: String, number: String, icon: String, tint: Color) -> some View {
        Button {
            if let url = URL(string: "tel://\(number)") { openURL(url) }
        } label: {
            HStack {
                Label(title, systemImage: icon).foregroundStyle(tint)
                Spacer()
                Text(number).font(.body.monospacedDigit()).foregroundStyle(.primary)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }
}

// MARK: - تغطية الشبكة

struct CoverageSettingsSection: View {
    @EnvironmentObject private var coverage: CoverageService
    @AppStorage(SettingsKeys.coverageCarrier) private var carrierRaw = ""
    @AppStorage(SettingsKeys.coverageContribute) private var contribute = false

    var body: some View {
        Section {
            Picker("شركة الاتصال في جوالي", selection: $carrierRaw) {
                Text("لم تُحدد").tag("")
                ForEach(Carrier.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("المساهمة في خريطة التغطية", isOn: $contribute)
                .disabled(carrierRaw.isEmpty)
            if coverage.pendingCount > 0 {
                LabeledContent("قياسات بانتظار الرفع", value: "\(coverage.pendingCount)")
            }
            NavigationLink { CarrierCoverageLinksView() } label: {
                Label("خرائط التغطية الرسمية للشركات", systemImage: "map")
            }
        } header: {
            Text("تغطية الشبكة")
        } footer: {
            Text("عند التفعيل يسجل التطبيق أثناء استخدامه: هل توجد شبكة، وهل فيها إنترنت، ونوعها (5G أو 4G أو 3G)، ضمن مربع تقريبي بطول 550 م تقريبًا، ثم يرفعها دون اسمك أو مسارك. Apple لا تتيح للتطبيقات معرفة اسم الشركة أو قوة الإشارة، لذلك تختار شركتك هنا.")
        }
    }
}

struct CarrierCoverageLinksView: View {
    var body: some View {
        List {
            Section {
                ForEach(Carrier.allCases.filter { $0.coverageURL != nil }) { c in
                    if let url = c.coverageURL {
                        Link(destination: url) { Label("خريطة تغطية \(c.title)", systemImage: "antenna.radiowaves.left.and.right") }
                    }
                }
            } footer: {
                Text("تغطية متوقعة تنشرها كل شركة على موقعها، وقد تختلف عن الواقع في البر.")
            }
            Section {
                Link(destination: Carrier.regulatorURL) { Label("خرائط التغطية من هيئة الاتصالات والفضاء والتقنية", systemImage: "building.columns") }
            } footer: {
                Text("خدمة رسمية تعرض تغطية الشبكات حسب العنوان أو الموقع.")
            }
        }
        .navigationTitle("خرائط التغطية الرسمية")
    }
}

/// شرح ألوان طبقة التغطية أسفل الخريطة.
struct CoverageLegend: View {
    var note: String?
    var body: some View {
        HStack(spacing: 10) {
            ForEach(CoverageLevel.allCases, id: \.self) { l in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(l.color.opacity(0.7)).frame(width: 12, height: 12)
                    Text(l.title).font(.caption2)
                }
            }
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
    }
}
