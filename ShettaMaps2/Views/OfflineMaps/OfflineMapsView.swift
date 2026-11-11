import SwiftUI
import UniformTypeIdentifiers

/// إدارة الخرائط المحفوظة دون إنترنت: تنزيل منطقة، متابعة التقدم، الإيقاف، الحذف، واستيراد MBTiles.
struct OfflineMapsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var offline: OfflineMapManager
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter

    @State private var regionName = ""
    @State private var minZoom = 6.0
    @State private var maxZoom = 13.0
    @State private var error: String?
    @State private var importing = false
    @State private var confirmDelete: OfflineRegionItem?
    @State private var confirmDeleteAll = false
    @State private var isStarting = false

    private var estimate: Int? {
        guard let b = mapManager.visibleBounds else { return nil }
        return GeoMath.estimatedTileCount(sw: b.sw, ne: b.ne, minZoom: Int(minZoom), maxZoom: Int(maxZoom))
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text(offline.isUsingDefaultStyle
                         ? "المصدر الحالي: OpenFreeMap (بيانات OpenStreetMap). يسمح بتنزيل حتى 3000 مربع لكل منطقة، فاختر منطقة متوسطة الحجم أو قلّل أعلى مستوى تكبير."
                         : "المصدر الحالي: \(offline.selectedTilesetID != nil ? "ملف محلي" : offline.styleURLString)")
                        .font(.footnote)
                } icon: { Image(systemName: "info.circle") }
                NavigationLink("إعدادات مصدر الخرائط") { MapSourceSettingsView() }
            }

            Section {
                TextField("اسم المنطقة (مثال: نفود الدهناء)", text: $regionName)
                VStack(alignment: .leading) {
                    Text("من مستوى تكبير \(Int(minZoom)) إلى \(Int(maxZoom))").font(.subheadline)
                    Slider(value: $minZoom, in: 0...16, step: 1) { Text("أدنى") }
                        .onChange(of: minZoom) { _, v in if v > maxZoom { maxZoom = v } }
                    Slider(value: $maxZoom, in: 0...17, step: 1) { Text("أعلى") }
                        .onChange(of: maxZoom) { _, v in if v < minZoom { minZoom = v } }
                }
                if let estimate {
                    LabeledContent("تقدير عدد المربعات", value: "\(estimate)")
                    if estimate > offline.maxTilesPerRegion {
                        Text("المنطقة كبيرة جدًا؛ صغّر الخريطة أو خفّض أعلى مستوى تكبير.").font(.caption).foregroundStyle(.red)
                    }
                }
                Button {
                    guard let b = mapManager.visibleBounds, !isStarting else { return }
                    isStarting = true
                    let name = regionName
                    Task {
                        defer { isStarting = false }
                        do {
                            try await offline.download(name: name, sw: b.sw, ne: b.ne, minZoom: Int(minZoom), maxZoom: Int(maxZoom))
                            regionName = ""
                        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Label("تنزيل المنطقة الظاهرة على الخريطة", systemImage: "arrow.down.circle.fill")
                        if isStarting { Spacer(); ProgressView() }
                    }
                }
                .disabled(mapManager.visibleBounds == nil || !network.isOnline || offline.selectedTilesetID != nil || isStarting)
            } header: { Text("تنزيل منطقة") } footer: {
                Text("حرّك الخريطة الرئيسية إلى المنطقة المطلوبة قبل فتح هذه الشاشة. يُفضّل التنزيل عبر Wi-Fi، وتحقق من أن ترخيص مزوّد الخرائط يسمح بالتنزيل.")
            }

            Section("المناطق المنزلة") {
                if offline.regions.isEmpty { Text("لا توجد مناطق منزلة").foregroundStyle(.secondary) }
                ForEach(offline.regions) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text(r.name).font(.body.weight(.semibold))
                            Spacer()
                            Text(stateTitle(r.state)).font(.caption).foregroundStyle(stateColor(r.state))
                            if r.state != .complete {
                                Button { offline.toggle(r) } label: {
                                    Image(systemName: r.state == .downloading ? "pause.circle" : "play.circle")
                                        .font(.title2)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(r.state == .downloading ? "إيقاف التنزيل" : "استئناف التنزيل")
                            }
                            Button(role: .destructive) { confirmDelete = r } label: {
                                Image(systemName: "trash").font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .tint(.red)
                            .accessibilityLabel("حذف المنطقة")
                        }
                        ProgressView(value: r.fraction)
                        HStack {
                            Text("\(Int(r.fraction * 100))٪ · \(Fmt.bytes(Int64(r.bytes)))")
                            Spacer()
                            Text("تكبير \(Int(r.minZoom))–\(Int(r.maxZoom))")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { confirmDelete = r } label: { Label("حذف", systemImage: "trash") }
                        if r.state != .complete {
                            Button { offline.toggle(r) } label: {
                                Label(r.state == .downloading ? "إيقاف" : "استئناف", systemImage: r.state == .downloading ? "pause" : "play")
                            }
                        }
                    }
                    .contextMenu {
                        Button("عرض على الخريطة") {
                            mapManager.layer = .offline
                            mapManager.send(.fit([r.sw, r.ne]))
                            dismiss(); router.showOnMap()
                        }
                    }
                }
                if offline.totalDownloadedBytes > 0 {
                    LabeledContent("المساحة المستخدمة", value: Fmt.bytes(Int64(offline.totalDownloadedBytes)))
                }
                if offline.regions.count > 1 {
                    Button("حذف كل المناطق", role: .destructive) { confirmDeleteAll = true }
                }
            }

            if let err = offline.lastError {
                Section {
                    Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    Button("إخفاء") { offline.clearError() }
                }
            }

            Section {
                ForEach(offline.tilesets) { t in
                    Button {
                        offline.selectedTilesetID = offline.selectedTilesetID == t.id ? nil : t.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(t.name).foregroundStyle(.primary)
                                Text("\(t.format.uppercased()) · تكبير \(t.minZoom)–\(t.maxZoom)").font(.caption).foregroundStyle(.secondary)
                                if !t.attribution.isEmpty { Text(t.attribution).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if offline.selectedTilesetID == t.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.desertOrange) }
                        }
                    }
                    .swipeActions { Button(role: .destructive) { offline.deleteTileset(t) } label: { Label("حذف", systemImage: "trash") } }
                }
                Button { importing = true } label: { Label("استيراد ملف MBTiles", systemImage: "square.and.arrow.down") }
            } header: { Text("ملفات خرائط محلية") } footer: {
                Text("يدعم ملفات MBTiles النقطية (PNG/JPG). اختر ملفًا لجعله مصدر طبقة «دون إنترنت». تأكد من امتلاكك حق استخدام البيانات دون اتصال.")
            }
        }
        .navigationTitle("الخرائط المحفوظة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if router.mapSheet != nil {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
        }
        .onAppear { offline.refreshRegions() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.mbtiles, .data]) { result in
            if case .success(let url) = result {
                do { try offline.importMBTiles(from: url) } catch {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .alert("تنبيه", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("حذف المنطقة؟", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) { if let r = confirmDelete { offline.delete(r) }; confirmDelete = nil }
        }
        .confirmationDialog("حذف كل المناطق المنزلة؟", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("حذف الكل", role: .destructive) { offline.deleteAll() }
        }
    }

    private func stateTitle(_ s: OfflineRegionItem.State) -> String {
        switch s {
        case .downloading: return "جارٍ التنزيل"
        case .paused: return "متوقف"
        case .interrupted: return "متوقف — اضغط للاستئناف"
        case .complete: return "مكتمل"
        case .invalid: return "غير صالح"
        case .unknown: return "جارٍ القراءة"
        }
    }

    private func stateColor(_ s: OfflineRegionItem.State) -> Color {
        switch s {
        case .complete: return .green
        case .downloading: return Theme.desertOrange
        case .invalid: return .red
        default: return .secondary
        }
    }
}

/// إعداد مصدر خرائط MapLibre (رابط نمط style.json).
struct MapSourceSettingsView: View {
    @AppStorage(SettingsKeys.offlineStyleURL) private var styleURL = ""
    @EnvironmentObject private var offline: OfflineMapManager

    var body: some View {
        Form {
            Section {
                TextField(OfflineMapManager.defaultStyleURL, text: $styleURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                Button("استعادة المصدر الافتراضي (OpenFreeMap)") { styleURL = "" }
            } header: { Text("رابط نمط الخريطة (style.json)") } footer: {
                Text("ضع رابط نمط من خادم مربعات خاص بك أو من مزوّد تجاري يسمح ترخيصه بالتخزين دون اتصال (قد يحتاج مفتاح API ضمن الرابط). لا تستخدم خوادم OpenStreetMap العامة للتنزيل الجماعي لأن سياستها تمنع ذلك.")
            }
            Section("ملاحظات الترخيص") {
                Text("بيانات OpenStreetMap متاحة بموجب رخصة ODbL وتتطلب ذكر المصدر «© OpenStreetMap contributors». يعرض المحرك نص الإسناد تلقائيًا من النمط.")
                    .font(.footnote)
                Text("صور الأقمار الصناعية في طبقة MapKit متاحة عبر الإنترنت فقط، ولا يُسمح بتنزيلها للاستخدام دون اتصال. لصور أقمار صناعية دون اتصال تحتاج إلى مزوّد يمنح هذا الحق صراحةً.")
                    .font(.footnote)
            }
        }
        .navigationTitle("مصدر الخرائط")
        .onDisappear { offline.objectWillChange.send() }
    }
}
