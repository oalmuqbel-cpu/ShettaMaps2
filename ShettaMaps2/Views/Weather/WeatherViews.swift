import SwiftUI
import CoreLocation

/// سهم الرياح على الخريطة: يشير إلى الجهة التي تتجه إليها الرياح، مع السرعة.
struct WindChip: View {
    let now: WeatherNow
    var mapHeading: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Label("رياح", systemImage: "wind")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Image(systemName: "location.north.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.directLine)
                .rotationEffect(.degrees(now.windDirection + 180 - mapHeading))
                .environment(\.layoutDirection, .leftToRight)
            Text("\(Int(now.windSpeed.rounded()))").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
            Text("كم/س").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(width: 52, height: 66)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(WeatherText.dustWarning(now) != nil ? Color.orange : .clear, lineWidth: 2))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
        .accessibilityLabel("رياح \(WeatherText.windFrom(now.windDirection)) بسرعة \(Int(now.windSpeed)) كيلومتر في الساعة")
    }
}

/// لوحة الطقس الكاملة لموقعك.
struct WeatherView: View {
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var location: LocationManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let r = weather.report {
                let n = r.now
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: WeatherText.icon(n.weatherCode, night: isNight(r, n.time)))
                            .symbolRenderingMode(.multicolor).font(.system(size: 40))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(n.temperature.rounded()))°").font(.system(size: 40, weight: .bold, design: .rounded))
                            Text(WeatherText.describe(n.weatherCode)).foregroundStyle(.secondary)
                        }
                    }
                    if let w = WeatherText.dustWarning(n) {
                        Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                } footer: {
                    Text("آخر تحديث \(Fmt.time.string(from: r.fetchedAt))")
                }
                Section("الرياح") {
                    HStack {
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.degrees(n.windDirection + 180))
                            .environment(\.layoutDirection, .leftToRight)
                            .foregroundStyle(Theme.directLine).font(.title2)
                        VStack(alignment: .leading) {
                            Text("\(Int(n.windSpeed.rounded())) كم/س · \(WeatherText.windFrom(n.windDirection))")
                                .font(.headline)
                            Text("تهب من \(Fmt.bearing(n.windDirection))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let g = n.windGusts { LabeledContent("الهبات", value: "\(Int(g.rounded())) كم/س") }
                    if let h = n.humidity { LabeledContent("الرطوبة", value: "\(Int(h))٪") }
                    if let v = n.visibility { LabeledContent("مدى الرؤية", value: Fmt.distance(v)) }
                    if n.precipitation > 0 { LabeledContent("المطر الآن", value: String(format: "%.1f مم", n.precipitation)) }
                }
                Section("الساعات القادمة") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(r.hours.prefix(24)) { h in
                                VStack(spacing: 5) {
                                    Text(Fmt.time.string(from: h.time)).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: WeatherText.icon(h.weatherCode, night: isNight(r, h.time)))
                                        .symbolRenderingMode(.multicolor)
                                    Text("\(Int(h.temperature.rounded()))°").font(.callout.weight(.semibold))
                                    Image(systemName: "location.north.fill").font(.caption2)
                                        .rotationEffect(.degrees(h.windDirection + 180))
                                        .environment(\.layoutDirection, .leftToRight)
                                        .foregroundStyle(Theme.directLine)
                                    Text("\(Int(h.windSpeed.rounded()))").font(.caption2).monospacedDigit()
                                    if let p = h.precipitationProbability, p > 0 {
                                        Text("\(Int(p))٪").font(.caption2).foregroundStyle(.blue)
                                    } else {
                                        Text(" ").font(.caption2)
                                    }
                                }
                                .frame(width: 46)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .environment(\.layoutDirection, .rightToLeft)
                }
                if let rise = r.sunrise, let set = r.sunset {
                    Section("الشمس") {
                        LabeledContent("الشروق", value: Fmt.time.string(from: rise))
                        LabeledContent("الغروب", value: Fmt.time.string(from: set))
                    }
                }
            } else {
                Section { Text("جارٍ تحميل الطقس…").foregroundStyle(.secondary) }
            }
            if let e = weather.lastError { Section { Text(e).font(.footnote).foregroundStyle(.orange) } }
            Section {
                Link("بيانات الطقس: Open-Meteo.com (رخصة CC BY 4.0)", destination: URL(string: "https://open-meteo.com/")!)
                    .font(.footnote)
            } footer: {
                Text("توقعات نماذج الطقس، وقد تختلف عن الواقع خصوصًا في الغبار المحلي. تابع تنبيهات المركز الوطني للأرصاد.")
            }
        }
        .navigationTitle("الطقس")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إغلاق") { dismiss() } } }
        .refreshable { if let c = location.location?.coordinate { await weather.refresh(at: c, force: true) } }
        .task { if let c = location.location?.coordinate { await weather.refresh(at: c) } }
    }

    private func isNight(_ r: WeatherReport, _ t: Date) -> Bool {
        AppearanceController.isNight(at: r.coordinate, now: t)
    }
}

/// ألوان شدة المطر.
enum RainScale {
    static func level(_ mm: Double) -> Int {
        switch mm {
        case ..<0.1: return 0
        case ..<1: return 1
        case ..<4: return 2
        case ..<10: return 3
        default: return 4
        }
    }
    static let colorsUI: [UIColor] = [
        .clear,
        UIColor(red: 0.55, green: 0.80, blue: 0.98, alpha: 1),
        UIColor(red: 0.20, green: 0.55, blue: 0.95, alpha: 1),
        UIColor(red: 0.10, green: 0.25, blue: 0.80, alpha: 1),
        UIColor(red: 0.55, green: 0.15, blue: 0.75, alpha: 1)
    ]
    static func color(_ level: Int) -> Color { Color(uiColor: colorsUI[max(0, min(4, level))]) }
    static let titles = ["", "خفيف", "متوسط", "غزير", "غزير جدًا"]
}

/// شريط وقت خريطة الأمطار مع المفتاح.
struct RainTimeline: View {
    let hours: [Date]
    @Binding var index: Int
    var loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: "cloud.rain").font(.footnote.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                HStack(spacing: 6) {
                    ForEach(1..<5) { l in
                        HStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2).fill(RainScale.color(l).opacity(0.75)).frame(width: 10, height: 10)
                            Text(RainScale.titles[l]).font(.system(size: 9))
                        }
                    }
                }
            }
            if hours.count > 1 {
                Slider(value: Binding(get: { Double(index) }, set: { index = Int($0.rounded()) }),
                       in: 0...Double(max(1, hours.count - 1)), step: 1)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Text("توقعات نموذج الطقس (Open-Meteo)، وليست صور رادار.").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .hudCard()
    }

    private var label: String {
        guard hours.indices.contains(index) else { return "الأمطار المتوقعة" }
        return index == 0 ? "الأمطار الآن" : "الأمطار الساعة \(Fmt.time.string(from: hours[index]))"
    }
}
