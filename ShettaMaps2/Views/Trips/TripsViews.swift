import SwiftUI
import SwiftData
import CoreLocation

/// الرحلات البرية: الرحلة النشطة، إنشاء رحلة، والرحلات السابقة.
struct TripsListView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var trips: TripManager
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \Trip.createdAt, order: .reverse) private var allTrips: [Trip]
    @State private var showNew = false

    var body: some View {
        List {
            if let active = trips.activeTrip {
                Section("الرحلة النشطة") {
                    NavigationLink { TripDetailView(trip: active) } label: { ActiveTripCard(trip: active) }
                }
            } else {
                Section {
                    Button { showNew = true } label: { Label("بدء رحلة جديدة", systemImage: "plus.circle.fill") }
                }
            }
            Section("الرحلات السابقة") {
                let past = allTrips.filter { !$0.isActive }
                if past.isEmpty { Text("لا توجد رحلات سابقة").foregroundStyle(.secondary) }
                ForEach(past) { t in
                    NavigationLink { TripDetailView(trip: t) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.name).font(.body.weight(.semibold))
                            HStack(spacing: 10) {
                                Text(Fmt.dateTime.string(from: t.createdAt))
                                Text(Fmt.distance(t.totalDistance))
                                Text("\(t.stops.count) توقف")
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    let past = allTrips.filter { !$0.isActive }
                    idx.map { past[$0] }.forEach { trips.delete($0) }
                }
            }
        }
        .navigationTitle("الرحلات")
        .toolbar {
            if router.mapSheet != nil {
                ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Image(systemName: "plus") }.disabled(trips.activeTrip != nil)
            }
        }
        .sheet(isPresented: $showNew) { NavigationStack { NewTripView() } }
    }
}

struct ActiveTripCard: View {
    @EnvironmentObject private var recorder: RouteRecordingManager
    @EnvironmentObject private var location: LocationManager
    let trip: Trip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trip.name).font(.headline)
            HStack(spacing: 12) {
                if recorder.isActive {
                    Label(Fmt.distance(recorder.distance), systemImage: "record.circle").foregroundStyle(.red)
                    Label(Fmt.duration(recorder.elapsed), systemImage: "clock")
                }
                if let start = trip.startCoordinate, let here = location.location?.coordinate {
                    Label("البداية: \(Fmt.distance(GeoMath.distance(here, start)))", systemImage: "house")
                }
            }
            .font(.caption)
        }
    }
}

struct NewTripView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var trips: TripManager
    @EnvironmentObject private var router: AppRouter
    @AppStorage(SettingsKeys.autoRecordTrips) private var autoRecordDefault = true
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    @State private var name = ""
    @State private var autoRecord = true
    @State private var destinationID: UUID?

    var body: some View {
        Form {
            Section("اسم الرحلة") { TextField("مثال: كشتة روضة خريم", text: $name) }
            Section {
                Toggle("تسجيل المسار تلقائيًا", isOn: $autoRecord)
            } footer: {
                Text("يُحفظ موقعك الحالي كنقطة بداية للرحلة لتتمكن من العودة إليها لاحقًا.")
            }
            Section("الوجهة (اختياري)") {
                Picker("الوجهة", selection: $destinationID) {
                    Text("بدون").tag(UUID?.none)
                    ForEach(places) { p in Text(p.name).tag(Optional(p.id)) }
                }
            }
        }
        .navigationTitle("رحلة جديدة")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { autoRecord = autoRecordDefault }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("ابدأ") {
                    let dest = places.first { $0.id == destinationID }?.asWaypoint
                    trips.startTrip(name: name, destination: dest, autoRecord: autoRecord)
                    dismiss()
                    router.showOnMap()
                }
            }
        }
    }
}

struct TripDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var trips: TripManager
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var recorder: RouteRecordingManager
    @Bindable var trip: Trip
    @State private var confirmEnd = false
    @State private var confirmClearStart = false
    @State private var stopToDelete: Int?

    var body: some View {
        List {
            Section("نقطة البداية") {
                if let s = trip.startCoordinate {
                    Text(CoordinateUtilities.format(s, as: .decimal)).font(.footnote.monospaced())
                        .environment(\.layoutDirection, .leftToRight)
                    if let here = location.location?.coordinate {
                        LabeledContent("المسافة والاتجاه", value: "\(Fmt.distance(GeoMath.distance(here, s))) · \(Fmt.bearing(GeoMath.bearing(from: here, to: s)))")
                    }
                    Button { _ = trips.returnToStart(of: trip); router.showOnMap() } label: {
                        Label("العودة إلى نقطة البداية", systemImage: "arrow.uturn.backward.circle.fill")
                    }
                } else {
                    Text("لم تُحدد بعد (بانتظار إشارة GPS جيدة)").foregroundStyle(.secondary)
                }
                if let here = location.location?.coordinate {
                    Button("تعيين موقعي الحالي كنقطة بداية") { trips.setStart(here, for: trip) }
                }
                if trip.startCoordinate != nil {
                    Button("حذف نقطة البداية", role: .destructive) { confirmClearStart = true }
                }
            }

            if let here = location.location?.coordinate {
                Section("الشمس اليوم") {
                    if let r = SunCalculator.time(.sunrise, on: Date(), at: here) { LabeledContent("الشروق", value: Fmt.time.string(from: r)) }
                    if let s = SunCalculator.time(.sunset, on: Date(), at: here) {
                        LabeledContent("الغروب", value: Fmt.time.string(from: s))
                        if s > Date() { LabeledContent("المتبقي على الغروب", value: Fmt.duration(s.timeIntervalSinceNow)) }
                    }
                }
            }

            Section("آخر موقع معروف") {
                if let c = trip.lastKnownCoordinate {
                    Text(CoordinateUtilities.format(c, as: .decimal)).font(.footnote.monospaced())
                        .environment(\.layoutDirection, .leftToRight)
                    if let t = trip.lastKnownAt { Text(Fmt.dateTime.string(from: t)).font(.caption).foregroundStyle(.secondary) }
                } else { Text("—").foregroundStyle(.secondary) }
            }

            Section {
                ForEach(Array(trip.stops.enumerated()), id: \.element.id) { i, s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name)
                            Text(CoordinateUtilities.format(s.coordinate, as: .decimal)).font(.caption.monospaced())
                                .foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
                        }
                        Spacer()
                        Button(role: .destructive) { stopToDelete = i } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("حذف نقطة التوقف")
                    }
                }
                .onDelete { trips.removeStops(at: $0, from: trip) }
                .onMove { trips.moveStops(from: $0, to: $1, in: trip) }
                if trip.isActive, let here = location.location?.coordinate {
                    Button { trips.addStop(Waypoint(name: "توقف \(trip.stops.count + 1)", coordinate: here), to: trip) } label: {
                        Label("إضافة موقعي الحالي كنقطة توقف", systemImage: "plus.circle")
                    }
                }
            } header: { Text("نقاط التوقف") }

            if let d = trip.destination {
                Section("الوجهة") {
                    Text(d.name)
                    if let here = location.location?.coordinate {
                        LabeledContent("المسافة والاتجاه", value: "\(Fmt.distance(GeoMath.distance(here, d.coordinate))) · \(Fmt.bearing(GeoMath.bearing(from: here, to: d.coordinate)))")
                    }
                }
            }

            Section("المسارات المسجلة") {
                let tracks = (trip.tracks ?? []).sorted { $0.startedAt < $1.startedAt }
                if tracks.isEmpty { Text("لا توجد مسارات").foregroundStyle(.secondary) }
                ForEach(tracks) { t in
                    NavigationLink { TrackDetailView(track: t) } label: { TrackRow(track: t) }
                }
                LabeledContent("إجمالي المسافة", value: Fmt.distance(trip.totalDistance))
                if !tracks.isEmpty {
                    Button { showTripOnMap(tracks) } label: {
                        Label("عرض الرحلة كاملة على الخريطة", systemImage: "map")
                    }
                }
            }

            Section {
                if !trip.stops.isEmpty || trip.destination != nil {
                    Button { trips.navigateTrip(trip); router.showOnMap() } label: {
                        Label("الملاحة عبر نقاط التوقف", systemImage: "location.north.line.fill")
                    }
                }
                if trip.isActive {
                    if !recorder.isActive {
                        Button { recorder.start(name: trip.name, trip: trip) } label: { Label("بدء تسجيل المسار", systemImage: "record.circle") }
                    }
                    Button("إنهاء الرحلة", role: .destructive) { confirmEnd = true }
                }
            }
            Section("ملاحظات") {
                TextField("ملاحظات الرحلة", text: $trip.notes, axis: .vertical).lineLimit(2...6)
            }
        }
        .confirmationDialog("حذف نقطة البداية؟", isPresented: $confirmClearStart, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { trips.clearStart(of: trip) }
        }
        .confirmationDialog("حذف نقطة التوقف؟", isPresented: Binding(get: { stopToDelete != nil }, set: { if !$0 { stopToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let i = stopToDelete, trip.stops.indices.contains(i) { trips.removeStops(at: IndexSet(integer: i), from: trip) }
                stopToDelete = nil
            }
        }
        .navigationTitle(trip.name)
        .toolbar { EditButton() }
        .onDisappear { try? context.save() }
        .confirmationDialog("إنهاء الرحلة؟ سيتم حفظ المسار.", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("إنهاء الرحلة", role: .destructive) { trips.endTrip() }
        }
    }

    /// كل مسارات الرحلة كخط واحد: بداية ونهاية كبيرتان للرحلة، وعلامات صغيرة لكل وقفة بينهما.
    private func showTripOnMap(_ tracks: [RecordedTrack]) {
        let points = TrackStops.merged(tracks.map(\.points))
        let segments = TrackAccumulator.segments(of: points)
        guard !segments.isEmpty else { return }
        router.shownTrack = ShownTrack(name: trip.name, segments: segments, stops: TrackStops.stops(from: points))
        mapManager.send(.fit(points.map(\.coordinate)))
        router.showOnMap()
    }
}
