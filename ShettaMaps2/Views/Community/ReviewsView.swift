import SwiftUI

/// نجوم التقييم (عرض أو اختيار).
struct StarsView: View {
    let rating: Double
    var size: CGFloat = 14
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: Double(i) <= rating ? "star.fill" : (Double(i) - 0.5 <= rating ? "star.leadinghalf.filled" : "star"))
                    .font(.system(size: size))
                    .foregroundStyle(Theme.desertOrange)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityLabel("التقييم \(String(format: "%.1f", rating)) من 5")
    }
}

/// التقييمات والتعليقات لمكان عام.
struct ReviewsView: View {
    let placeKey: String
    let placeName: String
    @EnvironmentObject private var reviews: ReviewsService
    @Environment(\.dismiss) private var dismiss
    @State private var myRating = 0
    @State private var myText = ""
    @State private var sending = false
    @State private var toReport: PlaceReview?

    var body: some View {
        List {
            Section {
                if let avg = reviews.average(placeKey) {
                    HStack {
                        Text(String(format: "%.1f", avg)).font(.system(size: 34, weight: .bold, design: .rounded))
                        VStack(alignment: .leading) {
                            StarsView(rating: avg, size: 16)
                            Text("\(reviews.visible(placeKey).count) تقييم").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if reviews.loading.contains(placeKey) {
                    ProgressView()
                } else {
                    Text("لا توجد تقييمات بعد. كن أول من يقيّم هذا المكان.").foregroundStyle(.secondary)
                }
            } header: { Text(placeName) }

            Section {
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { i in
                        Button { myRating = i } label: {
                            Image(systemName: i <= myRating ? "star.fill" : "star")
                                .font(.title2).foregroundStyle(Theme.desertOrange)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(i) نجوم")
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity)
                TextField("تعليقك: حالة الطريق، الزحمة، الخدمات، نصيحة للزوار…", text: $myText, axis: .vertical)
                    .lineLimit(2...6)
                Button {
                    sending = true
                    Task {
                        _ = await reviews.submit(key: placeKey, placeName: placeName, rating: myRating, text: myText)
                        sending = false
                    }
                } label: {
                    if sending { ProgressView() } else { Text(reviews.mine(placeKey) == nil ? "نشر التقييم" : "تحديث تقييمي") }
                }
                .disabled(myRating == 0 || sending)
                if reviews.mine(placeKey) != nil {
                    Button("حذف تقييمي", role: .destructive) { Task { await reviews.deleteMine(key: placeKey) } }
                }
                if let e = reviews.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
            } header: { Text("تقييمك") } footer: {
                Text("يظهر تقييمك للجميع دون اسمك. تجنب ذكر بيانات شخصية. التعليقات المخالفة تُخفى بعد البلاغات.")
            }

            Section("التعليقات") {
                let list = reviews.visible(placeKey)
                if list.isEmpty { Text("لا توجد تعليقات").foregroundStyle(.secondary) }
                ForEach(list) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            StarsView(rating: Double(r.rating), size: 11)
                            Spacer()
                            Text(Fmt.dateTime.string(from: r.createdAt)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !r.text.isEmpty { Text(r.text).font(.callout) }
                    }
                    .swipeActions {
                        if r.author != CommunityService.shared.myUid {
                            Button("بلاغ") { toReport = r }.tint(.orange)
                        }
                    }
                    .contextMenu {
                        if r.author != CommunityService.shared.myUid {
                            Button("بلاغ عن تعليق مخالف", systemImage: "exclamationmark.bubble") { toReport = r }
                        }
                    }
                }
            }
        }
        .navigationTitle("التقييمات والتعليقات")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        .refreshable { await reviews.load(placeKey) }
        .task {
            reviews.clearError()
            await reviews.load(placeKey)
            if let m = reviews.mine(placeKey) { myRating = m.rating; myText = m.text }
        }
        .confirmationDialog("بلاغ عن هذا التعليق؟", isPresented: Binding(get: { toReport != nil }, set: { if !$0 { toReport = nil } }),
                            titleVisibility: .visible) {
            Button("بلاغ وإخفاء", role: .destructive) { if let r = toReport { Task { await reviews.report(r) } } }
        }
    }
}
