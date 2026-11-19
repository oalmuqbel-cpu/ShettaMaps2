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
        .frame(width: DS.control, height: 62)
        .floatingSurface()
        .overlay(RoundedRectangle(cornerRadius: DS.controlRadius, style: .continuous)
            .stroke(WeatherText.dustWarning(now) != nil ? Color.orange : .clear, lineWidth: 2))
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
                if let night = DesertNight.make(at: location.location?.coordinate ?? r.coordinate, hours: r.allHours.isEmpty ? r.hours : r.allHours) {
                    DesertNightSection(night: night)
                }
                if !r.days.isEmpty {
                    Section {
                        ForEach(Array(r.days.enumerated()), id: \.element.id) { i, day in
                            WeatherDayRow(day: day, index: i, hours: r.allHours.filter {
                                $0.time >= day.date && $0.time < day.date.addingTimeInterval(86_400)
                            }, isNight: { isNight(r, $0) })
                        }
                    } header: {
                        Text("توقعات \(r.days.count) يومًا")
                    } footer: {
                        Text("ما بعد اليوم \(WeatherService.reliableDays) تقديري وقد يتغير. اضغط على اليوم لعرض ساعاته.")
                    }
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

/// سطر يوم في توقعات الأيام: الحالة والعظمى والصغرى والمطر والرياح، ويُفتح لعرض الساعات.
struct WeatherDayRow: View {
    let day: WeatherDay
    let index: Int
    let hours: [WeatherHour]
    let isNight: (Date) -> Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: WeatherText.icon(day.weatherCode))
                        .symbolRenderingMode(.multicolor).font(.title2).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(.headline)
                            if index >= WeatherService.reliableDays {
                                Text("تقديري").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                        }
                        HStack(spacing: 8) {
                            Text(WeatherText.describe(day.weatherCode)).font(.subheadline).foregroundStyle(.secondary)
                            if let p = day.precipitationProbability, p >= 10 {
                                Label("\(Int(p))٪", systemImage: "drop.fill").font(.caption).foregroundStyle(.blue)
                            }
                            Label("\(Int(day.windMax.rounded()))", systemImage: "wind").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(day.tempMax.rounded()))°").font(.headline.monospacedDigit())
                        Text("\(Int(day.tempMin.rounded()))°").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down").font(.caption).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibility)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        if day.precipitationSum > 0 {
                            Label(String(format: "%.1f مم", day.precipitationSum), systemImage: "cloud.rain").font(.caption)
                        }
                        if let g = day.gustsMax { Label("هبات \(Int(g.rounded())) كم/س", systemImage: "wind").font(.caption) }
                        if let d = day.windDirection { Text("رياح \(WeatherText.windFrom(d))").font(.caption) }
                    }
                    .foregroundStyle(.secondary)
                    if let rise = day.sunrise, let set = day.sunset {
                        Text("الشروق \(Fmt.time.string(from: rise)) · الغروب \(Fmt.time.string(from: set))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !hours.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                // كل ساعتين حتى يبقى الشريط واضحًا
                                ForEach(hours.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)) { h in
                                    VStack(spacing: 4) {
                                        Text(Fmt.time.string(from: h.time)).font(.caption2).foregroundStyle(.secondary)
                                        Image(systemName: WeatherText.icon(h.weatherCode, night: isNight(h.time)))
                                            .symbolRenderingMode(.multicolor)
                                        Text("\(Int(h.temperature.rounded()))°").font(.caption.weight(.semibold))
                                        Text("\(Int(h.windSpeed.rounded()))").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                        if let p = h.precipitationProbability, p > 0 {
                                            Text("\(Int(p))٪").font(.caption2).foregroundStyle(.blue)
                                        } else { Text(" ").font(.caption2) }
                                    }
                                    .frame(width: 44)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day.date) { return "اليوم" }
        if cal.isDateInTomorrow(day.date) { return "غدًا" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "EEEE d"
        return f.string(from: day.date)
    }

    private var accessibility: String {
        var s = "\(title)، \(WeatherText.describe(day.weatherCode))، العظمى \(Int(day.tempMax.rounded()))، الصغرى \(Int(day.tempMin.rounded()))"
        if let p = day.precipitationProbability, p >= 10 { s += "، احتمال المطر \(Int(p)) بالمئة" }
        s += "، الرياح حتى \(Int(day.windMax.rounded())) كيلومتر في الساعة"
        return s
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

/// لوحة الأمطار: توقعات الساعات القادمة (حتى يومين) مع تشغيل متحرك، أو رصد القمر الصناعي الآن.
struct RainPanel: View {
    @ObservedObject var forecast: RainForecastService
    @ObservedObject var observedService: RainNowService
    @Binding var observed: Bool
    @State private var playing = false
    /// بطاقة مدمجة: سطر واحد افتراضيًا، والتفاصيل عند فتحها.
    @AppStorage("rainPanelExpanded") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s) {
            // السطر الرئيسي: الحالة والوقت وزر التشغيل وزر الطي
            HStack(spacing: DS.s) {
                Image(systemName: observed ? "cloud.rain.fill" : "cloud.sun.rain.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 17))
                VStack(alignment: .leading, spacing: 1) {
                    Text(observed ? "المطر الآن" : "توقعات الأمطار").font(.subheadline.weight(.semibold))
                    Text(observed ? observedLabel : forecastLabel)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if observed ? observedService.loading : forecast.loading { ProgressView().controlSize(.small) }
                if !observed && !forecast.frames.isEmpty {
                    Button { playing.toggle() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.desertOrange)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.desertOrange.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playing ? "إيقاف" : "تشغيل حركة المطر")
                }
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "طي التفاصيل" : "عرض التفاصيل")
            }
            if !observed && !forecast.frames.isEmpty {
                Slider(value: Binding(get: { Double(forecast.index) },
                                      set: { forecast.index = Int($0.rounded()); playing = false }),
                       in: 0...Double(max(1, forecast.frames.count - 1)), step: 1)
                    .environment(\.layoutDirection, .leftToRight)
            }
            if expanded {
                Picker("", selection: $observed) {
                    Text("التوقعات").tag(false)
                    Text("الآن بالقمر الصناعي").tag(true)
                }
                .pickerStyle(.segmented)
                HStack {
                    legend
                    Spacer(minLength: 4)
                    if !observed, let m = forecast.selected?.maxRate, m < 0.2 {
                        Text("لا أمطار متوقعة").font(.caption2).foregroundStyle(.secondary)
                    }
                    if observed && observedService.failed {
                        Text("تعذّر التحميل").font(.caption2).foregroundStyle(.red)
                    }
                }
                Text(observed ? RainNowService.attribution + "، تقدير بالقمر الصناعي ويتأخر قرابة نصف ساعة."
                              : RainForecastService.attribution)
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if !observed && forecast.frames.isEmpty && forecast.failed {
                Text("تعذّر تنزيل التوقعات، تحقق من الاتصال.").font(.caption)
            }
        }
        .hudCard()
        .task(id: playing) {
            // تشغيل متحرك: ساعة كل ٠٫٦ ثانية، ثم يعود للبداية
            while playing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard playing, !forecast.frames.isEmpty else { break }
                forecast.index = (forecast.index + 1) % forecast.frames.count
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 5) {
            ForEach(1..<5) { l in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(RainScale.color(l).opacity(0.75)).frame(width: 9, height: 9)
                    Text(RainScale.titles[l]).font(.system(size: 9))
                }
            }
        }
    }

    private var forecastLabel: String {
        guard let t = forecast.selected?.time else { return forecast.loading ? "جارٍ التنزيل" : "" }
        let hours = Int((t.timeIntervalSinceNow / 3600).rounded())
        let when = hours <= 0 ? "الآن" : (hours == 1 ? "بعد ساعة" : (hours == 2 ? "بعد ساعتين" : (hours <= 10 ? "بعد \(hours) ساعات" : "بعد \(hours) ساعة")))
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateFormat = "EEEE h a"
        return "\(when) · \(f.string(from: t))"
    }

    private var observedLabel: String {
        guard let t = observedService.frames.last else { return "جارٍ التحميل" }
        let minutes = max(0, Int(Date().timeIntervalSince(t) / 60))
        return "آخر صورة الساعة \(Fmt.time.string(from: t)) · قبل \(minutes) دقيقة"
    }
}

/// قسم «ليلة البر»: الشفق والظلام والقمر وأجواء الليلة.
struct DesertNightSection: View {
    let night: DesertNight

    private var moonSymbol: String {
        switch night.phaseName {
        case "محاق": return "moonphase.new.moon"
        case "هلال متزايد": return "moonphase.waxing.crescent"
        case "تربيع أول": return "moonphase.first.quarter"
        case "أحدب متزايد": return "moonphase.waxing.gibbous"
        case "بدر": return "moonphase.full.moon"
        case "أحدب متناقص": return "moonphase.waning.gibbous"
        case "تربيع أخير": return "moonphase.last.quarter"
        default: return "moonphase.waning.crescent"
        }
    }

    private func t(_ d: Date?) -> String { d.map { Fmt.time.string(from: $0) } ?? "—" }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: moonSymbol).font(.system(size: 34)).foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
                VStack(alignment: .leading, spacing: 2) {
                    Text(night.phaseName).font(.headline)
                    Text("إضاءة القمر \(Int((night.illumination * 100).rounded()))٪").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if night.moonRise != nil || night.moonSet != nil {
                LabeledContent("القمر", value: [night.moonRise.map { "يشرق \(Fmt.time.string(from: $0))" },
                                                night.moonSet.map { "يغيب \(Fmt.time.string(from: $0))" }]
                    .compactMap { $0 }.joined(separator: " · "))
            }
            LabeledContent("الغروب", value: t(night.sunset))
            LabeledContent("آخر ضوء (الشفق المدني)", value: t(night.civilDusk))
            LabeledContent("الظلام الكامل", value: "\(t(night.astroDusk)) — \(t(night.astroDawn))")
            LabeledContent("الشروق", value: t(night.sunrise))
            if let b = night.bestDark {
                LabeledContent("أفضل وقت لرصد النجوم", value: "\(Fmt.time.string(from: b.start)) — \(Fmt.time.string(from: b.end))")
            } else {
                LabeledContent("رصد النجوم", value: "القمر يضيء أغلب الليل")
            }
            if let w = night.windMax {
                LabeledContent("رياح الليلة", value: "حتى \(Int(w.rounded())) كم/س" + (night.gustMax.map { " · هبات \(Int($0.rounded()))" } ?? ""))
            }
            if let m = night.tempMin { LabeledContent("أدنى حرارة", value: "\(Int(m.rounded()))°") }
        } header: {
            Text("ليلة البر")
        } footer: {
            Text("أوقات الشمس والقمر محسوبة في الجهاز دون إنترنت، وأوقات القمر تقريبية بحدود عشر دقائق.")
        }
    }
}
