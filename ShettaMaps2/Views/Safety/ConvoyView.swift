import SwiftUI
import CoreLocation

// MARK: - القافلة

/// قافلة: رحلة آمنة مشتركة بتحديث أسرع، يرى فيها كل عضو مواقع البقية وبعدهم عنه،
/// ويصله تنبيه إذا ابتعد أحدهم أكثر من الحد أو انقطع تحديثه.
struct ConvoyView: View {
    @EnvironmentObject private var safeTrip: SafeTripManager
    @EnvironmentObject private var follow: FollowService
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var mapManager: MapManager
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FollowService.convoyDistanceKey) private var maxKm: Double = 5
    @AppStorage("safeTrip.lastName") private var name = ""
    @State private var selected: Set<String> = []
    @State private var confirmEnd = false

    private var running: Bool { safeTrip.isConvoy }
    private var otherTripActive: Bool { safeTrip.isActive && !safeTrip.isConvoy }

    var body: some View {
        Form {
            if running { activeSections } else { setupSections }
        }
        .navigationTitle("القافلة")
        .navigationBarTitleDisplayMode(.inline)
        .task { await follow.refresh() }
        .confirmationDialog("إنهاء القافلة؟", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("إنهاء القافلة", role: .destructive) { Task { await safeTrip.end() } }
        } message: { Text("يتوقف إرسال موقعك لأعضاء القافلة.") }
    }

    // MARK: إعداد

    @ViewBuilder private var setupSections: some View {
        Section {
            Text("كل عضو يبدأ القافلة من جواله ويختار البقية. يُرسَل موقع كل عضو كل 45 ثانية تقريبًا، ويصلك تنبيه إذا ابتعد أحدهم أكثر من الحد الذي تختاره أو انقطع موقعه.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("اسمك في القافلة") {
            TextField("مثال: أبو محمد", text: $name)
        }
        Section {
            if follow.contacts.isEmpty {
                Text("أضف أعضاء القافلة أولًا من «أتابعهم» بمعرّف سَمْت لكل واحد منهم.")
                    .foregroundStyle(.secondary)
            }
            ForEach(follow.contacts) { c in
                Button {
                    if selected.contains(c.code) { selected.remove(c.code) } else { selected.insert(c.code) }
                } label: {
                    HStack {
                        Text(c.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selected.contains(c.code) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(c.code) ? Color.accentColor : .secondary)
                    }
                }
            }
        } header: { Text("الأعضاء") } footer: { Text("حتى 10 أعضاء.") }
        distanceSection
        Section {
            if otherTripActive {
                Text("لديك رحلة آمنة مفعلة. أنهِها أولًا لبدء قافلة.").font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                let members = follow.contacts.filter { selected.contains($0.code) }
                _ = safeTrip.start(name: name.isEmpty ? "قافلة" : name, contact: "", hours: 12,
                                   watchers: members, convoy: true, location: location.location)
                follow.startConvoyUpdates()
            } label: { Label("ابدأ القافلة", systemImage: "car.2") }
            .disabled(selected.isEmpty || otherTripActive || !network.isOnline)
        }
    }

    private var distanceSection: some View {
        Section {
            Picker("نبّهني إذا ابتعد عضو أكثر من", selection: $maxKm) {
                Text("2 كم").tag(2.0)
                Text("5 كم").tag(5.0)
                Text("10 كم").tag(10.0)
                Text("20 كم").tag(20.0)
            }
        }
    }

    // MARK: أثناء القافلة

    @ViewBuilder private var activeSections: some View {
        Section {
            Label("القافلة مفعلة · \(safeTrip.state?.watchers?.count ?? 0) أعضاء", systemImage: "car.2.fill")
                .foregroundStyle(.green)
            if let e = safeTrip.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
        }
        Section("الأعضاء") {
            let members = follow.convoyMembers
            if members.isEmpty {
                Text("بانتظار أن يبدأ الأعضاء القافلة من جوالاتهم.").foregroundStyle(.secondary)
            }
            ForEach(members) { t in memberRow(t) }
        }
        distanceSection
        Section {
            Button {
                mapManager.send(.fit(follow.convoyMembers.map(\.coordinate) + [location.location?.coordinate].compactMap { $0 }))
                router.showOnMap(); dismiss()
            } label: { Label("عرض القافلة على الخريطة", systemImage: "map") }
            .disabled(follow.convoyMembers.isEmpty)
            Button(role: .destructive) { confirmEnd = true } label: { Label("إنهاء القافلة", systemImage: "stop.circle") }
        }
    }

    private func memberRow(_ t: FollowedTrip) -> some View {
        let here = location.location?.coordinate
        let meters = here.map { GeoMath.distance($0, t.coordinate) }
        let far = (meters ?? 0) / 1000 > maxKm
        let stale = Date().timeIntervalSince(t.updatedAt) > 600
        return Button {
            mapManager.send(.focus(t.coordinate, spanMeters: 4_000))
            router.showOnMap(); dismiss()
        } label: {
            HStack(spacing: 12) {
                if let here {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(GeoMath.bearing(from: here, to: t.coordinate) - (location.heading.map { $0.trueHeading >= 0 ? $0.trueHeading : $0.magneticHeading } ?? 0)))
                        .foregroundStyle(far ? .orange : Color.accentColor)
                        .frame(width: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.displayName).foregroundStyle(.primary)
                    Text("منذ \(SafeTripManager.agoText(Date().timeIntervalSince(t.updatedAt)))")
                        .font(.caption).foregroundStyle(stale ? .red : .secondary)
                }
                Spacer()
                if let meters {
                    Text(Fmt.distance(meters)).font(.callout.monospacedDigit())
                        .foregroundStyle(far ? .orange : .primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
