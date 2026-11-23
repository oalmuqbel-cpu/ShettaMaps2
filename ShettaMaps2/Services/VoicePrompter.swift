import Foundation
import AVFoundation
import AudioToolbox

/// تعليمات صوتية بالعربية وفق متطلبات Apple لتطبيقات الملاحة في CarPlay:
/// جلسة صوت للتشغيل بنمط «تعليمات صوتية»، تخفض صوت الراديو مؤقتًا، تُفعَّل فقط أثناء الكلام،
/// وتحترم إعداد السيارة (promptStyle): بلا صوت، نغمة قصيرة، أو كلام كامل.
@MainActor
final class VoicePrompter: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = VoicePrompter()
    static let enabledKey = "voiceGuidance"

    /// كل عمليات محرك الكلام على طابور خلفي: تحميل الصوت العربي (AVSpeechSynthesisVoice) قد يعلّق
    /// الخيط الرئيسي ثواني أو أكثر، فكان يجمّد الشاشة لحظة بدء الملاحة.
    private let worker = SpeechWorker()
    private var lastText = ""
    private var lastAt = Date.distantPast

    private override init() {
        super.init()
        worker.setDelegate(self)
        worker.prewarm()
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// يقرأ نصًا قصيرًا. tone: نغمة تنبيه قبل الكلام (أو بدله إن كان إعداد السيارة «قصير»).
    func speak(_ text: String, tone: Bool = false) {
        // منع تكرار الجملة نفسها خلال ثوانٍ
        if text == lastText, Date().timeIntervalSince(lastAt) < 8 { return }
        lastText = text
        lastAt = Date()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
        } catch { return }

        switch session.promptStyle {
        case .none:
            return
        case .short:
            playTone()
            return
        default:
            break
        }
        do { try session.setActive(true) } catch { return }
        if tone { AudioServicesPlaySystemSound(1315) }
        worker.speak(text)
    }

    /// إيقاف الكلام فورًا (عند كتم التعليمات من الشاشة).
    func stop() {
        worker.stop()
        lastText = ""
    }

    private func playTone() {
        AudioServicesPlaySystemSound(1315)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivate() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.deactivate() }
    }

    /// لا نبقي الجلسة نشطة بعد انتهاء الكلام حتى يعود صوت الراديو فورًا.
    private func deactivate() {
        worker.whenIdle {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// يشغّل محرك الكلام على طابور تسلسلي خاص بعيدًا عن الخيط الرئيسي.
final class SpeechWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "samt.voice", qos: .userInitiated)
    private var synth: AVSpeechSynthesizer?
    private var voice: AVSpeechSynthesisVoice?
    private var voiceLoaded = false
    private weak var delegate: AVSpeechSynthesizerDelegate?

    func setDelegate(_ d: AVSpeechSynthesizerDelegate) { queue.async { self.delegate = d; self.synth?.delegate = d } }

    /// تحميل الصوت مسبقًا حتى تكون أول تعليمة فورية.
    func prewarm() { queue.async { _ = self.ensureReady() } }

    func speak(_ text: String) {
        queue.async {
            let s = self.ensureReady()
            if s.isSpeaking { s.stopSpeaking(at: .word) }
            let u = AVSpeechUtterance(string: text)
            u.voice = self.voice
            u.rate = AVSpeechUtteranceDefaultSpeechRate
            s.speak(u)
        }
    }

    func stop() {
        queue.async { if self.synth?.isSpeaking == true { self.synth?.stopSpeaking(at: .immediate) } }
    }

    func whenIdle(_ action: @escaping @Sendable () -> Void) {
        queue.async { if self.synth?.isSpeaking != true { action() } }
    }

    private func ensureReady() -> AVSpeechSynthesizer {
        if !voiceLoaded {
            voice = AVSpeechSynthesisVoice(language: "ar-SA") ?? AVSpeechSynthesisVoice(language: "ar")
            voiceLoaded = true
        }
        if let s = synth { return s }
        let s = AVSpeechSynthesizer()
        s.delegate = delegate
        synth = s
        return s
    }
}

/// نصوص التعليمات الصوتية (قابلة للاختبار).
enum VoicePhrases {
    /// المسافة بصيغة منطوقة مقرّبة: «٨٠٠ متر»، «كيلومتر ونصف»، «٣ كيلومترات».
    static func distance(_ m: Double) -> String {
        if m < 1000 {
            let r = m < 100 ? (m / 10).rounded() * 10 : (m / 50).rounded() * 50
            return "\(Int(max(10, r))) متر"
        }
        let km = (m / 100).rounded() / 10
        if km == 1 { return "كيلومتر" }
        if km == 1.5 { return "كيلومتر ونصف" }
        if km == 2 { return "كيلومترين" }
        if km < 10 {
            let s = km == km.rounded() ? "\(Int(km))" : String(format: "%.1f", km)
            return "\(s) " + ((km >= 3 && km <= 10 && km == km.rounded()) ? "كيلومترات" : "كيلومتر")
        }
        return "\(Int(km.rounded())) كيلومتر"
    }

    static func ahead(_ m: Double, _ instruction: String) -> String { "بعد \(distance(m))، \(instruction)" }
    static func start(_ name: String, _ m: Double) -> String { "بدأت الملاحة إلى \(name). المسافة \(distance(m))" }
    static func arrived(_ name: String) -> String { "وصلت إلى \(name)" }
}
