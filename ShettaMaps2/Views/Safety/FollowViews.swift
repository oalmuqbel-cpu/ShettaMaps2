import SwiftUI
import CoreImage.CIFilterBuiltins

/// معرّفي في سَمْت: يعطيه المستخدم لمن يريد أن يضيفه متابعًا.
struct MyCodeSection: View {
    @EnvironmentObject private var follow: FollowService
    @State private var copied = false

    var body: some View {
        Section {
            if let code = follow.myCode {
                HStack {
                    Text(FollowService.pretty(code))
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "تم النسخ" : "نسخ") {
                        UIPasteboard.general.string = code
                        copied = true
                    }
                    .buttonStyle(.bordered)
                }
                if let qr = QRCode.image(for: "samt:\(code)") {
                    HStack {
                        Spacer()
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                        Spacer()
                    }
                }
                ShareLink(item: "معرّفي في تطبيق سَمْت: \(FollowService.pretty(code))\nأضفه في «الرحلة الآمنة» لتتابع رحلاتي البرية.") {
                    Label("مشاركة معرّفي", systemImage: "square.and.arrow.up")
                }
            } else {
                Button { Task { await follow.ensureMyCode() } } label: {
                    Label("إنشاء معرّفي", systemImage: "person.text.rectangle")
                }
                if let e = follow.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            }
        } header: {
            Text("معرّفي في سَمْت")
        } footer: {
            Text("أعطِ هذا المعرّف لمن تريد أن تتابع رحلاته: هو يضيفك بمعرّفك، فتظهر لك رحلاته في «أتابعهم».")
        }
        .task { await follow.ensureMyCode() }
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// إضافة شخص بمعرّفه.
struct AddContactView: View {
    @EnvironmentObject private var follow: FollowService
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var name = ""
    @State private var working = false

    var body: some View {
        Form {
            Section {
                TextField("المعرّف (8 خانات)", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .environment(\.layoutDirection, .leftToRight)
                TextField("الاسم (مثل: أخوي محمد)", text: $name)
            } footer: {
                Text("يجده الشخص في تطبيقه: الإعدادات ← الرحلة الآمنة ← معرّفي في سَمْت.")
            }
            if let e = follow.lastError {
                Section { Text(e).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                Button {
                    working = true
                    Task {
                        if await follow.addContact(code: code, name: name) { dismiss() }
                        working = false
                    }
                } label: {
                    if working { ProgressView() } else { Text("إضافة") }
                }
                .disabled(FollowService.normalize(code).count != 8 || working)
            }
        }
        .navigationTitle("إضافة شخص")
        .onAppear { follow.clearError() }
    }
}

/// اختيار المتابعين للرحلة الآمنة.
struct WatchersPicker: View {
    @EnvironmentObject private var follow: FollowService
    @Binding var selected: Set<String>

    var body: some View {
        if follow.contacts.isEmpty {
            Text("لم تضف أحدًا بعد.").foregroundStyle(.secondary)
        }
        ForEach(follow.contacts) { c in
            Button {
                if selected.contains(c.code) { selected.remove(c.code) } else if selected.count < 10 { selected.insert(c.code) }
            } label: {
                HStack {
                    Image(systemName: selected.contains(c.code) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(c.code) ? Theme.desertOrange : .secondary)
                    VStack(alignment: .leading) {
                        Text(c.name).foregroundStyle(.primary)
                        Text(FollowService.pretty(c.code)).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .swipeActions { Button("حذف", role: .destructive) { follow.removeContact(c); selected.remove(c.code) } }
        }
        NavigationLink { AddContactView() } label: { Label("إضافة شخص بمعرّفه", systemImage: "person.badge.plus") }
    }
}

/// رحلات من أضافوني متابعًا.
struct FollowingView: View {
    @EnvironmentObject private var follow: FollowService
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if follow.trips.isEmpty {
                Section {
                    Text("لا توجد رحلات حاليًا. عندما يضيفك أحد بمعرّفك في رحلته الآمنة، تظهر هنا ويصلك تنبيه إذا تأخر تحديث موقعه.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(follow.trips) { t in
                Section {
                    statusRow(t)
                    LabeledContent("آخر تحديث", value: Fmt.dateTime.string(from: t.updatedAt))
                    LabeledContent("منذ", value: Fmt.duration(Date().timeIntervalSince(t.updatedAt)))
                    Text(CoordinateUtilities.format(t.coordinate, as: .decimal)).font(.footnote.monospaced())
                        .environment(\.layoutDirection, .leftToRight).textSelection(.enabled)
                    if let here = location.location?.coordinate {
                        LabeledContent("المسافة والاتجاه", value: "\(Fmt.distance(GeoMath.distance(here, t.coordinate))) · \(Fmt.bearing(GeoMath.bearing(from: here, to: t.coordinate)))")
                    }
                    Button {
                        mapManager.send(.focus(t.coordinate, spanMeters: 6_000))
                        router.showOnMap()
                        dismiss()
                    } label: { Label("عرض على الخريطة", systemImage: "map") }
                    Button {
                        navigation.navigate(to: Waypoint(name: "آخر موقع: \(t.displayName)", coordinate: t.coordinate))
                        router.showOnMap()
                        dismiss()
                    } label: { Label("الملاحة إلى آخر موقع", systemImage: "location.north.line") }
                    if t.isLate {
                        Link(destination: URL(string: "tel://911")!) { Label("الطوارئ 911", systemImage: "phone.fill").foregroundStyle(.red) }
                        Link(destination: URL(string: "tel://\(EmergencyContacts.enjadUnified)")!) {
                            Label("فريق إنجاد للبحث والإنقاذ", systemImage: "phone")
                        }
                    }
                } header: { Text(t.displayName) }
            }
            Section {
                if let r = follow.lastRefresh { LabeledContent("آخر مزامنة", value: Fmt.time.string(from: r)) }
                if let e = follow.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("يتحدث القسم عند فتح التطبيق وفي الخلفية حسب ما يسمح به النظام. التنبيه عند التأخر مجدول على جوالك نفسه، فيصلك حتى دون إنترنت ما دام التطبيق اطلع على الرحلة مرة واحدة على الأقل.")
            }
        }
        .navigationTitle("أتابعهم")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        .refreshable { await follow.refresh() }
        .task { await follow.refresh() }
    }

    @ViewBuilder
    private func statusRow(_ t: FollowedTrip) -> some View {
        if !t.active {
            Label("وصل بالسلامة وأنهى الرحلة", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
        } else if t.isLate {
            Label("تأخر التحديث: تجاوز \(SafeTripManager.hoursText(t.hours)) دون تحديث", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Label("الرحلة جارية · التنبيه بعد \(SafeTripManager.hoursText(t.hours)) دون تحديث", systemImage: "shield.lefthalf.filled")
                .foregroundStyle(Theme.desertOrange)
        }
    }
}
