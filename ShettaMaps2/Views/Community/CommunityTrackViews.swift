import SwiftUI
import SwiftData
import MapKit

/// مشاركة مسار مسجّل مع المجتمع.
struct ShareTrackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var community: CommunityService
    @EnvironmentObject private var store: CommunityTrackStore
    @Bindable var track: RecordedTrack
    let points: [TrackPoint]
    @State private var name = ""
    @State private var notes = ""
    @State private var showTerms = false
    @State private var sending = false
    @State private var error: String?

    private var prepared: [CLLocationCoordinate2D] { CommunityTrackStore.prepare(points.map(\.coordinate)) }

    var body: some View {
        Form {
            Section {
                Map {
                    MapPolyline(coordinates: points.map(\.coordinate)).stroke(.gray.opacity(0.5), lineWidth: 4)
                    MapPolyline(coordinates: prepared).stroke(Theme.track, lineWidth: 4)
                }
                .frame(height: 220)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("للخصوصية: يُخفى أول وآخر 400 متر من المسار (الجزء الرمادي) حتى لا يظهر مكان انطلاقك أو بيتك. ولا يُنشر اسمك.")
            }
            Section("اسم المسار") {
                TextField("مثال: طريق روضة خريم من الشمال", text: $name)
            }
            Section {
                TextField("حالة الطريق، الرمل، التطعيس، أماكن التوقف…", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            } header: { Text("وش صار معكم؟") } footer: {
                Text("حتى 500 حرف. لا تكتب أرقام جوال أو معلومات شخصية.")
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .navigationTitle("مشاركة المسار")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if name.isEmpty { name = track.name } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if sending { ProgressView() } else {
                    Button("نشر") { if community.termsAccepted { send() } else { showTerms = true } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).count < 2 || prepared.count < 2)
                }
            }
        }
        .sheet(isPresented: $showTerms) {
            NavigationStack { CommunityTermsView { community.termsAccepted = true; send() } }
        }
    }

    private func send() {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                let id = try await store.publish(name: name, notes: notes, coordinates: points.map(\.coordinate))
                track.publicID = id
                try? context.save()
                dismiss()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// قائمة مسارات المجتمع القريبة.
struct CommunityTracksListView: View {
    @EnvironmentObject private var store: CommunityTrackStore
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var mapManager: MapManager

    private var center: CLLocationCoordinate2D? { location.location?.coordinate ?? mapManager.visibleRegion?.center }

    private var sorted: [CommunityTrack] {
        let list = store.visibleTracks
        guard let c = center else { return list.sorted { $0.createdAt > $1.createdAt } }
        return list.sorted { distanceTo($0, c) < distanceTo($1, c) }
    }

    private func distanceTo(_ t: CommunityTrack, _ c: CLLocationCoordinate2D) -> Double {
        let mid = CLLocationCoordinate2D(latitude: (t.minLat + t.maxLat) / 2, longitude: (t.minLon + t.maxLon) / 2)
        return GeoMath.distance(c, mid)
    }

    var body: some View {
        List {
            if store.isLoading { ProgressView() }
            if let e = store.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            if sorted.isEmpty && !store.isLoading {
                ContentUnavailableView("لا توجد مسارات قريبة", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("كن أول من يشارك مسارًا في منطقتك من تفاصيل أي مسار مسجّل."))
            }
            ForEach(sorted) { t in
                NavigationLink { CommunityTrackView(track: t) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).font(.body.weight(.medium))
                        HStack {
                            Text(Fmt.distance(t.distance))
                            if let c = center { Text("· يبعد \(Fmt.distance(distanceTo(t, c)))") }
                            Text("· \(Fmt.dateTime.string(from: t.createdAt))")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if !t.notes.isEmpty { Text(t.notes).font(.caption).lineLimit(2) }
                    }
                }
            }
        }
        .navigationTitle("مسارات المجتمع")
        .refreshable { await load(force: true) }
        .task { await load(force: false) }
    }

    private func load(force: Bool) async {
        guard let c = center else { return }
        await store.refresh(sw: .init(latitude: c.latitude - 1.5, longitude: c.longitude - 1.5),
                            ne: .init(latitude: c.latitude + 1.5, longitude: c.longitude + 1.5), force: force)
    }
}

/// تفاصيل مسار من المجتمع.
struct CommunityTrackView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CommunityTrackStore
    @EnvironmentObject private var community: CommunityService
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var mapManager: MapManager
    let track: CommunityTrack
    @State private var confirmReport = false
    @State private var saved = false
    @State private var error: String?

    private var coords: [CLLocationCoordinate2D] { store.coordinates(of: track) }
    private var isMine: Bool { track.authorUid == community.myUid }

    var body: some View {
        List {
            Section {
                Map {
                    MapPolyline(coordinates: coords).stroke(Theme.track, lineWidth: 4)
                    if let s = coords.first { Marker("البداية", systemImage: "flag.fill", coordinate: s).tint(.green) }
                    if let e = coords.last { Marker("النهاية", systemImage: "flag.checkered", coordinate: e).tint(.red) }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            Section {
                LabeledContent("المسافة", value: Fmt.distance(track.distance))
                LabeledContent("تاريخ المشاركة", value: Fmt.dateTime.string(from: track.createdAt))
                if !track.notes.isEmpty { Text(track.notes) }
            } header: { Text(track.name) } footer: {
                Text("مشاركة من أحد المستخدمين. قد لا يكون المسار مناسبًا لكل السيارات؛ تحقق من الطريق بنفسك.")
            }
            Section {
                Button {
                    router.shownTrack = ShownTrack(name: track.name, segments: [coords])
                    mapManager.send(.fit(coords)); router.showOnMap()
                } label: { Label("عرض على الخريطة", systemImage: "map") }
                if let s = coords.first {
                    Button {
                        navigation.navigate(to: Waypoint(name: "بداية \(track.name)", coordinate: s)); router.showOnMap()
                    } label: { Label("الملاحة إلى بداية المسار", systemImage: "location.north.line.fill") }
                }
                Button { saveCopy() } label: {
                    Label(saved ? "حُفظ في مساراتك" : "حفظ نسخة في مساراتي", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                }
                .disabled(saved)
            }
            Section {
                if isMine {
                    Button("حذف مشاركتي", role: .destructive) {
                        Task {
                            do { try await store.unpublish(id: track.id); dismiss() }
                            catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                        }
                    }
                } else {
                    Button("إبلاغ عن محتوى مخالف", role: .destructive) { confirmReport = true }
                    Button("إخفاء كل مشاركات هذا الناشر") { community.hiddenAuthors.insert(track.authorUid); dismiss() }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("الإبلاغ عن هذا المسار؟", isPresented: $confirmReport, titleVisibility: .visible) {
            Button("إبلاغ", role: .destructive) { Task { await store.report(track); dismiss() } }
        } message: { Text("سيختفي عنك فورًا، ويُخفى عن الجميع بعد عدة بلاغات.") }
    }

    private func saveCopy() {
        let now = Date()
        let pts = coords.enumerated().map { i, c in TrackPoint(lat: c.latitude, lon: c.longitude, time: now.addingTimeInterval(Double(i))) }
        let t = RecordedTrack(name: track.name)
        t.isImported = true
        t.isComplete = true
        t.points = pts
        t.distanceMeters = track.distance
        t.endedAt = now
        context.insert(t)
        try? context.save()
        saved = true
    }
}
