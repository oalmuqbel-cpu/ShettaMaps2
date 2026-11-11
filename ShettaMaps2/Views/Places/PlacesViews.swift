import SwiftUI
import SwiftData
import CoreLocation

/// قائمة المواقع المحفوظة مع البحث والتصفية حسب التصنيف.
struct PlacesListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \SavedPlace.createdAt, order: .reverse) private var places: [SavedPlace]
    @Query(sort: \PlaceCategory.sortOrder) private var categories: [PlaceCategory]

    @State private var query = ""
    @State private var categoryFilter: UUID?
    @State private var exportURL: URL?
    @State private var showCategories = false

    private var filtered: [SavedPlace] {
        let key = SearchService.searchKey(query)
        return places.filter { p in
            (categoryFilter == nil || p.category?.id == categoryFilter)
                && (key.isEmpty || SearchService.searchKey(p.name).contains(key) || SearchService.searchKey(p.notes).contains(key))
        }
    }

    var body: some View {
        List {
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        FilterChip(title: "الكل", icon: "square.grid.2x2", selected: categoryFilter == nil) { categoryFilter = nil }
                        ForEach(categories) { c in
                            FilterChip(title: c.name, icon: c.iconName, selected: categoryFilter == c.id) { categoryFilter = c.id }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            if filtered.isEmpty {
                ContentUnavailableView("لا توجد مواقع", systemImage: "mappin.slash",
                                       description: Text("احفظ موقعك الحالي من الخريطة أو حدد نقطة عليها."))
            }
            ForEach(filtered) { place in
                NavigationLink {
                    PlaceDetailView(place: place)
                } label: {
                    PlaceRow(place: place, current: location.location?.coordinate)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { delete(place) } label: { Label("حذف", systemImage: "trash") }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        mapManager.send(.focus(place.coordinate, spanMeters: 2000))
                        router.showOnMap()
                    } label: { Label("على الخريطة", systemImage: "map") }
                    .tint(Theme.desertOrange)
                }
            }
        }
        .searchable(text: $query, prompt: "ابحث في المواقع")
        .navigationTitle("المواقع المحفوظة")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    if let c = location.location?.coordinate {
                        Button { router.mapSheet = .savePlace(c); router.showOnMap() } label: {
                            Label("حفظ موقعي الحالي", systemImage: "location")
                        }
                    }
                    Button { showCategories = true } label: { Label("إدارة التصنيفات", systemImage: "tag") }
                    Button { exportAll() } label: { Label("تصدير المواقع GPX", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showCategories) { NavigationStack { CategoriesView() } }
        .sheet(item: Binding(get: { exportURL.map(ShareItem.init) }, set: { exportURL = $0?.url })) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func delete(_ place: SavedPlace) {
        context.delete(place)
        try? context.save()
    }

    private func exportAll() {
        let points = filtered.map { GPXDocument.Point(name: $0.name, lat: $0.latitude, lon: $0.longitude,
                                                       elevation: $0.altitude, notes: $0.notes) }
        let xml = GPXService.export(waypoints: points, name: "مواقع سَمْت")
        exportURL = try? GPXService.writeTemporaryFile(xml, baseName: "ShettaMaps2-Places")
    }
}

struct PlaceRow: View {
    let place: SavedPlace
    let current: CLLocationCoordinate2D?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.category?.iconName ?? "mappin")
                .foregroundStyle(Color(hex: place.category?.colorHex ?? "D9822B"))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.sand))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(place.name).font(.body.weight(.semibold))
                    if place.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                }
                Text(CoordinateUtilities.format(place.coordinate, as: .decimal))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer()
            if let current {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.distance(GeoMath.distance(current, place.coordinate))).font(.caption.weight(.semibold))
                    Text(GeoMath.cardinalName(GeoMath.bearing(from: current, to: place.coordinate)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// تفاصيل الموقع: معلومات، ملاحة، مشاركة، تعديل.
struct PlaceDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @Bindable var place: SavedPlace
    @State private var editing = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section("الإحداثيات") {
                ForEach(CoordinateFormat.allCases) { f in
                    LabeledContent(f.title) {
                        Text(CoordinateUtilities.format(place.coordinate, as: f))
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                if let alt = place.altitude { LabeledContent("الارتفاع", value: Fmt.altitude(alt)) }
                if let acc = place.horizontalAccuracy { LabeledContent("دقة الحفظ", value: Fmt.accuracy(acc)) }
            }
            if let current = location.location?.coordinate {
                Section("من موقعك") {
                    LabeledContent("المسافة", value: Fmt.distance(GeoMath.distance(current, place.coordinate)))
                    LabeledContent("الاتجاه", value: Fmt.bearing(GeoMath.bearing(from: current, to: place.coordinate)))
                }
            }
            Section("معلومات") {
                LabeledContent("التصنيف", value: place.category?.name ?? "بدون تصنيف")
                LabeledContent("تاريخ الحفظ", value: Fmt.dateTime.string(from: place.createdAt))
                if !place.notes.isEmpty { Text(place.notes) }
            }
            Section {
                Button { navigation.navigate(to: place.asWaypoint); router.showOnMap() } label: {
                    Label("ابدأ الملاحة إلى هنا", systemImage: "location.north.line.fill")
                }
                Button { router.plannerDraft.waypoints.append(place.asWaypoint); router.mapSheet = .routePlanner; router.showOnMap() } label: {
                    Label("إضافة إلى مخطط المسار", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button { mapManager.send(.focus(place.coordinate, spanMeters: 2000)); router.showOnMap() } label: {
                    Label("عرض على الخريطة", systemImage: "map")
                }
                Button { place.isFavorite.toggle(); try? context.save() } label: {
                    Label(place.isFavorite ? "إزالة من المفضلة" : "إضافة إلى المفضلة", systemImage: "star")
                }
                Button { UIPasteboard.general.string = CoordinateUtilities.shareString(place.coordinate) } label: {
                    Label("نسخ الإحداثيات", systemImage: "doc.on.doc")
                }
                ShareLink(item: shareText) { Label("مشاركة كنص", systemImage: "square.and.arrow.up") }
                Button { exportGPX() } label: { Label("مشاركة كملف GPX", systemImage: "doc.badge.arrow.up") }
            }
            Section {
                Button("حذف الموقع", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(place.name)
        .toolbar { Button("تعديل") { editing = true } }
        .sheet(isPresented: $editing) { NavigationStack { PlaceEditorView(mode: .edit(place)) } }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        .confirmationDialog("حذف \(place.name)؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                context.delete(place); try? context.save(); dismiss()
            }
        }
    }

    private var shareText: String {
        let c = CoordinateUtilities.shareString(place.coordinate)
        return "\(place.name)\n\(c)\n\(CoordinateUtilities.format(place.coordinate, as: .dms))"
    }

    private func exportGPX() {
        let xml = GPXService.export(waypoints: [.init(name: place.name, lat: place.latitude, lon: place.longitude,
                                                      elevation: place.altitude, notes: place.notes)], name: place.name)
        shareURL = try? GPXService.writeTemporaryFile(xml, baseName: place.name)
    }
}

/// إنشاء أو تعديل موقع.
struct PlaceEditorView: View {
    enum Mode { case create(CLLocationCoordinate2D), edit(SavedPlace) }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var location: LocationManager
    @Query(sort: \PlaceCategory.sortOrder) private var categories: [PlaceCategory]

    let mode: Mode
    @State private var name = ""
    @State private var notes = ""
    @State private var categoryID: UUID?
    @State private var coordinateText = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("الاسم") {
                TextField("مثال: مخيم الوادي", text: $name)
            }
            Section("الإحداثيات") {
                TextField("خط العرض، خط الطول", text: $coordinateText)
                    .font(.body.monospaced())
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("التصنيف") {
                Picker("التصنيف", selection: $categoryID) {
                    Text("بدون تصنيف").tag(UUID?.none)
                    ForEach(categories) { c in Label(c.name, systemImage: c.iconName).tag(Optional(c.id)) }
                }
            }
            Section("ملاحظات") {
                TextField("وصف الطريق، حالة الأرض، تنبيهات…", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }
        }
        .navigationTitle(isEditing ? "تعديل الموقع" : "حفظ موقع")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("حفظ") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private var isEditing: Bool { if case .edit = mode { return true } else { return false } }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .create(let c):
            coordinateText = CoordinateUtilities.shareString(c)
            name = "موقع \(Fmt.dateTime.string(from: Date()))"
            categoryID = categories.first(where: { $0.name == "عام" })?.id
        case .edit(let p):
            name = p.name; notes = p.notes; categoryID = p.category?.id
            coordinateText = CoordinateUtilities.shareString(p.coordinate)
        }
    }

    private func save() {
        let coord: CLLocationCoordinate2D
        do { coord = try CoordinateUtilities.parse(coordinateText) } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "إحداثيات غير صالحة"
            return
        }
        let category = categories.first { $0.id == categoryID }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .create(let original):
            // إذا كانت النقطة هي الموقع الحالي نحفظ الارتفاع والدقة
            var alt: Double?, acc: Double?
            if let loc = location.location, GeoMath.distance(loc.coordinate, original) < 1, GeoMath.distance(coord, original) < 1 {
                alt = loc.verticalAccuracy >= 0 ? loc.altitude : nil
                acc = loc.horizontalAccuracy
            }
            let p = SavedPlace(name: trimmed, coordinate: coord, notes: notes, altitude: alt, horizontalAccuracy: acc, category: category)
            context.insert(p)
        case .edit(let p):
            p.name = trimmed; p.notes = notes; p.category = category
            p.coordinate = coord
            p.updatedAt = Date()
        }
        try? context.save()
        dismiss()
    }
}

/// إدارة التصنيفات.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \PlaceCategory.sortOrder) private var categories: [PlaceCategory]
    @State private var newName = ""
    @State private var newIcon = "mappin"

    private let icons = ["mappin", "tent", "mountain.2", "water.waves", "leaf", "drop", "fuelpump", "flag", "binoculars", "camera", "car", "exclamationmark.triangle"]

    var body: some View {
        List {
            Section("تصنيف جديد") {
                TextField("اسم التصنيف", text: $newName)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(icons, id: \.self) { i in
                            Image(systemName: i)
                                .frame(width: 40, height: 40)
                                .background(Circle().fill(newIcon == i ? Theme.desertOrange.opacity(0.3) : Theme.sand))
                                .onTapGesture { newIcon = i }
                                .accessibilityAddTraits(newIcon == i ? .isSelected : [])
                        }
                    }
                }
                Button("إضافة") {
                    let c = PlaceCategory(name: newName.trimmingCharacters(in: .whitespaces), iconName: newIcon,
                                          sortOrder: (categories.last?.sortOrder ?? 0) + 1)
                    context.insert(c); try? context.save(); newName = ""
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section("التصنيفات") {
                ForEach(categories) { c in
                    HStack {
                        Label(c.name, systemImage: c.iconName)
                        Spacer()
                        Text("\(c.places?.count ?? 0)").foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    idx.map { categories[$0] }.forEach { context.delete($0) }
                    try? context.save()
                }
            }
        }
        .navigationTitle("التصنيفات")
        .toolbar { Button("تم") { dismiss() } }
    }
}

struct FilterChip: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Theme.desertOrange : Theme.sand))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// غلاف لعرض ورقة المشاركة لملف.
struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
