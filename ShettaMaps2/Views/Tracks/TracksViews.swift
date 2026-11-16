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
    @State private var pendingDelete: [RecordedTrack] = []
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
            .onDelete { idx in pendingDelete = idx.map { tracks[$0] } }
        }
        .confirmationDialog(pendingDelete.count == 1 ? "حذف المسار «\(pendingDelete.first?.name ?? "")»؟" : "حذف \(pendingDelete.count) مسارات؟",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                pendingDelete.forEach { context.delete($0) }
                try? context.save()
                pendingDelete = []
            }
            Button("إلغاء", role: .cancel) { pendingDelete = [] }
        } message: { Text("لا يمكن التراجع عن الحذف.") }
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
    @State private var confirmDelete = false
    @EnvironmentObject private var communityTracks: CommunityTrackStore
    // أجزاء المسار حسب الوقفات
    @State private var selectedPart: TrackPart?
    @State private var partToDelete: TrackPart?
    @State private var partToRename: TrackPart?
    @State private var partName = ""
    @State private var mapPosition: MapCameraPosition = .automatic

    private var parts: [TrackPart] { TrackParts.parts(points).filter { $0.coordinates.count > 1 } }

    private func partTitle(_ p: TrackPart) -> String {
        track.partNames[p.keyString].flatMap { $0.isEmpty ? nil : $0 } ?? "الجزء \(p.index)"
    }

    private var segments: [[CLLocationCoordinate2D]] { TrackAccumulator.segments(of: points) }

    var body: some View {
        List {
            Section {
                Map(position: $mapPosition) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        MapPolyline(coordinates: seg)
                            .stroke(selectedPart == nil ? Theme.track : Theme.track.opacity(0.3), lineWidth: 4)
                    }
                    if let sp = selectedPart, let a = sp.coordinates.first, let b = sp.coordinates.last {
                        MapPolyline(coordinates: sp.coordinates).stroke(Theme.desertOrange, lineWidth: 6)
                        Marker("بداية \(partTitle(sp))", systemImage: "play.fill", coordinate: a).tint(.green)
                        Marker("نهاية \(partTitle(sp))", systemImage: "pause.fill", coordinate: b).tint(.orange)
                    }
                    if let f = points.first { Marker("البداية", systemImage: "flag", coordinate: f.coordinate).tint(.green) }
                    if let l = points.last { Marker("النهاية", systemImage: "flag.checkered", coordinate: l.coordinate).tint(.red) }
                }
                .frame(height: 260)
                .listRowInsets(EdgeInsets())
            }
            if parts.count > 1 {
                Section {
                    ForEach(parts) { part in
                        Button { select(part) } label: { partRow(part) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { partToDelete = part } label: { Label("حذف", systemImage: "trash") }
                                Button { partName = track.partNames[part.keyString] ?? ""; partToRename = part } label: {
                                    Label("تسمية", systemImage: "pencil")
                                }.tint(Theme.brown)
                            }
                            .contextMenu { partMenu(part) }
                    }
                } header: {
                    Text("أجزاء المسار (\(parts.count))")
                } footer: {
                    Text("يُقسم المسار عند كل وقفة تساوي مدة «الإيقاف التلقائي» في الإعدادات أو أطول. اضغط على جزء لعرضه، واسحب أو اضغط مطولًا للخيارات.")
                }
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
                    router.shownTrack = ShownTrack(name: track.name, segments: segments, stops: TrackStops.stops(from: points))
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
                Button("حذف المسار", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(track.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("حذف «\(partToDelete.map(partTitle) ?? "")» من المسار؟",
                            isPresented: Binding(get: { partToDelete != nil }, set: { if !$0 { partToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("حذف الجزء", role: .destructive) { if let p = partToDelete { deletePart(p) }; partToDelete = nil }
            Button("إلغاء", role: .cancel) { partToDelete = nil }
        } message: { Text("يُحذف هذا الجزء من الطريق فقط ويبقى مكانه فراغًا، وتبقى بقية الأجزاء كما هي. لا يمكن التراجع.") }
        .alert("تسمية الجزء", isPresented: Binding(get: { partToRename != nil }, set: { if !$0 { partToRename = nil } })) {
            TextField("مثال: طريق الروضة", text: $partName)
            Button("حفظ") {
                if let p = partToRename {
                    var names = track.partNames
                    let n = partName.trimmingCharacters(in: .whitespaces)
                    names[p.keyString] = n.isEmpty ? nil : n
                    track.partNames = names
                    try? context.save()
                }
                partToRename = nil
            }
            Button("إلغاء", role: .cancel) { partToRename = nil }
        }
        .confirmationDialog("حذف المسار «\(track.name)»؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("حذف", role: .destructive) { context.delete(track); try? context.save(); dismiss() }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("لا يمكن التراجع عن الحذف.") }
        .onAppear {
            // ترقيم الأجزاء حسب الوقفات (مرة واحدة، ويُحفظ)
            let original = track.points
            let normalized = TrackParts.normalized(original, stopThreshold: TrackParts.stopThreshold)
            if normalized.map(\.segment) != original.map(\.segment) {
                track.points = normalized
                try? context.save()
            }
            points = normalized
            mapPosition = initialPosition
        }
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

    // MARK: - أجزاء المسار

    private func partRow(_ part: TrackPart) -> some View {
        HStack(spacing: 12) {
            Text("\(part.index)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(selectedPart?.key == part.key ? Theme.desertOrange : Theme.brown))
            VStack(alignment: .leading, spacing: 3) {
                Text(partTitle(part)).font(.body.weight(.semibold))
                Text("\(Fmt.time.string(from: part.start))–\(Fmt.time.string(from: part.end)) · \(Fmt.distance(part.distance)) · \(Fmt.duration(part.duration))")
                    .font(.caption).foregroundStyle(.secondary)
                if let stop = part.stopAfter, stop >= 60 {
                    Label("بعده وقفة \(Fmt.duration(stop))", systemImage: "pause.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu { partMenu(part) } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(Theme.desertOrange)
            }
            .accessibilityLabel("خيارات \(partTitle(part))")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func partMenu(_ part: TrackPart) -> some View {
        Button { select(part) } label: { Label("عرض هذا الجزء", systemImage: "eye") }
        Button {
            router.shownTrack = ShownTrack(name: partTitle(part), segments: [part.coordinates], stops: [])
            mapManager.send(.fit(part.coordinates)); router.showOnMap()
        } label: { Label("عرضه على الخريطة الرئيسية", systemImage: "map") }
        Button { partName = track.partNames[part.keyString] ?? ""; partToRename = part } label: {
            Label("تسمية الجزء", systemImage: "pencil")
        }
        Button { exportPart(part) } label: { Label("تصدير الجزء GPX", systemImage: "square.and.arrow.up") }
        if let a = part.coordinates.first {
            Button {
                navigation.navigate(to: Waypoint(name: "بداية \(partTitle(part))", coordinate: a)); router.showOnMap()
            } label: { Label("الملاحة إلى بدايته", systemImage: "arrow.uturn.backward") }
        }
        if let b = part.coordinates.last {
            Button {
                navigation.navigate(to: Waypoint(name: "نهاية \(partTitle(part))", coordinate: b)); router.showOnMap()
            } label: { Label("الملاحة إلى نهايته", systemImage: "flag.checkered") }
        }
        Button(role: .destructive) { partToDelete = part } label: { Label("حذف الجزء", systemImage: "trash") }
    }

    private func select(_ part: TrackPart) {
        selectedPart = selectedPart?.key == part.key ? nil : part
        let coords = selectedPart?.coordinates ?? points.map(\.coordinate)
        guard let box = GeoMath.boundingBox(coords) else { return }
        let center = CLLocationCoordinate2D(latitude: (box.sw.latitude + box.ne.latitude) / 2,
                                            longitude: (box.sw.longitude + box.ne.longitude) / 2)
        withAnimation {
            mapPosition = .region(MKCoordinateRegion(center: center,
                span: MKCoordinateSpan(latitudeDelta: max(0.004, (box.ne.latitude - box.sw.latitude) * 1.4),
                                       longitudeDelta: max(0.004, (box.ne.longitude - box.sw.longitude) * 1.4))))
        }
    }

    private func exportPart(_ part: TrackPart) {
        let name = "\(track.name) - \(partTitle(part))"
        let xml = GPXService.export(trackName: name, points: TrackParts.points(of: part, in: points))
        shareURL = try? GPXService.writeTemporaryFile(xml, baseName: name)
    }

    /// حذف جزء كامل وإعادة حساب إحصائيات المسار.
    private func deletePart(_ part: TrackPart) {
        let pts = TrackParts.removing(part, from: points)
        guard pts.count > 1 else { return }
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
        var names = track.partNames
        names[part.keyString] = nil
        track.partNames = names
        try? context.save()
        if selectedPart?.key == part.key { selectedPart = nil }
        points = pts
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
