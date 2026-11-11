import SwiftUI
import CoreLocation

/// إدخال الإحداثيات يدويًا بصيغ متعددة مع التحقق والتحويل الفوري.
struct CoordinateInputView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var vm = CoordinateInputViewModel()

    var body: some View {
        Form {
            Section {
                Picker("طريقة الإدخال", selection: Binding(get: { vm.mode }, set: { vm.switchMode($0) })) {
                    ForEach(CoordinateInputViewModel.InputMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if vm.mode == .freeText {
                Section {
                    TextField("24.7136, 46.6753", text: $vm.text, axis: .vertical)
                        .font(.body.monospaced())
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .environment(\.layoutDirection, .leftToRight)
                    Button { if let s = UIPasteboard.general.string { vm.text = s } } label: {
                        Label("لصق من الحافظة", systemImage: "doc.on.clipboard")
                    }
                } header: { Text("الإحداثيات") } footer: {
                    Text("أمثلة مقبولة: 24.7136, 46.6753 — أو 24°42'49\"N 46°40'31\"E — أو 24 42.816 ش 46 40.518 ق. تُقبل الأرقام العربية.")
                }
            } else {
                Section("خط العرض") { dmsRow(deg: $vm.latDeg, min: $vm.latMin, sec: $vm.latSec, positive: $vm.latNorth, pos: "شمال", neg: "جنوب") }
                Section("خط الطول") { dmsRow(deg: $vm.lonDeg, min: $vm.lonMin, sec: $vm.lonSec, positive: $vm.lonEast, pos: "شرق", neg: "غرب") }
            }

            if let err = vm.errorMessage {
                Section { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }

            if let c = vm.coordinate {
                Section("التحويل") {
                    ForEach(CoordinateFormat.allCases) { f in
                        LabeledContent(f.title) {
                            Text(CoordinateUtilities.format(c, as: f))
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .environment(\.layoutDirection, .leftToRight)
                        }
                    }
                }
                if let here = location.location?.coordinate {
                    Section("من موقعك الحالي") {
                        LabeledContent("المسافة المباشرة", value: Fmt.distance(GeoMath.distance(here, c)))
                        LabeledContent("الاتجاه", value: Fmt.bearing(GeoMath.bearing(from: here, to: c)))
                    }
                }
                Section {
                    Button { mapManager.send(.focus(c, spanMeters: 3000)); mapManager.pickedCoordinate = nil; dismiss(); router.showOnMap() } label: {
                        Label("انتقل إلى النقطة على الخريطة", systemImage: "map")
                    }
                    Button { navigation.navigate(to: Waypoint(name: "إحداثيات مدخلة", coordinate: c)); dismiss(); router.showOnMap() } label: {
                        Label("ابدأ الملاحة إليها", systemImage: "location.north.line.fill")
                    }
                    Button {
                        router.plannerDraft.waypoints.append(Waypoint(name: "نقطة \(router.plannerDraft.waypoints.count + 1)", coordinate: c))
                        router.mapSheet = .routePlanner
                    } label: { Label("إضافة إلى مخطط المسار", systemImage: "point.3.connected.trianglepath.dotted") }
                    Button { router.mapSheet = .savePlace(c) } label: { Label("حفظ كموقع", systemImage: "mappin.and.ellipse") }
                    Button { UIPasteboard.general.string = CoordinateUtilities.shareString(c) } label: { Label("نسخ", systemImage: "doc.on.doc") }
                }
            }

            if let here = location.location?.coordinate {
                Section {
                    Button { vm.switchMode(.freeText); vm.text = CoordinateUtilities.shareString(here) } label: {
                        Label("استخدم موقعي الحالي", systemImage: "location")
                    }
                }
            }
        }
        .navigationTitle("إدخال الإحداثيات")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
    }

    private func dmsRow(deg: Binding<String>, min: Binding<String>, sec: Binding<String>, positive: Binding<Bool>, pos: String, neg: String) -> some View {
        VStack {
            HStack {
                field("درجة", deg)
                field("دقيقة", min)
                field("ثانية", sec)
            }
            Picker("", selection: positive) {
                Text(pos).tag(true)
                Text(neg).tag(false)
            }
            .pickerStyle(.segmented)
        }
    }

    private func field(_ title: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", text: binding)
                .keyboardType(.decimalPad)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
        }
    }
}
