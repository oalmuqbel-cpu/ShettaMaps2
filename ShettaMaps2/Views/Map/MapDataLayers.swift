import UIKit
import MapKit
import MapLibre

/// طبقات البيانات (الردميات، تغطية الشبكة، الأمطار) على محرك MapLibre.
/// مشتركة بين خريطة الهاتف دون إنترنت وخريطة CarPlay حتى يتطابق الشكل.
enum MapLibreDataLayers {
    /// ردميات بيانات سَمْت: مصدر أشكال مع طبقة خطوط وطبقة نصوص على امتداد الطريق.
    @MainActor static func dirt(_ roads: [DirtRoad], on map: MLNMapView) {
        guard let style = map.style else { return }
        let features: [MLNPolylineFeature] = roads.compactMap { r in
            guard r.coordinates.count > 1 else { return nil }
            var coords = r.coordinates
            let f = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            f.attributes = ["kind": r.kind.rawValue, "label": r.name]
            return f
        }
        let shape = MLNShapeCollectionFeature(shapes: features)
        if let src = style.source(withIdentifier: "samt-dirt-data") as? MLNShapeSource {
            src.shape = shape
            return
        }
        let src = MLNShapeSource(identifier: "samt-dirt-data", shape: shape, options: nil)
        style.addSource(src)
        // إطار تحت الخط ليظهر على الرمل والأقمار الصناعية: أبيض للمؤكدة وداكن للمرصودة
        let casing = MLNLineStyleLayer(identifier: "samt-dirt-data-casing", source: src)
        casing.lineColor = NSExpression(format: "TERNARY(kind == 'ms_detected', %@, %@)",
                                        UIColor.black.withAlphaComponent(0.45), UIColor.white.withAlphaComponent(0.9))
        casing.lineWidth = NSExpression(format: "TERNARY(kind == 'ms_detected', 4.5, 6)")
        casing.lineCap = NSExpression(forConstantValue: "round")
        let line = MLNLineStyleLayer(identifier: "samt-dirt-data-line", source: src)
        line.lineColor = NSExpression(format: "TERNARY(kind == 'ms_detected', %@, %@)",
                                      DirtRoadStyle.detectedUI, DirtRoadStyle.confirmedUI)
        line.lineWidth = NSExpression(format: "TERNARY(kind == 'ms_detected', 2.5, 3.5)")
        line.lineDashPattern = NSExpression(forConstantValue: [2, 1.2])
        let text = MLNSymbolStyleLayer(identifier: "samt-dirt-data-label", source: src)
        text.predicate = NSPredicate(format: "label != ''")
        text.text = NSExpression(forKeyPath: "label")
        text.symbolPlacement = NSExpression(forConstantValue: "line")
        text.textFontSize = NSExpression(forConstantValue: 12)
        text.textFontNames = NSExpression(forConstantValue: ["Noto Sans Regular"])
        text.textColor = NSExpression(forConstantValue: UIColor(red: 0.30, green: 0.15, blue: 0.03, alpha: 1))
        text.textHaloColor = NSExpression(forConstantValue: UIColor.white)
        text.textHaloWidth = NSExpression(forConstantValue: 2)
        text.minimumZoomLevel = 12
        insertBelowLabels([casing, line], in: style)
        style.addLayer(text)
    }

    /// خريطة الأمطار المتوقعة: مربعات بلون شدة المطر للساعة المختارة.
    @MainActor static func rain(_ cells: [RainCell], hour: Int, on map: MLNMapView) {
        guard let style = map.style else { return }
        let polys: [MLNPolygonFeature] = cells.compactMap { cell in
            let mm = cell.hourly.indices.contains(hour) ? cell.hourly[hour] : 0
            let l = RainScale.level(mm)
            guard l > 0 else { return nil }
            var coords = cell.corners
            let f = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
            f.attributes = ["l": l]
            return f
        }
        let shape = MLNShapeCollectionFeature(shapes: polys)
        if let src = style.source(withIdentifier: "samt-rain") as? MLNShapeSource {
            src.shape = shape
            return
        }
        let src = MLNShapeSource(identifier: "samt-rain", shape: shape, options: nil)
        style.addSource(src)
        let fill = MLNFillStyleLayer(identifier: "samt-rain-fill", source: src)
        fill.fillColor = NSExpression(format: "TERNARY(l == 1, %@, TERNARY(l == 2, %@, TERNARY(l == 3, %@, %@)))",
                                      RainScale.colorsUI[1], RainScale.colorsUI[2], RainScale.colorsUI[3], RainScale.colorsUI[4])
        fill.fillOpacity = NSExpression(forConstantValue: 0.45)
        insertBelowLabels([fill], in: style)
    }

    /// مربعات تغطية الشبكة (تعبئة ملونة حسب الحالة).
    @MainActor static func coverage(_ cells: [CoverageCell], on map: MLNMapView) {
        guard let style = map.style else { return }
        let polys: [MLNPolygonFeature] = cells.map { cell in
            var coords = cell.corners
            let f = MLNPolygonFeature(coordinates: &coords, count: UInt(coords.count))
            f.attributes = ["level": cell.level.rawValue]
            return f
        }
        let shape = MLNShapeCollectionFeature(shapes: polys)
        if let src = style.source(withIdentifier: "samt-coverage") as? MLNShapeSource {
            src.shape = shape
            return
        }
        let src = MLNShapeSource(identifier: "samt-coverage", shape: shape, options: nil)
        style.addSource(src)
        let fill = MLNFillStyleLayer(identifier: "samt-coverage-fill", source: src)
        fill.fillColor = NSExpression(format: "TERNARY(level == 'data', %@, TERNARY(level == 'voice', %@, %@))",
                                      CoverageLevel.data.uiColor, CoverageLevel.voice.uiColor, CoverageLevel.none.uiColor)
        fill.fillOpacity = NSExpression(forConstantValue: 0.32)
        fill.fillOutlineColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.25))
        insertBelowLabels([fill], in: style)
    }

    /// إبراز الطرق الترابية والردميات الموجودة في بيانات النمط نفسه (طبقة transportation: class=track أو surface=unpaved).
    @MainActor static func highlightStyleDirt(on map: MLNMapView, visible: Bool) {
        guard let style = map.style else { return }
        if let line = style.layer(withIdentifier: "samt-dirt-roads"), let casing = style.layer(withIdentifier: "samt-dirt-roads-casing") {
            line.isVisible = visible
            casing.isVisible = visible
            return
        }
        guard visible else { return }
        let vectorSources = style.sources.compactMap { $0 as? MLNVectorTileSource }
        guard let source = vectorSources.first(where: { $0.identifier == "openmaptiles" }) ?? vectorSources.first else { return }
        let casing = MLNLineStyleLayer(identifier: "samt-dirt-roads-casing", source: source)
        casing.sourceLayerIdentifier = "transportation"
        casing.predicate = NSPredicate(format: "%K == %@ OR %K == %@", "class", "track", "surface", "unpaved")
        casing.lineColor = NSExpression(forConstantValue: UIColor.white.withAlphaComponent(0.9))
        casing.lineWidth = NSExpression(forConstantValue: 5.5)
        casing.minimumZoomLevel = 9
        let line = MLNLineStyleLayer(identifier: "samt-dirt-roads", source: source)
        line.sourceLayerIdentifier = "transportation"
        line.predicate = casing.predicate
        line.lineColor = NSExpression(forConstantValue: DirtRoadStyle.confirmedUI)
        line.lineWidth = NSExpression(forConstantValue: 3)
        line.lineDashPattern = NSExpression(forConstantValue: [2.2, 1.2])
        line.minimumZoomLevel = 9
        insertBelowLabels([casing, line], in: style)
    }

    /// تحت الأسماء: قبل أول طبقة رموز إن وجدت.
    @MainActor private static func insertBelowLabels(_ layers: [MLNStyleLayer], in style: MLNStyle) {
        if let firstSymbol = style.layers.first(where: { $0 is MLNSymbolStyleLayer }) {
            for l in layers { style.insertLayer(l, below: firstSymbol) }
        } else {
            for l in layers { style.addLayer(l) }
        }
    }
}

// MARK: - MapKit (UIKit) — تستخدمه CarPlay

/// خطوط بيانات مجمعة في عنصر واحد (أداء أفضل من آلاف العناصر المنفصلة).
final class DataMKMultiPolyline: MKMultiPolyline {
    enum Role { case dirtCasing, dirt, detectedCasing, detected }
    var role: Role = .dirt
}

/// مضلعات بيانات مجمعة بلون تعبئة واحد.
final class DataMKMultiPolygon: MKMultiPolygon {
    var fill: UIColor = .clear
    var stroke: UIColor?
}

enum MapKitDataLayers {
    /// يستبدل طبقات البيانات على الخريطة. تُضاف تحت خطوط الملاحة والمسارات.
    @MainActor static func apply(dirt: [DirtRoad], coverage: [CoverageCell], rain: [RainCell], rainHour: Int, to m: MKMapView) {
        m.removeOverlays(m.overlays.filter { $0 is DataMKMultiPolyline || $0 is DataMKMultiPolygon })
        var bottomToTop: [MKOverlay] = []

        // التغطية: لون لكل حالة
        for level in [CoverageLevel.none, .voice, .data] {
            let polys = coverage.filter { $0.level == level }.map { MKPolygon(coordinates: $0.corners, count: 4) }
            guard !polys.isEmpty else { continue }
            let mp = DataMKMultiPolygon(polys)
            mp.fill = level.uiColor.withAlphaComponent(0.32)
            mp.stroke = UIColor.black.withAlphaComponent(0.2)
            bottomToTop.append(mp)
        }
        // الأمطار: لون لكل شدة
        for l in 1...4 {
            let polys = rain.filter {
                RainScale.level($0.hourly.indices.contains(rainHour) ? $0.hourly[rainHour] : 0) == l
            }.map { MKPolygon(coordinates: $0.corners, count: 4) }
            guard !polys.isEmpty else { continue }
            let mp = DataMKMultiPolygon(polys)
            mp.fill = RainScale.colorsUI[l].withAlphaComponent(0.45)
            bottomToTop.append(mp)
        }
        // الردميات: إطار ثم خط، والمرصودة فوق المؤكدة بلون مختلف
        let confirmed = dirt.filter { $0.kind != .detected && $0.coordinates.count > 1 }
            .map { MKPolyline(coordinates: $0.coordinates, count: $0.coordinates.count) }
        let detected = dirt.filter { $0.kind == .detected && $0.coordinates.count > 1 }
            .map { MKPolyline(coordinates: $0.coordinates, count: $0.coordinates.count) }
        if !detected.isEmpty {
            let c = DataMKMultiPolyline(detected); c.role = .detectedCasing; bottomToTop.append(c)
            let l = DataMKMultiPolyline(detected); l.role = .detected; bottomToTop.append(l)
        }
        if !confirmed.isEmpty {
            let c = DataMKMultiPolyline(confirmed); c.role = .dirtCasing; bottomToTop.append(c)
            let l = DataMKMultiPolyline(confirmed); l.role = .dirt; bottomToTop.append(l)
        }
        // الإدراج في أسفل المستوى بترتيب عكسي حتى تبقى خطوط الملاحة فوقها
        for o in bottomToTop.reversed() { m.insertOverlay(o, at: 0, level: .aboveRoads) }
    }

    @MainActor static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
        if let p = overlay as? DataMKMultiPolyline {
            let r = MKMultiPolylineRenderer(multiPolyline: p)
            r.lineCap = .round
            r.lineJoin = .round
            switch p.role {
            case .dirtCasing:
                r.strokeColor = UIColor.white.withAlphaComponent(0.9); r.lineWidth = 6
            case .dirt:
                r.strokeColor = DirtRoadStyle.confirmedUI; r.lineWidth = 3.5; r.lineDashPattern = [8, 4]
            case .detectedCasing:
                r.strokeColor = UIColor.black.withAlphaComponent(0.45); r.lineWidth = 4.5
            case .detected:
                r.strokeColor = DirtRoadStyle.detectedUI; r.lineWidth = 2.5; r.lineDashPattern = [3, 4]
            }
            return r
        }
        if let p = overlay as? DataMKMultiPolygon {
            let r = MKMultiPolygonRenderer(multiPolygon: p)
            r.fillColor = p.fill
            if let s = p.stroke { r.strokeColor = s; r.lineWidth = 0.6 }
            return r
        }
        return nil
    }
}
