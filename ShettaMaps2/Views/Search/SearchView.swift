import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

/// البحث العربي عن الأماكن البرية: محليًا دون إنترنت (المحفوظات + قاعدة جغرافية مستوردة) أو عبر Apple Maps.
struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var search: SearchService
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var community: CommunityService
    @Query private var places: [SavedPlace]
    @State private var selectedCommunity: CommunityPlace?

    enum Scope: String, CaseIterable, Identifiable { case local, online; var id: String { rawValue } }

    @State private var query = ""
    @State private var kind: PlaceKind = .all
    @State private var scope: Scope = .local
    @State private var onlineResults: [SearchResult] = []
    @State private var onlineError: String?
    @State private var isSearching = false
    @State private var importing = false
    @State private var importMessage: String?

    private var localResults: [SearchResult] {
        let near = location.location?.coordinate
        var list = search.searchLocal(query, kind: kind, places: places, near: near)
        if kind != .saved {
            list += community.search(query, near: near).filter { kind == .all || $0.kind == kind }
            if let near { list.sort { GeoMath.distance(near, $0.coordinate) < GeoMath.distance(near, $1.coordinate) } }
        }
        return Array(list.prefix(150))
    }

    var body: some View {
        List {
            Section {
                Picker("نطاق البحث", selection: $scope) {
                    Text("دون إنترنت").tag(Scope.local)
                    Text("عبر الإنترنت").tag(Scope.online)
                }
                .pickerStyle(.segmented)
                if scope == .local {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(PlaceKind.allCases) { k in
                                FilterChip(title: k.title, icon: k.icon, selected: kind == k) { kind = k }
                            }
                        }
                    }
                }
            }

            if scope == .local {
                if search.gazetteer.isEmpty {
                    Section {
                        Label("لا توجد قاعدة بيانات جغرافية محلية بعد. البحث يشمل مواقعك المحفوظة فقط.", systemImage: "info.circle")
                            .font(.footnote)
                        Button("استيراد قاعدة أماكن (GeoJSON)") { importing = true }
                    } footer: {
                        Text("القاعدة المضمنة مبنية من بيانات OpenStreetMap الموثقة، ولا يضيف التطبيق أي أسماء أو إحداثيات من عنده.")
                    }
                }
                Section(header: Text("النتائج (\(localResults.count))")) {
                    if localResults.isEmpty { Text("لا توجد نتائج").foregroundStyle(.secondary) }
                    ForEach(localResults) { r in resultRow(r) }
                }
            } else {
                if !network.isOnline {
                    Label("البحث عبر الإنترنت غير متاح حاليًا. استخدم البحث دون إنترنت.", systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                }
                if isSearching { ProgressView() }
                if let onlineError { Text(onlineError).foregroundStyle(.red).font(.footnote) }
                ForEach(onlineResults) { r in resultRow(r) }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "جبل، وادي، روضة، مخيم…")
        .onSubmit(of: .search) { if scope == .online { Task { await runOnline() } } }
        .navigationTitle("البحث")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCommunity) { cp in NavigationStack { CommunityPlaceView(place: cp) } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("استيراد قاعدة أماكن (GeoJSON)") { importing = true }
                    Text("المصدر الحالي: \(search.gazetteerSource) — \(search.gazetteer.count) مكان")
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, UTType(filenameExtension: "geojson") ?? .json]) { result in
            if case .success(let url) = result {
                do {
                    let count = try search.importGazetteer(from: url)
                    importMessage = "تم استيراد \(count) مكان."
                }
                catch { importMessage = "تعذّر الاستيراد: \(error.localizedDescription)" }
            }
        }
        .alert("قاعدة الأماكن", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(importMessage ?? "") }
    }

    private func resultRow(_ r: SearchResult) -> some View {
        HStack {
            Image(systemName: r.kind.icon).foregroundStyle(Theme.desertOrange).frame(width: 28)
            VStack(alignment: .leading) {
                Text(r.name).font(.body.weight(.medium))
                if !r.subtitle.isEmpty { Text(r.subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let here = location.location?.coordinate {
                Text(Fmt.distance(GeoMath.distance(here, r.coordinate))).font(.caption).foregroundStyle(.secondary)
            }
            Menu {
                Button { mapManager.send(.focus(r.coordinate, spanMeters: 4000)); dismiss(); router.showOnMap() } label: {
                    Label("عرض على الخريطة", systemImage: "map")
                }
                Button { navigation.navigate(to: r.waypoint); dismiss(); router.showOnMap() } label: {
                    Label("ابدأ الملاحة", systemImage: "location.north.line.fill")
                }
                Button { router.plannerDraft.waypoints.append(r.waypoint); router.mapSheet = .routePlanner } label: {
                    Label("إضافة إلى مخطط المسار", systemImage: "plus")
                }
                if r.source != .saved {
                    Button { router.mapSheet = .savePlace(r.coordinate) } label: { Label("حفظ", systemImage: "mappin") }
                }
                if r.source == .community, let cp = community.place(forResultID: r.id) {
                    Button { selectedCommunity = cp } label: { Label("التفاصيل والإبلاغ", systemImage: "info.circle") }
                }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        }
    }

    private func runOnline() async {
        guard !query.isEmpty else { return }
        isSearching = true; onlineError = nil
        defer { isSearching = false }
        do {
            onlineResults = try await search.searchOnline(query, region: mapManager.visibleRegion)
            if onlineResults.isEmpty { onlineError = "لا توجد نتائج." }
        } catch {
            onlineResults = []
            onlineError = network.isOnline ? "تعذّر البحث: \(error.localizedDescription)" : "لا يوجد اتصال بالإنترنت."
        }
    }
}
