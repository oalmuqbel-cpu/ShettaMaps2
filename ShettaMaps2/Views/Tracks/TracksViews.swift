import SwiftUI
import SwiftData
import MapKit
import UniformTypeIdentifiers

extension UTType {
    static let gpx = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let mbtiles = UTType(importedAs: "com.almuqbel.shettamaps2.mbtiles", conformingTo: .data)
}

/// استعراض المسارات السابقة واستيراد ملفات GPX.
struct TracksListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var recorder: RouteRecordingManager
    @EnvironmentObject private var router: AppRouter
    @Query(filter: #Predicate<RecordedTrack> { $0.isComplete == true }, sort: \RecordedTrack.startedAt, order: .reverse)
    private var tracks: [RecordedTrack]

    @State private var importing = false
    @State private var message: String?

    var body: some View {
        List {
            if recorder.isActive {
                Section {
                    HStack {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                        VStack(alignment: .leading) {
                            Text("تسجيل جارٍ").font(.headline)
                            Text("\(Fmt.distance(recorder.distance)) · \(Fmt.duration(recorder.elapsed))").font(.caption)
                        }
                        Spacer()
                        Button("إنهاء") { recorder.finish() }.buttonStyle(.borderedProminent).tint(.red)
                    }
                }
            }
            if tracks.isEmpty {
                ContentUnavailableView("لا توجد مسارات", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("ابدأ تسجيل مسار من الخريطة أو استورد ملف GPX."))
            }
            ForEach(tracks) { t in
                NavigationLink { TrackDetailView(track: t) } label: { TrackRow(track: t) }
            }
            .onDelete { idx in
                idx.map { tracks[$0] }.forEach { context.delete($0) }
                try? context.save()
            }
        }
        .navigationTitle("المسارات")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label("استيراد GPX", systemImage: "square.and.arrow.down") }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { CommunityTracksListView() } label: { Label("مسارات المجتمع", systemImage: "person.2") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.gpx, .xml], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): urls.forEach(importGPX)
            case .failure(let e): message = e.localizedDescription
            }
        }
        .onChange(of: router.incomingGPX) { _, url in
            if let url { importGPX(url); router.incomingGPX = nil }
        }
        .onAppear {
            if let url = router.incomingGPX { importGPX(url); router.incomingGPX = nil }
        }
        .alert("الاستيراد", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func importGPX(_ url: URL) {
        do {
            let doc = try GPXService.parse(url: url)
            var trackCount = 0
            for t in doc.tracks where t.points.count >= 2 {
                let acc = TrackAccumulator(existing: t.points)
                let track = RecordedTrack(name: t.name, startedAt: t.points.first?.time ?? Date())
                track.points = acc.points
                track.distanceMeters = acc.distance
                track.movingSeconds = acc.movingSeconds
                track.maxSpeed = acc.maxSpeed
                if let a = t.points.first?.time, let b = t.points.last?.time { track.elapsedSeconds = max(0, b.timeIntervalSince(a)) }
                track.endedAt = t.points.last?.time
                track.isComplete = true
                track.isImported = true
                context.insert(track)
                trackCount += 1
            }
            let general = try? context.fetch(FetchDescriptor<PlaceCategory>(predicate: #Predicate { $0.name == "عام" })).first
            for w in doc.waypoints {
                let p = SavedPlace(name: w.name, coordinate: .init(latitude: w.lat, longitude: w.lon),
                                   notes: w.notes ?? "", altitude: w.elevation, category: general)
                context.insert(p)
            }
            try context.save()
            message = "تم استيراد \(trackCount) مسار و\(doc.waypoints.count) نقطة."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct TrackRow: View {
    let track: RecordedTrack
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(track.name).font(.body.weight(.semibold)).lineLimit(1)
                if track.isImported { Text("مستورد").font(.caption2).padding(.horizontal, 6).background(Capsule().fill(Theme.sand)) }
            }
            HStack(spacing: 12) {
                Label(Fmt.distance(track.distanceMeters), systemImage: "ruler")
                Label(Fmt.duration(track.elapsedSeconds), systemImage: "clock")
                Text(Fmt.dateTime.string(from: track.startedAt))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// تفاصيل المسار: خريطة، إحصائيات، تصدير، وإرشاد للعودة إلى بدايته.
struct TrackDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var mapManager: MapManager
    @Bindable var track: RecordedTrack
    @State private var points: [TrackPoint] = []
    @State private var shareURL: URL?
    @State private var renaming = false
    @State private var newName = ""
    @State private var sharing = false
    @State private var shareError: String?
    @EnvironmentObject private var communityTracks: CommunityTrackStore

    private var segments: [[CLLocationCoordinate2D]] { TrackAccumulator.segments(of: points) }

    var body: some View {
        List {
            Section {
                Map(initialPosition: initialPosition) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg).stroke(Theme.track, lineWidth: 4)
                    }
                    if let f = points.first { Marker("البداية", systemImage: "flag", coordinate: f.coordinate).tint(.green) }
                    if let l = points.last { Marker("النهاية", systemImage: "flag.checkered", coordinate: l.coordinate).tint(.red) }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            Section("الإحصائيات") {
                LabeledContent("المسافة", value: Fmt.distance(track.distanceMeters))
                LabeledContent("المدة الكلية", value: Fmt.duration(track.elapsedSeconds))
                LabeledContent("مدة الحركة", value: Fmt.duration(track.movingSeconds))
                LabeledContent("متوسط السرعة أثناء الحركة", value: Fmt.speed(track.averageMovingSpeed))
                LabeledContent("أعلى سرعة", value: Fmt.speed(track.maxSpeed > 0 ? track.maxSpeed : nil))
                LabeledContent("عدد النقاط", value: "\(track.pointCount)")
                if let alts = altitudeRange { LabeledContent("الارتفاع", value: "\(Fmt.altitude(alts.0)) — \(Fmt.altitude(alts.1))") }
                LabeledContent("البداية", value: Fmt.dateTime.string(from: track.startedAt))
                if let e = track.endedAt { LabeledContent("النهاية", value: Fmt.dateTime.string(from: e)) }
                if let trip = track.trip { LabeledContent("الرحلة", value: trip.name) }
            }
            Section {
                Button {
                    router.shownTrack = ShownTrack(name: track.name, segments: segments)
                    mapManager.send(.fit(points.map(\.coordinate))); router.showOnMap()
                } label: {
                    Label("عرض على الخريطة الرئيسية", systemImage: "map")
                }
                if let start = points.first {
                    Button {
                        navigation.navigate(to: Waypoint(name: "بداية \(track.name)", coordinate: start.coordinate))
                        router.showOnMap()
                    } label: { Label("العودة إلى بداية المسار", systemImage: "arrow.uturn.backward") }
                }
                Button { exportGPX() } label: { Label("تصدير GPX", systemImage: "square.and.arrow.up") }
                if let pid = track.publicID {
                    Label("منشور في مسارات المجتمع", systemImage: "person.2.fill").foregroundStyle(.secondary)
                    Button("إلغاء المشاركة", role: .destructive) {
                        Task {
                            do { try await communityTracks.unpublish(id: pid); track.publicID = nil; try? context.save() }
                            catch { shareError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                        }
                    }
                } else if !track.isImported, points.count > 2 {
                    Button { sharing = true } label: { Label("مشاركة المسار مع المجتمع", systemImage: "person.2") }
                }
                if let shareError { Text(shareError).font(.footnote).foregroundStyle(.red) }
                Button { newName = track.name; renaming = true } label: { Label("إعادة التسمية", systemImage: "pencil") }
                if points.count > 2 {
                    NavigationLink { TrackTrimView(track: track, points: points) } label: {
                        Label("قص المسار أو حذف جزء منه", systemImage: "scissors")
                    }
                }
                Button("حذف المسار", role: .destructive) {
                    context.delete(track); try? context.save(); dismiss()
                }
            }
        }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { points = track.points }
        .onChange(of: track.pointCount) { _, _ in points = track.points }
        .sheet(isPresented: $sharing) { NavigationStack { ShareTrackView(track: track, points: points) } }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { ShareSheet(items: [$0.url]) }
        .alert("إعادة التسمية", isPresented: $renaming) {
            TextField("الاسم", text: $newName)
            Button("حفظ") { track.name = newName; try? context.save() }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private var initialPosition: MapCameraPosition {
        guard let box = GeoMath.boundingBox(points.map(\.coordinate)) else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: (box.sw.latitude + box.ne.latitude) / 2,
                                            longitude: (box.sw.longitude + box.ne.longitude) / 2)
        return .region(MKCoordinateRegion(center: center,
                                          span: MKCoordinateSpan(latitudeDelta: max(0.005, (box.ne.latitude - box.sw.latitude) * 1.3),
                                                                 longitudeDelta: max(0.005, (box.ne.longitude - box.sw.longitude) * 1.3))))
    }

    private var altitudeRange: (Double, Double)? {
        let alts = points.compactMap(\.alt)
        guard let mn = alts.min(), let mx = alts.max() else { return nil }
        return (mn, mx)
    }

    private func exportGPX() {
        let xml = GPXService.export(trackName: track.name, points: points)
        shareURL = try? GPXService.writeTemporaryFile(xml, baseName: track.name)
    }
}

/// قص المسار: حذف بدايته أو نهايته (مثلًا إذا نسيت إيقاف التسجيل) أو حذف جزء من وسطه.
struct TrackTrimView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var track: RecordedTrack
    let original: [TrackPoint]
    @State private var from: Double = 0
    @State private var to: Double = 0
    @State private var mode: TrackAccumulator.TrimMode = .keepRange
    @State private var confirm = false

    init(track: RecordedTrack, points: [TrackPoint]) {
        self.track = track
        self.original = points
        _to = State(initialValue: Double(max(0, points.count - 1)))
    }

    private var lastIndex: Double { Double(max(1, original.count - 1)) }
    private var result: [TrackPoint] { TrackAccumulator.trimmed(original, from: Int(from), to: Int(to), mode: mode) }
    private var selected: [CLLocationCoordinate2D] {
        guard !original.isEmpty else { return [] }
        let a = Int(min(from, to)), b = Int(max(from, to))
        return original[a...b].map(\.coordinate)
    }

    var body: some View {
        Form {
            Section {
                Map {
                    ForEach(Array(TrackAccumulator.segments(of: original).enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg).stroke(.gray.opacity(0.6), lineWidth: 4)
                    }
                    MapPolyline(coordinates: selected).stroke(mode == .keepRange ? Theme.track : .red, lineWidth: 5)
                    if let f = selected.first { Marker("من", systemImage: "scissors", coordinate: f).tint(.blue) }
                    if let l = selected.last { Marker("إلى", systemImage: "scissors", coordinate: l).tint(.blue) }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            Section {
                Picker("العملية", selection: $mode) {
                    Text("الإبقاء على المحدد").tag(TrackAccumulator.TrimMode.keepRange)
                    Text("حذف المحدد").tag(TrackAccumulator.TrimMode.removeRange)
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading) {
                    Text("من: \(timeLabel(Int(from)))").font(.subheadline)
                    Slider(value: $from, in: 0...lastIndex, step: 1)
                    Text("إلى: \(timeLabel(Int(to)))").font(.subheadline)
                    Slider(value: $to, in: 0...lastIndex, step: 1)
                }
            } footer: {
                Text(mode == .keepRange
                     ? "يُحذف ما قبل «من» وما بعد «إلى». مفيد إذا نسيت إيقاف التسجيل."
                     : "يُحذف الجزء الأحمر فقط، ويبقى ما قبله وما بعده.")
            }
            Section("بعد التعديل") {
                LabeledContent("المسافة", value: Fmt.distance(TrackAccumulator(existing: result).distance))
                LabeledContent("عدد النقاط", value: "\(result.count) من \(original.count)")
            }
        }
        .navigationTitle("قص المسار")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("حفظ") { confirm = true }.disabled(result.count < 2 || result.count == original.count)
            }
        }
        .confirmationDialog("حفظ التعديل على المسار؟", isPresented: $confirm, titleVisibility: .visible) {
            Button("حفظ", role: .destructive) { apply() }
        } message: { Text("لا يمكن التراجع عن حذف النقاط.") }
    }

    private func timeLabel(_ i: Int) -> String {
        guard original.indices.contains(i) else { return "—" }
        return Fmt.time.string(from: original[i].time)
    }

    private func apply() {
        let pts = result
        let acc = TrackAccumulator(existing: pts)
        track.points = pts
        track.distanceMeters = acc.distance
        track.movingSeconds = acc.movingSeconds
        track.maxSpeed = acc.maxSpeed
        if let f = pts.first, let l = pts.last {
            track.startedAt = f.time
            track.endedAt = l.time
            track.elapsedSeconds = l.time.timeIntervalSince(f.time)
        }
        try? context.save()
        dismiss()
    }
}
