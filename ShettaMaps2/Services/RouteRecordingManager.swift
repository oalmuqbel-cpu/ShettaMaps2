import Foundation
import SwiftData
import CoreLocation
import Combine

enum RecordingState: Equatable {
    case idle, recording, paused
    var title: String {
        switch self {
        case .idle: return "متوقف"
        case .recording: return "جارٍ التسجيل"
        case .paused: return "متوقف مؤقتًا"
        }
    }
}

/// يسجّل المسار عبر GPS ويحفظه تدريجيًا في SwiftData حتى لا يضيع عند إغلاق التطبيق.
@MainActor
final class RouteRecordingManager: ObservableObject {
    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var distance: Double = 0
    @Published private(set) var movingSeconds: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentSpeed: Double?
    @Published private(set) var maxSpeed: Double = 0
    /// المقاطع الحالية للعرض على الخريطة (الآيفون وCarPlay).
    @Published private(set) var liveSegments: [[CLLocationCoordinate2D]] = []
    @Published private(set) var recoveredNotice: String?
    @Published private(set) var lastRejection: TrackAccumulator.Rejection?
    /// إيقاف تلقائي بسبب الوقوف؛ يُستأنف التسجيل تلقائيًا عند الحركة.
    @Published private(set) var isAutoPaused = false

    /// مسافة الحركة التي تُعد خروجًا من مكان الوقوف، ومدة الوقوف قبل الإيقاف التلقائي.
    static let stationaryRadius: Double = 35
    static let resumeRadius: Double = 60
    private var anchor: CLLocation?
    private var lastMoveTime = Date()
    var autoPauseSeconds: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: SettingsKeys.autoPauseMinutes) as? Double ?? 15
        return minutes * 60
    }

    private(set) var currentTrack: RecordedTrack?
    private var accumulator = TrackAccumulator()
    private let context: ModelContext
    private let location: LocationManager
    private var subscription: AnyCancellable?
    private var timer: Timer?
    private var startedAt: Date?
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    private var unsavedCount = 0
    private var lastCheckpoint = Date()
    private static let backgroundReason = "recording"

    init(context: ModelContext, location: LocationManager) {
        self.context = context
        self.location = location
    }

    var isActive: Bool { state != .idle }

    // MARK: - التحكم

    @discardableResult
    func start(name: String? = nil, trip: Trip? = nil) -> RecordedTrack? {
        guard state == .idle else { return currentTrack }
        let title = name ?? "مسار \(Fmt.dateTime.string(from: Date()))"
        let track = RecordedTrack(name: title)
        track.trip = trip
        context.insert(track)
        try? context.save()

        currentTrack = track
        accumulator = TrackAccumulator()
        startedAt = Date()
        pausedTotal = 0
        pausedAt = nil
        resetPublished()
        state = .recording
        anchor = location.location
        lastMoveTime = Date()
        isAutoPaused = false

        location.requestAlwaysIfNeeded()
        location.requestFullAccuracyIfNeeded()
        location.beginBackgroundUpdates(reason: Self.backgroundReason)
        subscribe()
        startTimer()
        if let loc = location.location { ingest(loc) }
        return track
    }

    func pause() {
        guard state == .recording else { return }
        isAutoPaused = false
        state = .paused
        pausedAt = Date()
        accumulator.markPaused()
        checkpoint(force: true)
    }

    func resume() {
        guard state == .paused else { return }
        if let p = pausedAt { pausedTotal += Date().timeIntervalSince(p) }
        pausedAt = nil
        isAutoPaused = false
        lastMoveTime = Date()
        anchor = location.location
        state = .recording
    }

    /// يوقف التسجيل تلقائيًا بعد الوقوف مدة محددة، بلا نقاط ولا وقت إضافي حتى تتحرك.
    private func autoPauseIfStationary(now: Date = Date()) {
        guard state == .recording, autoPauseSeconds > 0, now.timeIntervalSince(lastMoveTime) >= autoPauseSeconds else { return }
        state = .paused
        isAutoPaused = true
        pausedAt = now
        accumulator.markPaused()
        checkpoint(force: true)
    }

    /// ينهي التسجيل ويحفظ المسار. يحذف المسار إن كان أقل من نقطتين.
    @discardableResult
    func finish() -> RecordedTrack? {
        guard state != .idle, let track = currentTrack else { return nil }
        if state == .paused, let p = pausedAt { pausedTotal += Date().timeIntervalSince(p) }
        writeStats(to: track)
        track.endedAt = Date()
        track.isComplete = true
        let keep = accumulator.points.count >= 2
        if !keep { context.delete(track) }
        try? context.save()
        teardown()
        return keep ? track : nil
    }

    func discard() {
        guard let track = currentTrack else { return }
        context.delete(track)
        try? context.save()
        teardown()
    }

    func clearRecoveredNotice() { recoveredNotice = nil }

    // MARK: - داخلي

    private func subscribe() {
        subscription = location.locationPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] loc in self?.ingest(loc) }
    }

    private func ingest(_ loc: CLLocation) {
        currentSpeed = loc.speed >= 0 ? loc.speed : nil
        let accurate = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= 50
        if state == .paused, isAutoPaused {
            // استئناف تلقائي عند الابتعاد عن مكان الوقوف
            if accurate, let a = anchor, loc.distance(from: a) > Self.resumeRadius { resume() } else { return }
        }
        guard state == .recording else { return }
        if accurate {
            if let a = anchor, loc.distance(from: a) <= Self.stationaryRadius {
                autoPauseIfStationary()
                if state != .recording { return }
            } else {
                anchor = loc
                lastMoveTime = Date()
            }
        }
        let point = TrackPoint(location: loc, segment: accumulator.segment)
        lastRejection = accumulator.append(point)
        guard lastRejection == nil else { return }
        distance = accumulator.distance
        movingSeconds = accumulator.movingSeconds
        maxSpeed = accumulator.maxSpeed
        liveSegments = accumulator.segments
        unsavedCount += 1
        checkpoint(force: false)
    }

    /// حفظ دوري: كل 20 نقطة أو كل دقيقة.
    private func checkpoint(force: Bool) {
        guard let track = currentTrack else { return }
        guard force || unsavedCount >= 20 || Date().timeIntervalSince(lastCheckpoint) > 60 else { return }
        writeStats(to: track)
        try? context.save()
        unsavedCount = 0
        lastCheckpoint = Date()
    }

    private func writeStats(to track: RecordedTrack) {
        track.points = accumulator.points
        track.distanceMeters = accumulator.distance
        track.movingSeconds = accumulator.movingSeconds
        track.maxSpeed = accumulator.maxSpeed
        track.elapsedSeconds = computeElapsed()
    }

    private func computeElapsed() -> TimeInterval {
        guard let s = startedAt else { return 0 }
        var paused = pausedTotal
        if let p = pausedAt { paused += Date().timeIntervalSince(p) }
        return max(0, Date().timeIntervalSince(s) - paused)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.elapsed = self?.computeElapsed() ?? 0
                self?.autoPauseIfStationary()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func resetPublished() {
        distance = 0; movingSeconds = 0; elapsed = 0; maxSpeed = 0
        liveSegments = []; lastRejection = nil; unsavedCount = 0
        lastCheckpoint = Date()
    }

    private func teardown() {
        subscription = nil
        timer?.invalidate(); timer = nil
        currentTrack = nil
        state = .idle
        startedAt = nil; pausedAt = nil; pausedTotal = 0
        isAutoPaused = false; anchor = nil
        liveSegments = []
        location.endBackgroundUpdates(reason: Self.backgroundReason)
    }

    /// يُغلق أي مسار بقي غير مكتمل بسبب إنهاء التطبيق، ويحتفظ بنقاطه.
    func recoverUnfinishedTrackIfNeeded() {
        let descriptor = FetchDescriptor<RecordedTrack>(predicate: #Predicate { $0.isComplete == false })
        guard let unfinished = try? context.fetch(descriptor), !unfinished.isEmpty else { return }
        var recovered = 0
        for track in unfinished {
            if track.pointCount >= 2 {
                track.isComplete = true
                track.endedAt = track.points.last?.time ?? Date()
                recovered += 1
            } else {
                context.delete(track)
            }
        }
        try? context.save()
        if recovered > 0 {
            recoveredNotice = "تمت استعادة \(recovered) مسار لم يكتمل حفظه بسبب إغلاق التطبيق."
        }
    }
}
