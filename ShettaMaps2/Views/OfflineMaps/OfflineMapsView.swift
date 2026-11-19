import SwiftUI
import UniformTypeIdentifiers
import CoreLocation

/// إدارة الخرائط المحفوظة دون إنترنت: تنزيل منطقة، متابعة التقدم، الإيقاف، الحذف، واستيراد MBTiles.
struct OfflineMapsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var offline: OfflineMapManager
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var dirt: DirtRoadsStore
    @ObservedObject private var package = OfflinePackageService.shared
    @ObservedObject private var regionPacks = RegionPackService.shared
    @State private var confirmRegionDelete: RegionPack?
    @AppStorage("offlineInclude_dirt") private var includeDirt = true
    @AppStorage("offlineInclude_speed") private var includeSpeed = true
    @AppStorage("offlineInclude_community") private var includeCommunity = true
    @AppStorage("offlineInclude_coverage") private var includeCoverage = true

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

            readyRegionsSection

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
                            // الخريطة ثم كل الطبقات المختارة للمنطقة نفسها لتعمل معًا دون إنترنت
                            regionName = ""
                            try await OfflinePackageService.shared.downloadRegion(name: name, sw: b.sw, ne: b.ne,
                                                                                  minZoom: Int(minZoom), maxZoom: Int(maxZoom))
                        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Label("تنزيل المنطقة الظاهرة على الخريطة", systemImage: "arrow.down.circle.fill")
                        if isStarting { Spacer(); ProgressView() }
                    }
                }
                .disabled(mapManager.visibleBounds == nil || !network.isOnline || offline.isUsingImportedFile || isStarting)
                if let status = package.layersStatus {
                    HStack { ProgressView(); Text(status + "…").font(.footnote).foregroundStyle(.secondary) }
                }
            } header: { Text("تنزيل منطقة") } footer: {
                Text("حرّك الخريطة الرئيسية إلى المنطقة المطلوبة قبل فتح هذه الشاشة. يُفضّل التنزيل عبر Wi-Fi، وتحقق من أن ترخيص مزوّد الخرائط يسمح بالتنزيل.")
            }

            Section {
                Toggle(isOn: $includeDirt) { Label(OfflineLayerOption.dirt.title, systemImage: OfflineLayerOption.dirt.icon) }
                Toggle(isOn: $includeSpeed) { Label(OfflineLayerOption.speed.title, systemImage: OfflineLayerOption.speed.icon) }
                Toggle(isOn: $includeCommunity) { Label(OfflineLayerOption.community.title, systemImage: OfflineLayerOption.community.icon) }
                Toggle(isOn: $includeCoverage) { Label(OfflineLayerOption.coverage.title, systemImage: OfflineLayerOption.coverage.icon) }
            } header: { Text("يُنزَّل مع كل خريطة") } footer: {
                Text("تُنزَّل هذه الطبقات تلقائيًا مع أي منطقة تحفظها ومع أي ملف خرائط تستورده (مثل صور الأقمار الصناعية)، حتى تعمل كلها معًا دون إنترنت. أسماء الأماكن ومحطات الوقود والغيران مضمنة في التطبيق أصلًا.")
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

            Section {
                if let b = mapManager.visibleBounds {
                    Button {
                        Task { await dirt.download(sw: b.sw, ne: b.ne) }
                    } label: {
                        HStack {
                            Label("تنزيل ردميات المنطقة الظاهرة", systemImage: "road.lanes")
                            if !dirt.downloading.isEmpty { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!network.isOnline || !dirt.downloading.isEmpty)
                }
                ForEach(dirt.installed.sorted(), id: \.self) { key in
                    HStack {
                        Text("منطقة \(key.replacingOccurrences(of: "_", with: "°، "))°").font(.subheadline)
                        Spacer()
                        Button(role: .destructive) { dirt.delete(key: key) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                if !dirt.installed.isEmpty {
                    LabeledContent("المساحة", value: Fmt.bytes(dirt.installedBytes))
                }
                if let e = dirt.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            } header: { Text("الردميات والطرق الترابية") } footer: {
                Text("تُنزَّل تلقائيًا أثناء تصفح الخريطة عند توفر الإنترنت، وتُنزَّل مع أي منطقة تحفظها لتعمل دون إنترنت. المصادر: © OpenStreetMap contributors، وطرق رصدتها Microsoft من صور الأقمار الصناعية (Microsoft Road Detections) وتظهر بلون برتقالي منقّط لأنها غير مؤكدة.")
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
                    .contextMenu {
                        Button { downloadLayers(for: t) } label: { Label("تنزيل الطبقات لمنطقة هذا الملف", systemImage: "square.3.layers.3d.down.right") }
                            .disabled(!network.isOnline)
                    }
                }
                Button { importing = true } label: { Label("استيراد ملف MBTiles", systemImage: "square.and.arrow.down") }
            } header: { Text("ملفات خرائط محلية") } footer: {
                Text("يدعم ملفات MBTiles النقطية (PNG/JPG)، ومنها صور الأقمار الصناعية. اختر ملفًا لجعله مصدر طبقة «دون إنترنت»، وتُنزَّل الردميات والطبقات لمنطقته تلقائيًا عند الاستيراد (أو اضغط مطولًا على الملف). صور الأقمار الصناعية من Apple لا يُسمح بتنزيلها، فتعمل بالإنترنت فقط. تأكد من امتلاكك حق استخدام بيانات الملف دون اتصال.")
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
                do {
                    try offline.importMBTiles(from: url)
                    if let t = offline.tilesets.last { downloadLayers(for: t) }
                } catch {
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

    /// الطبقات المرافقة لمنطقة ملف خرائط مستورد.
    private func downloadLayers(for t: LocalTileset) {
        guard network.isOnline else { return }
        let sw = CLLocationCoordinate2D(latitude: t.swLat, longitude: t.swLon)
        let ne = CLLocationCoordinate2D(latitude: t.neLat, longitude: t.neLon)
        Task { await OfflinePackageService.shared.downloadLayers(sw: sw, ne: ne) }
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


// MARK: - المناطق الجاهزة

extension OfflineMapsView {
    @ViewBuilder
    var readyRegionsSection: some View {
        Section {
            if let m = regionPacks.manifest {
                ForEach(m.regions) { p in regionRow(p) }
                LabeledContent("المساحة الفارغة في جهازك", value: ByteCountFormatter.string(fromByteCount: regionPacks.freeBytes, countStyle: .file))
                    .font(.footnote)
            } else if regionPacks.loadingManifest {
                HStack { ProgressView(); Text("جارٍ تحميل قائمة المناطق").foregroundStyle(.secondary) }
            } else if regionPacks.manifestFailed {
                Button("إعادة المحاولة") { Task { await regionPacks.loadManifest() } }
                Text("تعذّر تحميل قائمة المناطق، تحقق من الاتصال.").font(.footnote).foregroundStyle(.secondary)
            }
            if let e = regionPacks.lastError {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("مناطق جاهزة للتنزيل")
        } footer: {
            Text("تنزّل المنطقة مرة واحدة وتعمل كاملة دون إنترنت: الطرق والأسماء والتضاريس، ومعها الطبقات المختارة بالأسفل (الردميات وحدود السرعة...). بيانات OpenStreetMap عبر OpenMapTiles.")
        }
        .task { if regionPacks.manifest == nil { await regionPacks.loadManifest() } }
        .confirmationDialog("حذف المنطقة؟", isPresented: Binding(get: { confirmRegionDelete != nil }, set: { if !$0 { confirmRegionDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmRegionDelete) { p in
            Button("حذف \(p.title)", role: .destructive) { regionPacks.delete(p) }
            Button("إلغاء", role: .cancel) {}
        } message: { p in
            Text("يُحذف ملف الخريطة من جهازك ويمكن تنزيله مرة أخرى لاحقًا.")
        }
    }

    private func regionRow(_ p: RegionPack) -> some View {
        HStack(spacing: DS.m) {
            Image(systemName: p.id == "saudi" ? "map.fill" : "map")
                .font(DS.iconFont).foregroundStyle(Theme.desertOrange).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.body.weight(.semibold))
                Text(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)
                     + (regionPacks.isInstalled(p) ? (regionPacks.hasUpdate(p) ? " · يتوفر تحديث" : " · منزّلة") : ""))
                    .font(.caption).foregroundStyle(regionPacks.isInstalled(p) ? Color.green : .secondary)
                if let f = regionPacks.progress[p.id] {
                    ProgressView(value: f).tint(Theme.desertOrange)
                    Text("\(Int(f * 100))٪").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if regionPacks.progress[p.id] != nil {
                Button("إيقاف") { regionPacks.cancel(p) }.buttonStyle(.bordered)
            } else if regionPacks.isInstalled(p) {
                Menu {
                    if let t = offline.regionTileset(id: p.id) {
                        Button { offline.selectedTilesetID = t.id; mapManager.layer = .offline } label: {
                            Label("استخدامها الآن", systemImage: "checkmark.circle")
                        }
                    }
                    if regionPacks.hasUpdate(p) {
                        Button { regionPacks.download(p) } label: { Label("تحديث", systemImage: "arrow.clockwise") }
                    }
                    Button(role: .destructive) { confirmRegionDelete = p } label: { Label("حذف", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            } else {
                Button { regionPacks.download(p) } label: {
                    Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Theme.desertOrange)
                }
                .buttonStyle(.plain)
                .disabled(!network.isOnline)
                .accessibilityLabel("تنزيل \(p.title)")
            }
        }
        .padding(.vertical, 2)
    }
}
