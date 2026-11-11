import SwiftUI
import SwiftData

/// شروط المشاركة العامة (مطلوبة قبل أول مشاركة وفق إرشادات Apple للمحتوى الذي ينشئه المستخدمون).
struct CommunityTermsView: View {
    @Environment(\.dismiss) private var dismiss
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("قبل مشاركة مكان بشكل عام").font(.title3.bold())
                term("المشاركة العامة تعرض اسم المكان وإحداثياته ونوعه وملاحظاته لجميع مستخدمي التطبيق.")
                term("لا يُنشر اسمك أو بريدك أو رقمك أو موقعك الحالي. يُربط المكان بمعرّف عشوائي لجهازك فقط حتى تستطيع حذفه.")
                term("شارك الأماكن البرية العامة فقط، ولا تشارك أملاكًا خاصة أو مواقع منازل أو أماكن يمنع دخولها.")
                term("يُمنع أي محتوى مسيء أو مضلل أو مخالف للأنظمة. يمكن للمستخدمين الإبلاغ عنه، ويُخفى تلقائيًا بعد عدة بلاغات، ويُحذف من قبل الإدارة دون إشعار.")
                term("الأماكن المشاركة إرشادية وقد تكون غير دقيقة. تحقق دائمًا من الطريق والسلامة قبل التوجه.")
                term("يمكنك حذف أي مشاركة لك في أي وقت بجعل المكان خاصًا أو بحذفه.")
                Button {
                    onAccept()
                } label: {
                    Text("أوافق على الشروط").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding()
        }
        .navigationTitle("شروط المشاركة")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
    }

    private func term(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(Theme.desertOrange)
            Text(text).font(.callout)
        }
    }
}

/// تفاصيل مكان مشارك من المجتمع: ملاحة، حفظ، إبلاغ، وحجب صاحب المشاركة.
struct CommunityPlaceView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var community: CommunityService
    @EnvironmentObject private var navigation: SharedNavigationState
    @EnvironmentObject private var location: LocationManager
    @EnvironmentObject private var router: AppRouter
    let place: CommunityPlace
    @State private var confirmReport = false
    @State private var confirmHide = false
    @State private var saved = false

    private var isMine: Bool { place.authorUid == community.myUid }

    var body: some View {
        List {
            Section {
                LabeledContent("النوع", value: place.kind.title)
                LabeledContent("الإحداثيات") {
                    Text(CoordinateUtilities.format(place.coordinate, as: .decimal)).font(.footnote.monospaced())
                        .environment(\.layoutDirection, .leftToRight).textSelection(.enabled)
                }
                if let here = location.location?.coordinate {
                    LabeledContent("المسافة والاتجاه",
                                   value: "\(Fmt.distance(GeoMath.distance(here, place.coordinate))) · \(Fmt.bearing(GeoMath.bearing(from: here, to: place.coordinate)))")
                }
                LabeledContent("تاريخ المشاركة", value: Fmt.dateTime.string(from: place.createdAt))
                if !place.notes.isEmpty { Text(place.notes) }
            } footer: {
                Text("مكان شاركه أحد المستخدمين. قد لا يكون دقيقًا؛ تحقق من الطريق والسلامة قبل التوجه.")
            }
            Section {
                Button { navigation.navigate(to: place.waypoint); dismiss(); router.showOnMap() } label: {
                    Label("ابدأ الملاحة إليه", systemImage: "location.north.line.fill")
                }
                Button {
                    let p = SavedPlace(name: place.name, coordinate: place.coordinate, notes: place.notes)
                    context.insert(p); try? context.save(); saved = true
                } label: { Label(saved ? "تم الحفظ في مواقعي" : "حفظ في مواقعي", systemImage: "bookmark") }
                .disabled(saved)
            }
            if !isMine {
                Section {
                    Button("الإبلاغ عن محتوى غير مناسب", role: .destructive) { confirmReport = true }
                    Button("حجب مشاركات هذا المستخدم", role: .destructive) { confirmHide = true }
                }
            }
        }
        .navigationTitle(place.name)
        .confirmationDialog("الإبلاغ عن هذه المشاركة؟ ستُخفى عنك فورًا.", isPresented: $confirmReport, titleVisibility: .visible) {
            Button("إبلاغ", role: .destructive) { Task { await community.report(place); dismiss() } }
        }
        .confirmationDialog("حجب كل مشاركات هذا المستخدم على جهازك؟", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("حجب", role: .destructive) { community.hideAuthor(of: place); dismiss() }
        }
    }
}

/// إعدادات المشاركة المجتمعية ومشاركاتي.
struct CommunitySettingsView: View {
    @EnvironmentObject private var community: CommunityService
    @Query(filter: #Predicate<SavedPlace> { $0.isPublic == true }, sort: \SavedPlace.name) private var mine: [SavedPlace]
    @State private var showTerms = false

    var body: some View {
        List {
            Section {
                LabeledContent("الحالة", value: community.isEnabled ? "مفعّلة" : "غير مفعّلة")
                LabeledContent("الشروط", value: community.termsAccepted ? "تمت الموافقة" : "لم تتم الموافقة")
                Button("عرض شروط المشاركة") { showTerms = true }
            } footer: {
                Text("عند حفظ مكان تختار «خاص» (على جهازك فقط) أو «عام» (يراه الجميع دون معلومات عنك). الأماكن العامة تساعد غيرك في العثور على الروضات والأودية والمخيمات.")
            }
            Section("مشاركاتي العامة (\(mine.count))") {
                if mine.isEmpty { Text("لا توجد مشاركات").foregroundStyle(.secondary) }
                ForEach(mine) { p in
                    VStack(alignment: .leading) {
                        Text(p.name)
                        Text(PlaceKind(rawValue: p.publicKind ?? "")?.title ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !community.hiddenAuthors.isEmpty {
                Section {
                    Button("إلغاء حجب جميع المستخدمين (\(community.hiddenAuthors.count))") { community.hiddenAuthors = [] }
                }
            }
            if let e = community.lastError {
                Section { Text(e).font(.caption).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("المشاركة المجتمعية")
        .sheet(isPresented: $showTerms) {
            NavigationStack { CommunityTermsView { community.termsAccepted = true; showTerms = false } }
        }
    }
}
