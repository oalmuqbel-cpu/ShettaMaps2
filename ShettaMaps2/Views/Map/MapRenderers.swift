import UIKit
import MapKit
import MapLibre

// MARK: - MapLibre

final class TaggedPolyline: MLNPolyline {
    var kind: MapOverlaySet.LineKind = .track
}

final class TaggedPointAnnotation: MLNPointAnnotation {
    var kind: MapOverlaySet.PinKind = .saved
    var pinID: String = ""
}

/// يرسم MapOverlaySet على MLNMapView ويحدّثه فقط عند التغيّر.
enum MapLibreOverlayRenderer {
    @MainActor static func apply(_ set: MapOverlaySet, to mapView: MLNMapView) {
        if let existing = mapView.annotations, !existing.isEmpty {
            mapView.removeAnnotations(existing)
        }
        var items: [MLNAnnotation] = []
        for line in set.lines where line.coordinates.count > 1 {
            let coords = line.coordinates
            let count = UInt(coords.count)
            let poly = TaggedPolyline(coordinates: coords, count: count)
            poly.kind = line.kind
            items.append(poly)
        }
        for pin in set.pins {
            let a = TaggedPointAnnotation()
            a.coordinate = pin.coordinate
            a.title = pin.title
            a.subtitle = pin.subtitle
            a.kind = pin.kind
            a.pinID = pin.id
            items.append(a)
        }
        mapView.addAnnotations(items)
    }

    static func strokeColor(for annotation: MLNShape) -> UIColor {
        guard let p = annotation as? TaggedPolyline else { return Theme.trackUI }
        return color(for: p.kind)
    }

    static func lineWidth(for annotation: MLNShape) -> CGFloat {
        guard let p = annotation as? TaggedPolyline else { return 4 }
        return width(for: p.kind)
    }

    /// صورة العلامة: دائرة ملونة حسب النوع.
    @MainActor static func image(for annotation: MLNAnnotation, mapView: MLNMapView) -> MLNAnnotationImage? {
        guard let a = annotation as? TaggedPointAnnotation else { return nil }
        let reuse = "pin-\(a.kind)"
        if let cached = mapView.dequeueReusableAnnotationImage(withIdentifier: reuse) { return cached }
        let img = PinImageFactory.image(kind: a.kind)
        return MLNAnnotationImage(image: img, reuseIdentifier: reuse)
    }
}

// MARK: - MapKit (UIKit) — تستخدمه CarPlay

final class TaggedMKPolyline: MKPolyline {
    var kind: MapOverlaySet.LineKind = .track
}

final class TaggedMKAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let kind: MapOverlaySet.PinKind
    init(pin: MapOverlaySet.Pin) {
        coordinate = pin.coordinate; title = pin.title; subtitle = pin.subtitle; kind = pin.kind
    }
}

enum MapKitOverlayRenderer {
    @MainActor static func apply(_ set: MapOverlaySet, to mapView: MKMapView) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        for line in set.lines where line.coordinates.count > 1 {
            let coords = line.coordinates
            let count = coords.count
            let poly = TaggedMKPolyline(coordinates: coords, count: count)
            poly.kind = line.kind
            mapView.addOverlay(poly, level: .aboveRoads)
        }
        mapView.addAnnotations(set.pins.map(TaggedMKAnnotation.init))
    }

    @MainActor static func renderer(for overlay: MKOverlay) -> MKOverlayRenderer {
        guard let p = overlay as? TaggedMKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let r = MKPolylineRenderer(polyline: p)
        r.strokeColor = color(for: p.kind)
        r.lineWidth = width(for: p.kind)
        if p.kind == .direct { r.lineDashPattern = [10, 8] }
        r.lineCap = .round
        return r
    }

    @MainActor static func view(for annotation: MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        guard let a = annotation as? TaggedMKAnnotation else { return nil }
        let id = "pin-\(a.kind)"
        let v = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
            ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: id)
        v.annotation = a
        v.markerTintColor = PinImageFactory.color(kind: a.kind)
        v.glyphImage = UIImage(systemName: PinImageFactory.symbol(kind: a.kind))
        v.displayPriority = a.kind == .destination ? .required : .defaultHigh
        v.canShowCallout = true
        return v
    }
}

// MARK: - مشترك

private func color(for kind: MapOverlaySet.LineKind) -> UIColor {
    switch kind {
    case .track: return Theme.trackUI
    case .importedTrack: return UIColor.systemPurple
    case .direct: return Theme.directLineUI
    case .road: return Theme.routeUI
    }
}

private func width(for kind: MapOverlaySet.LineKind) -> CGFloat {
    switch kind {
    case .road: return 7
    case .direct: return 3
    case .track, .importedTrack: return 4
    }
}

enum PinImageFactory {
    static func color(kind: MapOverlaySet.PinKind) -> UIColor {
        switch kind {
        case .saved: return Theme.desertOrangeUI
        case .destination: return UIColor.systemRed
        case .waypoint: return Theme.directLineUI
        case .picked: return UIColor.systemPink
        case .start: return UIColor.systemGreen
        case .search: return Theme.brownUI
        }
    }

    static func symbol(kind: MapOverlaySet.PinKind) -> String {
        switch kind {
        case .saved: return "mappin"
        case .destination: return "flag.checkered"
        case .waypoint: return "smallcircle.filled.circle"
        case .picked: return "scope"
        case .start: return "house"
        case .search: return "magnifyingglass"
        }
    }

    @MainActor static func image(kind: MapOverlaySet.PinKind) -> UIImage {
        let size = CGSize(width: 30, height: 30)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            color(kind: kind).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: rect)
            ring.lineWidth = 2.5
            ring.stroke()
            if let glyph = UIImage(systemName: symbol(kind: kind),
                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let g = glyph.size
                glyph.draw(in: CGRect(x: (size.width - g.width) / 2, y: (size.height - g.height) / 2, width: g.width, height: g.height))
            }
        }
    }
}
