import Foundation
import CoreLocation

/// منطق شاشة إدخال الإحداثيات: التحليل الحي والتحويل بين الصيغ والإدخال المجزأ بالدرجات والدقائق والثواني.
@MainActor
final class CoordinateInputViewModel: ObservableObject {
    enum InputMode: String, CaseIterable, Identifiable {
        case freeText, dms
        var id: String { rawValue }
        var title: String { self == .freeText ? "نص حر" : "درجات ودقائق وثوانٍ" }
    }

    @Published var mode: InputMode = .freeText
    @Published var text = "" { didSet { parseText() } }

    // الإدخال المجزأ
    @Published var latDeg = "" { didSet { parseDMS() } }
    @Published var latMin = "" { didSet { parseDMS() } }
    @Published var latSec = "" { didSet { parseDMS() } }
    @Published var latNorth = true { didSet { parseDMS() } }
    @Published var lonDeg = "" { didSet { parseDMS() } }
    @Published var lonMin = "" { didSet { parseDMS() } }
    @Published var lonSec = "" { didSet { parseDMS() } }
    @Published var lonEast = true { didSet { parseDMS() } }

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var errorMessage: String?

    func reset() {
        text = ""; coordinate = nil; errorMessage = nil
    }

    private func parseText() {
        guard mode == .freeText else { return }
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { coordinate = nil; errorMessage = nil; return }
        do {
            coordinate = try CoordinateUtilities.parse(text)
            errorMessage = nil
        } catch {
            coordinate = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
        }
    }

    private func parseDMS() {
        guard mode == .dms else { return }
        func num(_ s: String) -> Double? { Double(CoordinateUtilities.normalize(s.isEmpty ? "0" : s)) }
        guard let ld = num(latDeg), let lm = num(latMin), let ls = num(latSec),
              let od = num(lonDeg), let om = num(lonMin), let os = num(lonSec),
              !latDeg.isEmpty, !lonDeg.isEmpty else {
            coordinate = nil
            errorMessage = latDeg.isEmpty && lonDeg.isEmpty ? nil : "أكمل الحقول بأرقام صحيحة."
            return
        }
        guard lm < 60, ls < 60, om < 60, os < 60, ld >= 0, od >= 0, lm >= 0, ls >= 0, om >= 0, os >= 0 else {
            coordinate = nil; errorMessage = CoordinateParseError.minutesOrSecondsOutOfRange.errorDescription; return
        }
        let lat = (ld + lm / 60 + ls / 3600) * (latNorth ? 1 : -1)
        let lon = (od + om / 60 + os / 3600) * (lonEast ? 1 : -1)
        guard (-90...90).contains(lat) else { coordinate = nil; errorMessage = CoordinateParseError.latitudeOutOfRange.errorDescription; return }
        guard (-180...180).contains(lon) else { coordinate = nil; errorMessage = CoordinateParseError.longitudeOutOfRange.errorDescription; return }
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        errorMessage = nil
    }

    /// يملأ الحقول المجزأة من إحداثية (للتحويل العكسي).
    func fill(from c: CLLocationCoordinate2D) {
        let la = CoordinateUtilities.toDMS(c.latitude), lo = CoordinateUtilities.toDMS(c.longitude)
        mode = .dms
        latDeg = "\(la.degrees)"; latMin = "\(la.minutes)"; latSec = String(format: "%.2f", la.seconds); latNorth = !la.isNegative
        lonDeg = "\(lo.degrees)"; lonMin = "\(lo.minutes)"; lonSec = String(format: "%.2f", lo.seconds); lonEast = !lo.isNegative
    }

    func switchMode(_ m: InputMode) {
        let current = coordinate
        mode = m
        if let current {
            if m == .dms { fill(from: current) } else { text = CoordinateUtilities.shareString(current) }
        }
    }
}
