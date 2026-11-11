import SwiftUI
import SwiftData
import CoreLocation

/// مخطط مسار متعدد النقاط: نقطة انطلاق، نقاط مرور، ووجهة، مع حساب المسافات والاتجاهات لكل مرحلة.
struct RoutePlannerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var mapManager: MapManager
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]

    @State private var pickingFor: PickTarget?
    @State private var coordText = ""
    @State private var coordError: String?

    enum PickTarget: Identifiable { case origin, waypoint, destination; var id: Int { hashValue } }

    private var draft: RoutePlannerDraft { router.plannerDraft }

    /// الخطة الناتجة: الوجهة هي آخر نقطة إن لم تُحدد صراحةً.
    private var plan: NavigationPlan? {
        var wps = draft.waypoints
        let dest: Waypoint
        if let d = draft.destination { dest = d } else if let last = wps.popLast() { dest = last } else { return nil }
        let origin: Waypoint? = draft.useCurrentLocationAsOrigin
            ? location.location.map { Waypoint(name: "موقعي", coordinate: $0.coordinate) }
            : draft.origin
        return NavigationPlan(origin: origin, waypoints: wps, destination: dest, mode: .direct)
    }

    var body: some View {
        Form {
            Section("الانطلاق") {
                Toggle("من موقعي الحالي", isOn: $router.plannerDraft.useCurrentLocationAsOrigin)
                if !draft.useCurrentLocationAsOrigin {
                    pointRow(draft.origin, placeholder: "حدد نقطة الانطلاق") { pickingFor = .origin }
                }
            }
            Section {
                if draft.waypoints.isEmpty {
                    Text("لا توجد نقاط مرور").foregroundStyle(.secondary)
                }
                ForEach(Array(draft.waypoints.enumerated()), id: \.element.id) { i, w in
                    HStack {
                        Text("\(i + 1)").font(.caption.bold()).frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.sand))
                        VStack(alignment: .leading) {
                            Text(w.name)
                            Text(CoordinateUtilities.format(w.coordinate, as: .decimal)).font(.caption.monospaced())
                                .foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
                        }
                    }
                }
                .onDelete { router.plannerDraft.waypoints.remove(atOffsets: $0) }
                .onMove { router.plannerDraft.waypoints.move(fromOffsets: $0, toOffset: $1) }
                Button { pickingFor = .waypoint } label: { Label("إضافة نقطة مرور", systemImage: "plus.circle") }
            } header: { Text("نقاط المرور") }

            Section("الوجهة") {
                pointRow(draft.destination, placeholder: "إن تُركت فارغة تُعتبر آخر نقطة مرور هي الوجهة") { pickingFor = .destination }
            }

            if let plan {
                Section("المراحل") {
                    ForEach(Array(NavigationEngine.legs(for: plan).enumerated()), id: \.offset) { _, leg in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(leg.from.name) ← \(leg.to.name)").font(.subheadline)
                            Text("\(Fmt.distance(leg.distance)) · \(Fmt.bearing(leg.bearing))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("المسافة المباشرة الكلية", value: Fmt.distance(NavigationEngine.totalDistance(for: plan)))
                }
                Section {
                    Button {
                        navigation.start(plan)
                        mapManager.send(.fit(plan.allPoints.map(\.coordinate)))
                        dismiss(); router.showOnMap()
                    } label: { Label("ابدأ الملاحة (خط مباشر)", systemImage: "location.north.line.fill") }
                    Button {
                        var p = plan; p.mode = .road
                        navigation.start(p)
                        dismiss(); router.showOnMap()
                    } label: { Label("ابدأ الملاحة عبر الطرق المعروفة", systemImage: "road.lanes") }
                    Button("مسح المخطط", role: .destructive) { router.plannerDraft = RoutePlannerDraft() }
                } footer: {
                    Text("الخط المباشر إرشاد جغرافي بالاتجاه والمسافة وليس طريقًا مضمونًا للقيادة. توجيهات الطرق تتطلب الإنترنت ولا تتوفر عادةً للمسارات الصحراوية غير المعبدة.")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("مخطط المسار")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        .sheet(item: $pickingFor) { target in
            NavigationStack { pointPicker(for: target) }
        }
    }

    private func pointRow(_ w: Waypoint?, placeholder: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let w {
                VStack(alignment: .leading) {
                    Text(w.name).foregroundStyle(.primary)
                    Text(CoordinateUtilities.format(w.coordinate, as: .decimal)).font(.caption.monospaced())
                        .foregroundStyle(.secondary).environment(\.layoutDirection, .leftToRight)
                }
            } else {
                Text(placeholder).foregroundStyle(.secondary)
            }
        }
    }

    private func pointPicker(for target: PickTarget) -> some View {
        List {
            Section("إحداثيات") {
                TextField("24.7136, 46.6753", text: $coordText)
                    .font(.body.monospaced()).keyboardType(.numbersAndPunctuation)
                    .environment(\.layoutDirection, .leftToRight)
                if let coordError { Text(coordError).font(.caption).foregroundStyle(.red) }
                Button("استخدام هذه الإحداثيات") {
                    do {
                        let c = try CoordinateUtilities.parse(coordText)
                        assign(Waypoint(name: "إحداثيات \(CoordinateUtilities.shareString(c))", coordinate: c), to: target)
                    } catch { coordError = (error as? LocalizedError)?.errorDescription }
                }
            }
            if let here = location.location?.coordinate {
                Section { Button("موقعي الحالي") { assign(Waypoint(name: "موقعي", coordinate: here), to: target) } }
            }
            Section("المواقع المحفوظة") {
                ForEach(places) { p in
                    Button(p.name) { assign(p.asWaypoint, to: target) }
                }
            }
        }
        .navigationTitle("اختر نقطة")
        .toolbar { Button("إلغاء") { pickingFor = nil } }
    }

    private func assign(_ w: Waypoint, to target: PickTarget) {
        switch target {
        case .origin: router.plannerDraft.origin = w
        case .waypoint: router.plannerDraft.waypoints.append(w)
        case .destination: router.plannerDraft.destination = w
        }
        coordText = ""; coordError = nil
        pickingFor = nil
    }
}
