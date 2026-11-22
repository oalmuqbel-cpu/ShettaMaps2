import SwiftUI
import CoreLocation

/// بطاقة معلومات المحمية: كل ما فيها مقتبس من مصدره ومعه رابطه، مع تنبيه بالرجوع للجهة الرسمية.
struct ReserveInfoView: View {
    let reserve: Reserve
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var location: LocationManager

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reserve.name).font(.title3.weight(.bold))
                    if let en = reserve.nameEn, en != reserve.name {
                        Text(en).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Label(reserve.kind.title, systemImage: "leaf")
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: reserve.kind.uiColor))
                }
                .padding(.vertical, 4)
                if reserve.areaKm2 > 0 {
                    LabeledContent("المساحة التقريبية", value: "\(reserve.areaKm2.formatted()) كم²")
                }
                if let op = reserve.operatorName { LabeledContent("الجهة المسؤولة", value: op) }
                if let here = location.location?.coordinate {
                    LabeledContent("موقعك", value: reserve.contains(here) ? "داخل حدود المحمية" : "خارج حدود المحمية")
                }
            }

            Section {
                Label {
                    Text("هذه المعلومات مقتبسة من المصدر المذكور أدناه، وقد لا تكون دقيقة أو محدّثة، والحدود المرسومة تقريبية. ارجع وتأكد من الجهات الرسمية قبل الدخول أو التخييم أو الصيد، فقد يلزم تصريح، وتختلف الأنظمة من محمية لأخرى.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: { Text("تنبيه") }

            Section {
                if let src = reserve.source {
                    Link(destination: src) {
                        Label("OpenStreetMap: بيانات هذه المحمية وحدودها", systemImage: "map")
                    }
                }
                Text("© مساهمو OpenStreetMap، بموجب رخصة ODbL.").font(.footnote).foregroundStyle(.secondary)
                if let site = reserve.website {
                    Link(destination: site) {
                        Label("موقع الجهة (كما ورد في المصدر): \(site.host() ?? site.absoluteString)", systemImage: "globe")
                    }
                }
            } header: { Text("المصدر") }

            if reserve.country == nil || reserve.country == "SA" {
                Section {
                    Link(destination: URL(string: "https://www.ncw.gov.sa")!) {
                        Label("المركز الوطني لتنمية الحياة الفطرية", systemImage: "building.columns")
                    }
                    Link(destination: URL(string: "https://www.ncvc.gov.sa")!) {
                        Label("المركز الوطني لتنمية الغطاء النباتي ومكافحة التصحر", systemImage: "building.columns")
                    }
                } header: { Text("جهات رسمية للتأكد") } footer: {
                    Text("المحميات الملكية لكل منها هيئة تطوير خاصة بها.")
                }
            }
        }
        .navigationTitle("المحمية")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
    }
}
