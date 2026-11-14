import Foundation
import SwiftUI
import MessageUI
import UserNotifications
import CoreLocation

/// نص رسالة الموقع (للطوارئ أو للمشاركة السريعة).
enum LocationMessage {
    static func text(for loc: CLLocation) -> String {
        let c = loc.coordinate
        let lat = String(format: "%.6f", c.latitude), lon = String(format: "%.6f", c.longitude)
        var parts = ["موقعي الحالي: \(lat), \(lon)",
                     "https://maps.apple.com/?ll=\(lat),\(lon)"]
        if loc.horizontalAccuracy >= 0 { parts.append("الدقة: ±\(Int(loc.horizontalAccuracy)) م") }
        parts.append("الوقت: \(Fmt.dateTime.string(from: loc.timestamp))")
        parts.append("أُرسل من تطبيق سَمْت")
        return parts.joined(separator: "\n")
    }
}

/// شاشة رسالة SMS جاهزة بالموقع. تعمل بإشارة الجوال دون إنترنت؛ والإرسال يتم بضغطة من المستخدم.
struct MessageComposer: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    @Environment(\.dismiss) private var dismiss

    static var canSend: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let parent: MessageComposer
        init(_ p: MessageComposer) { parent = p }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            parent.dismiss()
        }
    }
}

/// تنبيه قبل غروب الشمس أثناء الرحلة.
enum SunsetReminder {
    static let id = "samt.sunset"

    static func schedule(at c: CLLocationCoordinate2D, minutesBefore: Double = 45) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let sunset = SunCalculator.time(.sunset, on: Date(), at: c) else { return }
        let fire = sunset.addingTimeInterval(-minutesBefore * 60)
        guard fire > Date().addingTimeInterval(60) else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "اقترب غروب الشمس"
            content.body = "الغروب الساعة \(Fmt.time.string(from: sunset)). إن كنت ستعود، فابدأ الآن قبل الظلام."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    static func cancel() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id]) }
}
