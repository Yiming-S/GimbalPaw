import Combine
import Foundation

enum PersonTrackingState: Equatable {
    case off
    case awaitingSelection(Int)
    case acquiring
    case locked
    case correcting
    case centered
    case lossGrace
    case coasting(PersonSearchDirection)
    case searching(PersonSearchDirection)
    case scanning(PersonSearchDirection)
    case reacquiring
    case searchPaused(String)
    case motionPaused(String)
    case unavailable(String)

    var title: String {
        switch self {
        case .off: return "人物跟踪已关闭"
        case let .awaitingSelection(count):
            return count == 0 ? "正在识别画面人物" : "检测到 \(count) 人，请选择目标"
        case .acquiring: return "正在稳定锁定人物"
        case .locked: return "人物已锁定"
        case .correcting: return "正在自动校正构图"
        case .centered: return "人物位于中心死区"
        case .lossGrace: return "人物暂时出框，正在确认方向"
        case let .coasting(direction): return "\(direction.title)惯性寻找"
        case let .searching(direction): return "\(direction.title)继续寻找"
        case let .scanning(direction): return "自动扫描：\(direction.title)"
        case .reacquiring: return "发现候选，正在稳定重锁"
        case let .searchPaused(reason): return "扫描已暂停：\(reason)"
        case let .motionPaused(reason): return "运动已暂停：\(reason)"
        case let .unavailable(reason): return reason
        }
    }
}

private enum PersonTrackingPhase: Equatable {
    case off
    case awaitingSelection
    case acquiring
    case following
    case lossGrace
    case coasting
    case searching
    case reacquiring(settleUntilUptime: TimeInterval)
    case searchPaused
    case motionPaused

    var carriesLockedTarget: Bool {
        switch self {
        case .following, .lossGrace, .coasting:
            return true
        default:
            return false
        }
    }
}

private struct HorizontalObservation {
    let centerX: Double
    let confidence: Float
}

@MainActor
final class PersonTrackingCoordinator: ObservableObject {
    private static let speedModeDefaultsKey = "personTracking.speedMode"
    private static let reacquisitionFrames = 5
    private static let reacquisitionDuration: TimeInterval = 0.40
    private static let reacquisitionMinimumConfidence: Float = 0.65
    private static let reacquisitionMaximumCenterShift = 0.05

    @Published private(set) var enabled = false
    @Published private(set) var canEnable = false
    @Published private(set) var speedMode: PersonTrackingSpeedMode = .fast

    // These change on the ~12.5 Hz vision cadence, and @Published fires
    // objectWillChange on every assignment even when the value is identical.
    // Manual willSet publication only wakes observers on real changes.
    private(set) var state: PersonTrackingState = .off {
        willSet { if newValue != state { objectWillChange.send() } }
    }
    private(set) var canResumeSearch = false {
        willSet { if newValue != canResumeSearch { objectWillChange.send() } }
    }
    private(set) var visiblePeople: [PersonCandidate] = [] {
        willSet { if newValue != visiblePeople { objectWillChange.send() } }
    }
    private(set) var selectedPersonID: PersonCandidateID? {
        willSet { if newValue != selectedPersonID { objectWillChange.send() } }
    }
    private(set) var selectedPersonDetection: PersonDetection? {
        willSet { if newValue != selectedPersonDetection { objectWillChange.send() } }
    }
    private(set) var hasAnalyzedPeopleFrame = false {
        willSet { if newValue != hasAnalyzedPeopleFrame { objectWillChange.send() } }
    }

    var canChangePersonSelection: Bool {
        enabled && phase != .motionPaused
    }

    private let bluetooth: any PersonTrackingBluetoothControlling
    private let camera: any PersonTrackingCameraControlling
    private var cancellables: Set<AnyCancellable> = []
    private var watchdogTask: Task<Void, Never>?
    private var pendingCorrectionRetryTask: Task<Void, Never>?
    private var coastTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var activeSpeedMode: PersonTrackingSpeedMode?
    private var activeVisionSessionID: UUID?
    private var safetyArmed = false
    private var appActive = true
    private var phase: PersonTrackingPhase = .off
    private var motionGeneration: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var lastVisionSampleAtUptime: TimeInterval = 0
    private var lastValidAtUptime: TimeInterval = 0
    private var consecutiveValidDetections = 0
    private var consecutiveMisses = 0
    private var acquisitionStartedAtUptime: TimeInterval?
    private var lastAcquisitionDetection: PersonDetection?
    private var reversalBlockedUntilUptime: TimeInterval = 0
    private var lastSubmittedCorrection: PersonTrackingCorrection?
    private var centerStopIssued = false
    private var recentHorizontalObservations: [HorizontalObservation] = []
    private var lastKnownYawDirection: PersonSearchDirection = .right
    private var searchDirection: PersonSearchDirection = .right
    private var searchHasReachedBoundary = false
    private var searchEpisodeStartedAtUptime: TimeInterval = 0
    private var searchEpisodeTravelTenths = 0
    private var searchBoundaryTouches = 0
    private var resumeSearchAfterCandidate = false
    private var reacquisitionCandidateID: PersonCandidateID?
    private var identityTracker = PersonIdentityTracker()
    private var smoothedSelectedDetection: PersonDetection?
    private var hasMadeInitialAutomaticSelection = false

    init(
        bluetooth: any PersonTrackingBluetoothControlling,
        camera: any PersonTrackingCameraControlling
    ) {
        self.bluetooth = bluetooth
        self.camera = camera
        let defaults = UserDefaults.standard
        if let storedObject = defaults.object(forKey: Self.speedModeDefaultsKey) {
            let rawValue = (storedObject as? NSNumber)?.intValue
            speedMode = rawValue.flatMap(PersonTrackingSpeedMode.init(rawValue:))
                ?? .standard
        } else {
            speedMode = .fast
        }

        bluetooth.statePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.recomputeAvailability()
                if self.enabled, !state.isReady {
                    self.disable(reason: "BLE 连接已失效", sendStop: false)
                }
            }
            .store(in: &cancellables)

        bluetooth.nudgeAvailablePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeAvailability() }
            .store(in: &cancellables)

        bluetooth.trackingOriginConfirmedPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeAvailability() }
            .store(in: &cancellables)

        bluetooth.personTrackingActivePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self else { return }
                if self.enabled, !active {
                    self.camera.setPersonTrackingEnabled(false)
                    self.enabled = false
                    self.sessionID = nil
                    self.activeSpeedMode = nil
                    self.watchdogTask?.cancel()
                    self.resetTargetState()
                    self.state = .unavailable("云台跟踪会话已停止")
                }
                self.recomputeAvailability()
            }
            .store(in: &cancellables)

        camera.statusPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.recomputeAvailability()
                if self.enabled, !status.isRunning {
                    self.disable(reason: "摄像头预览已停止", sendStop: true)
                }
            }
            .store(in: &cancellables)

        // Samples arrive as a direct main-thread callback: no Combine hop, no
        // run-loop-mode stalls, and no whole-object invalidation per frame.
        camera.onPersonSample = { [weak self] sample in
            self?.consume(sample)
        }
    }

    deinit {
        watchdogTask?.cancel()
        pendingCorrectionRetryTask?.cancel()
        coastTask?.cancel()
        searchTask?.cancel()
    }

    func setSafetyArmed(_ armed: Bool) {
        safetyArmed = armed
        recomputeAvailability()
        if enabled, !armed {
            disable(reason: "安全确认已关闭", sendStop: true)
        }
    }

    func setAppActive(_ active: Bool, sendStopOnDisable: Bool = true) {
        appActive = active
        recomputeAvailability()
        if enabled, !active {
            disable(reason: "应用转入后台", sendStop: sendStopOnDisable)
        }
    }

    func setEnabled(_ shouldEnable: Bool) {
        if shouldEnable {
            enable()
        } else {
            disable(reason: "人物跟踪已关闭", sendStop: true)
        }
    }

    func setSpeedMode(_ mode: PersonTrackingSpeedMode) {
        guard !enabled, !bluetooth.personTrackingActive else { return }
        speedMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.speedModeDefaultsKey)
    }

    func selectPerson(_ candidateID: PersonCandidateID) {
        guard enabled,
              let sessionID,
              phase != .motionPaused,
              candidateID != selectedPersonID,
              identityTracker.lock(on: candidateID)
        else { return }

        _ = beginNewMotionGeneration()
        bluetooth.pausePersonTrackingWithStop(
            session: sessionID,
            reason: "切换锁定人物 STOP"
        )
        hasMadeInitialAutomaticSelection = true
        prepareForTargetSelection()
        publishIdentitySnapshot(identityTracker.currentSnapshot)
    }

    func clearPersonSelection() {
        guard enabled,
              phase != .motionPaused,
              selectedPersonID != nil,
              let sessionID
        else { return }
        _ = beginNewMotionGeneration()
        bluetooth.pausePersonTrackingWithStop(
            session: sessionID,
            reason: "取消人物锁定 STOP"
        )
        identityTracker.clearLock()
        hasMadeInitialAutomaticSelection = true
        prepareForTargetSelection()
        publishIdentitySnapshot(identityTracker.currentSnapshot)
        phase = .awaitingSelection
        state = .awaitingSelection(visiblePeople.count)
    }

    func resumeSearch() {
        guard enabled, phase == .searchPaused, canResumeSearch else { return }
        beginSearchEpisode(resetEpisode: true)
    }

    func emergencyStop() {
        if enabled {
            disable(reason: "手动 STOP", sendStop: true)
        } else {
            bluetooth.stopMotion(reason: "手动 STOP")
        }
    }

    private func enable() {
        guard canEnable else {
            state = .unavailable("需先启动摄像头、连接 OM3 并完成安全确认")
            return
        }
        let sessionSpeedMode = speedMode
        guard let session = bluetooth.beginPersonTracking(speedMode: sessionSpeedMode) else {
            state = .unavailable("OM3 当前动作尚未结束")
            return
        }

        resetTargetState()
        sessionID = session
        activeSpeedMode = sessionSpeedMode
        enabled = true
        phase = .awaitingSelection
        state = .awaitingSelection(0)
        camera.setPersonTrackingEnabled(true)
        // The camera can refuse (e.g. motion calibration still holds the
        // analyzer). Without this check the UI would report tracking as on
        // while no sample ever arrives.
        guard camera.personTrackingEnabled else {
            disable(reason: "摄像头人物分析未能启动", sendStop: false)
            state = .unavailable("摄像头人物分析未能启动；请先结束全向验证或重启预览")
            return
        }
        startWatchdog()
        recomputeAvailability()
    }

    private func disable(reason: String, sendStop: Bool) {
        let session = sessionID
        let wasEnabled = enabled

        enabled = false
        camera.setPersonTrackingEnabled(false)
        sessionID = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        resetTargetState()

        if let session {
            bluetooth.endPersonTracking(
                session: session,
                reason: reason,
                sendStop: sendStop
            )
        }
        activeSpeedMode = nil
        if wasEnabled {
            state = .off
        }
        recomputeAvailability()
    }

    private func consume(_ sample: PersonVisionSample) {
        guard enabled,
              let sessionSpeedMode = activeSpeedMode,
              camera.isPersonTrackingSessionValid(sample.sessionID),
              sample.sequence > lastSequence
        else { return }
        lastSequence = sample.sequence
        activeVisionSessionID = sample.sessionID

        let now = ProcessInfo.processInfo.systemUptime
        // A sample that is too old to steer motion still proves the vision
        // pipeline is alive. Recording it before the freshness gate keeps the
        // scan stall detector from treating flowing-but-late frames as a
        // frozen camera and pausing every search episode at its first step.
        lastVisionSampleAtUptime = sample.observedAtUptime
        hasAnalyzedPeopleFrame = true
        guard now - sample.observedAtUptime <= sessionSpeedMode.maximumSampleAge else {
            return
        }

        // Tracker samples are position-only updates for the locked target;
        // identity, acquisition, and loss handling stay detector-driven.
        if sample.origin == .tracker {
            consumeTrackerSample(sample)
            return
        }

        var snapshot = identityTracker.update(
            detections: sample.detections,
            sequence: sample.sequence,
            observedAtUptime: sample.observedAtUptime
        )

        if snapshot.lockedID == nil,
           phase == .awaitingSelection,
           !hasMadeInitialAutomaticSelection,
           identityTracker.lockFirstVisibleCandidate() != nil {
            hasMadeInitialAutomaticSelection = true
            prepareForTargetSelection()
            snapshot = identityTracker.currentSnapshot
        }
        publishIdentitySnapshot(snapshot)

        guard snapshot.lockedID != nil else {
            phase = .awaitingSelection
            state = .awaitingSelection(snapshot.personCount)
            return
        }

        guard let rawDetection = snapshot.lockedDetection else {
            if identityTracker.hasUnresolvedRetiredLock,
               handleCandidateObservation(snapshot: snapshot, sample: sample) {
                return
            }
            let targetSample = PersonVisionSample(
                sessionID: sample.sessionID,
                detection: nil,
                sequence: sample.sequence,
                observedAtUptime: sample.observedAtUptime
            )
            handleMissingObservation(targetSample)
            return
        }

        let detection = smoothSelectedDetection(rawDetection)
        selectedPersonDetection = detection
        // Every detector-confirmed position re-anchors the correlation
        // tracker, so its intermediate updates cannot drift for more than one
        // detector period.
        camera.setPersonTrackingSeed(rawDetection)
        let targetSample = PersonVisionSample(
            sessionID: sample.sessionID,
            detections: sample.detections,
            selectedDetection: detection,
            sequence: sample.sequence,
            observedAtUptime: sample.observedAtUptime
        )
        handleValidObservation(detection, sample: targetSample)
    }

    /// Full-frame-rate position updates from the correlation tracker. Only
    /// steers the gimbal while the phase is already following and the detector
    /// confirmed the locked person within the bridge window; it never touches
    /// miss counters, loss timing, or identity state.
    private func consumeTrackerSample(_ sample: PersonVisionSample) {
        guard phase == .following,
              identityTracker.lockedID != nil,
              !identityTracker.hasUnresolvedRetiredLock,
              let rawDetection = sample.detections.first,
              lastValidAtUptime > 0,
              sample.observedAtUptime - lastValidAtUptime
                <= PersonTrackingPolicy.trackerBridgeMaximumGap
        else { return }

        let detection = smoothSelectedDetection(rawDetection)
        selectedPersonDetection = detection
        let targetSample = PersonVisionSample(
            sessionID: sample.sessionID,
            detections: sample.detections,
            selectedDetection: detection,
            sequence: sample.sequence,
            observedAtUptime: sample.observedAtUptime,
            origin: .tracker
        )
        processFollowingDetection(detection, sample: targetSample, isTrackerDriven: true)
    }

    private func handleMissingObservation(_ sample: PersonVisionSample) {
        pendingCorrectionRetryTask?.cancel()
        pendingCorrectionRetryTask = nil
        consecutiveMisses += 1
        let age = lastValidAtUptime > 0
            ? sample.observedAtUptime - lastValidAtUptime
            : 0

        switch phase {
        case .following:
            stopSupersededVisualMotionIfNeeded(
                reason: "人物首次出框 STOP",
                cooldownOverride: PersonSearchPolicy.lossGraceStopCooldown
            )
            phase = .lossGrace
            state = .lossGrace
        case .lossGrace:
            if consecutiveMisses >= 2,
               let direction = trustedCoastDirection(),
               age < PersonTrackingPolicy.lostTimeout {
                startCoasting(direction: direction)
            }
        case .coasting:
            break
        case .acquiring:
            resetAcquisitionCounters()
        case let .reacquiring(settleUntilUptime):
            guard sample.observedAtUptime >= settleUntilUptime else { return }
            resetAcquisitionCounters()
            if resumeSearchAfterCandidate {
                beginSearchEpisode(resetEpisode: searchEpisodeStartedAtUptime == 0)
            } else {
                phase = .searchPaused
                state = .searchPaused("候选消失，等待人物重新进入画面")
                canResumeSearch = true
            }
        case .awaitingSelection, .searching, .searchPaused, .motionPaused, .off:
            return
        }

        if phase.carriesLockedTarget, age >= PersonTrackingPolicy.lostTimeout {
            beginSearchEpisode(resetEpisode: true)
        }
    }

    private func handleValidObservation(
        _ detection: PersonDetection,
        sample: PersonVisionSample
    ) {
        let validObservationGap = lastValidAtUptime > 0
            ? sample.observedAtUptime - lastValidAtUptime
            : 0

        switch phase {
        case .coasting, .searching:
            beginReacquisition(
                with: sample,
                resumeSearchIfRejected: true,
                candidateID: identityTracker.lockedID
            )
            return
        case .searchPaused:
            beginReacquisition(
                with: sample,
                resumeSearchIfRejected: false,
                candidateID: identityTracker.lockedID
            )
            return
        case .awaitingSelection, .motionPaused, .off:
            return
        case let .reacquiring(settleUntilUptime):
            guard sample.observedAtUptime >= settleUntilUptime else { return }
            processAcquisition(detection, sample: sample, isReacquisition: true)
            return
        case .acquiring:
            processAcquisition(detection, sample: sample, isReacquisition: false)
            return
        case .following, .lossGrace:
            if validObservationGap >= PersonTrackingPolicy.lostTimeout {
                beginReacquisition(
                    with: sample,
                    resumeSearchIfRejected: true,
                    candidateID: identityTracker.lockedID
                )
                return
            }
            phase = .following
            processFollowingDetection(detection, sample: sample)
        }
    }

    /// Handles frames whose explicit lock can no longer be resolved while other
    /// candidates are visible. Policy: exactly one visible candidate is
    /// stabilized and then inherits the lock automatically; several visible
    /// candidates always stop automatic motion and wait for a manual choice.
    /// Returns false when the frame should fall through to the missing-target
    /// handling instead.
    private func handleCandidateObservation(
        snapshot: PersonIdentitySnapshot,
        sample: PersonVisionSample
    ) -> Bool {
        let candidates = snapshot.visibleCandidates
        guard !candidates.isEmpty else { return false }
        let onlyCandidate = candidates.count == 1 ? candidates[0] : nil

        switch phase {
        case .lossGrace, .coasting, .searching:
            if let onlyCandidate {
                beginReacquisition(
                    with: sample,
                    resumeSearchIfRejected: true,
                    candidateID: onlyCandidate.id
                )
            } else {
                pauseForManualSelection()
            }
            return true

        case .searchPaused:
            // Multiple candidates keep the pause as-is: the person buttons are
            // already visible and re-issuing a STOP every frame is pointless.
            guard let onlyCandidate else { return true }
            beginReacquisition(
                with: sample,
                resumeSearchIfRejected: false,
                candidateID: onlyCandidate.id
            )
            return true

        case let .reacquiring(settleUntilUptime):
            guard let onlyCandidate else {
                resetAcquisitionCounters()
                pauseForManualSelection()
                return true
            }
            if reacquisitionCandidateID != onlyCandidate.id {
                resetAcquisitionCounters()
                reacquisitionCandidateID = onlyCandidate.id
            }
            guard sample.observedAtUptime >= settleUntilUptime else { return true }
            processAcquisition(
                onlyCandidate.detection,
                sample: sample,
                isReacquisition: true
            )
            return true

        case .acquiring:
            // Nothing is moving during acquisition, so a retired lock can be
            // transferred in place; with several people visible the user must
            // choose again.
            if let onlyCandidate {
                if identityTracker.lock(on: onlyCandidate.id) {
                    resetAcquisitionCounters()
                    publishIdentitySnapshot(identityTracker.currentSnapshot)
                }
            } else {
                identityTracker.clearLock()
                publishIdentitySnapshot(identityTracker.currentSnapshot)
                phase = .awaitingSelection
                state = .awaitingSelection(candidates.count)
            }
            return true

        case .following, .awaitingSelection, .motionPaused, .off:
            return false
        }
    }

    private func pauseForManualSelection() {
        pauseAutomaticMotion(
            reason: "检测到多名人物，请点选跟踪目标",
            resumable: true
        )
    }

    private func processAcquisition(
        _ detection: PersonDetection,
        sample: PersonVisionSample,
        isReacquisition: Bool
    ) {
        if lastValidAtUptime > 0,
           sample.observedAtUptime - lastValidAtUptime
               >= PersonTrackingPolicy.lostTimeout {
            resetAcquisitionCounters()
        }
        if isReacquisition {
            let area = detection.width * detection.height
            guard detection.confidence >= Self.reacquisitionMinimumConfidence,
                  area >= 0.015
            else {
                resetAcquisitionCounters()
                state = .reacquiring
                return
            }
            if let previous = lastAcquisitionDetection,
               hypot(
                   detection.centerX - previous.centerX,
                   detection.centerY - previous.centerY
               ) > Self.reacquisitionMaximumCenterShift {
                consecutiveValidDetections = 0
                acquisitionStartedAtUptime = nil
            }
        }

        if consecutiveValidDetections == 0 {
            acquisitionStartedAtUptime = sample.observedAtUptime
        }
        consecutiveValidDetections += 1
        lastAcquisitionDetection = detection
        lastValidAtUptime = sample.observedAtUptime
        state = isReacquisition ? .reacquiring : .acquiring

        let requiredFrames = isReacquisition ? Self.reacquisitionFrames : 3
        let requiredDuration = isReacquisition
            ? Self.reacquisitionDuration
            : PersonTrackingPolicy.acquisitionMinimumDuration
        guard let acquisitionStartedAtUptime,
              consecutiveValidDetections >= requiredFrames,
              sample.observedAtUptime - acquisitionStartedAtUptime >= requiredDuration
        else { return }

        if isReacquisition,
           let candidateID = reacquisitionCandidateID,
           identityTracker.lockedID != candidateID {
            guard identityTracker.lock(on: candidateID) else {
                resetAcquisitionCounters()
                return
            }
            publishIdentitySnapshot(identityTracker.currentSnapshot)
        }
        reacquisitionCandidateID = nil
        phase = .following
        canResumeSearch = false
        resumeSearchAfterCandidate = false
        searchEpisodeStartedAtUptime = 0
        searchEpisodeTravelTenths = 0
        searchBoundaryTouches = 0
        searchHasReachedBoundary = false
        consecutiveMisses = 0
        reversalBlockedUntilUptime = 0
        lastSubmittedCorrection = nil
        recentHorizontalObservations.removeAll(keepingCapacity: true)
        state = .locked
        processFollowingDetection(detection, sample: sample)
    }

    private func processFollowingDetection(
        _ detection: PersonDetection,
        sample: PersonVisionSample,
        isTrackerDriven: Bool = false
    ) {
        guard let sessionID, let sessionSpeedMode = activeSpeedMode else { return }
        phase = .following
        if !isTrackerDriven {
            // Loss handling and coast-direction inference stay on the
            // detector cadence; tracker samples must not extend the perceived
            // validity of the target.
            consecutiveMisses = 0
            lastValidAtUptime = sample.observedAtUptime
            recordHorizontalObservation(detection)
        }

        guard let correction = PersonTrackingPolicy.correction(
            for: detection,
            speedMode: sessionSpeedMode
        ) else {
            pendingCorrectionRetryTask?.cancel()
            pendingCorrectionRetryTask = nil
            stopSupersededVisualMotionIfNeeded(reason: "人物进入中心死区 STOP")
            state = .centered
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now >= reversalBlockedUntilUptime else {
            state = .locked
            return
        }
        if let previous = lastSubmittedCorrection,
           reversesDirection(correction, comparedWith: previous) {
            reversalBlockedUntilUptime = now + PersonTrackingPolicy.reversalPauseDuration
            _ = beginNewMotionGeneration()
            bluetooth.pausePersonTrackingWithStop(
                session: sessionID,
                reason: "人物方向反转 STOP"
            )
            centerStopIssued = true
            lastSubmittedCorrection = nil
            state = .locked
            return
        }

        guard let commandResult = camera.withValidPersonTrackingSession(
            sample.sessionID,
            operation: {
                bluetooth.sendPersonTrackingCorrection(
                    correction,
                    observedAtUptime: sample.observedAtUptime,
                    session: sessionID
                )
            }
        ) else { return }

        switch commandResult {
        case let .submitted(submittedCorrection):
            acceptSubmittedCorrection(submittedCorrection)
        case .busy:
            if state != .correcting { state = .locked }
            scheduleRetry(
                correction: correction,
                sample: sample,
                sessionID: sessionID,
                speedMode: sessionSpeedMode
            )
        case .boundaryReached:
            pauseAutomaticMotion(
                reason: "已到当前安全包络边界；请关闭跟踪、人工回正并重新确认",
                resumable: false
            )
        case .safetyBudgetExhausted:
            pauseAutomaticMotion(
                reason: "已达到累计行程安全上限，请重新理线并重新启用跟踪",
                resumable: false
            )
        case .inactive, .failed:
            pauseAutomaticMotion(reason: "云台未接受跟踪修正", resumable: false)
        }
    }

    private func scheduleRetry(
        correction: PersonTrackingCorrection,
        sample: PersonVisionSample,
        sessionID: UUID,
        speedMode: PersonTrackingSpeedMode
    ) {
        pendingCorrectionRetryTask?.cancel()
        let expiresAtUptime = sample.observedAtUptime + speedMode.maximumSampleAge
        let generation = motionGeneration
        pendingCorrectionRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    return
                }
                guard let self,
                      self.enabled,
                      self.phase == .following,
                      self.motionGeneration == generation,
                      self.sessionID == sessionID,
                      self.activeSpeedMode == speedMode,
                      self.camera.isPersonTrackingSessionValid(sample.sessionID),
                      ProcessInfo.processInfo.systemUptime <= expiresAtUptime
                else { return }

                guard let result = self.camera.withValidPersonTrackingSession(
                    sample.sessionID,
                    operation: {
                        self.bluetooth.sendPersonTrackingCorrection(
                            correction,
                            observedAtUptime: sample.observedAtUptime,
                            session: sessionID
                        )
                    }
                ) else { return }

                switch result {
                case let .submitted(submittedCorrection):
                    self.acceptSubmittedCorrection(submittedCorrection)
                    self.pendingCorrectionRetryTask = nil
                    return
                case .busy:
                    continue
                case .boundaryReached:
                    self.pauseAutomaticMotion(
                        reason: "已到当前安全包络边界；请关闭跟踪、人工回正并重新确认",
                        resumable: false
                    )
                    return
                case .safetyBudgetExhausted:
                    self.pauseAutomaticMotion(
                        reason: "已达到累计行程安全上限，请重新理线并重新启用跟踪",
                        resumable: false
                    )
                    return
                case .inactive, .failed:
                    self.pauseAutomaticMotion(reason: "云台未接受跟踪修正", resumable: false)
                    return
                }
            }
        }
    }

    private func acceptSubmittedCorrection(_ correction: PersonTrackingCorrection) {
        lastSubmittedCorrection = correction
        centerStopIssued = false
        if correction.yawTenths > 0 {
            lastKnownYawDirection = .right
        } else if correction.yawTenths < 0 {
            lastKnownYawDirection = .left
        }
        state = .correcting
    }

    private func startCoasting(direction: PersonSearchDirection) {
        guard enabled,
              phase == .lossGrace,
              let sessionID,
              let visionSessionID = activeVisionSessionID
        else { return }
        let generation = beginNewMotionGeneration()
        phase = .coasting
        searchDirection = direction
        state = .coasting(direction)
        var submittedTravelTenths = 0
        let deadline = lastValidAtUptime + PersonTrackingPolicy.lostTimeout

        coastTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.enabled,
                      self.phase == .coasting,
                      self.motionGeneration == generation,
                      self.sessionID == sessionID,
                      self.camera.isPersonTrackingSessionValid(visionSessionID)
                else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let coastDuration = Double(PersonSearchPolicy.coastDurationTenths) / 10.0
                if now + coastDuration > deadline {
                    self.beginSearchEpisode(resetEpisode: true)
                    return
                }
                if submittedTravelTenths >= PersonSearchPolicy.maximumCoastTravelTenths {
                    do {
                        try await Task.sleep(nanoseconds: 20_000_000)
                    } catch {
                        return
                    }
                    continue
                }

                guard let result = self.camera.withValidPersonTrackingSession(
                    visionSessionID,
                    operation: {
                        self.bluetooth.sendPersonSearchStep(
                            direction: direction,
                            mode: .coast,
                            requestedAtUptime: now,
                            mustFinishByUptime: deadline,
                            session: sessionID
                        )
                    }
                ) else { return }
                switch result {
                case let .submitted(yawTenths, reachesSoftBoundary):
                    submittedTravelTenths += abs(yawTenths)
                    if reachesSoftBoundary {
                        do {
                            try await Task.sleep(nanoseconds: Self.nanoseconds(coastDuration))
                        } catch {
                            return
                        }
                        guard self.motionGeneration == generation,
                              self.phase == .coasting
                        else { return }
                        self.beginSearchEpisode(resetEpisode: true)
                        return
                    }
                    let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                    do {
                        try await Task.sleep(
                            nanoseconds: Self.nanoseconds(
                                min(PersonSearchPolicy.coastCooldown, remaining)
                            )
                        )
                    } catch {
                        return
                    }
                case .busy:
                    do {
                        try await Task.sleep(
                            nanoseconds: Self.nanoseconds(PersonSearchPolicy.commandRetryInterval)
                        )
                    } catch {
                        return
                    }
                case .softBoundaryReached:
                    self.beginSearchEpisode(resetEpisode: true)
                    return
                case .hardBoundaryReached:
                    self.pauseAutomaticMotion(
                        reason: "已到当前安全包络边界；请关闭跟踪、人工回正并重新确认",
                        resumable: false
                    )
                    return
                case .safetyBudgetExhausted:
                    self.pauseAutomaticMotion(
                        reason: "已达到累计行程安全上限，请重新理线并重新启用跟踪",
                        resumable: false
                    )
                    return
                case .inactive, .failed:
                    self.pauseAutomaticMotion(reason: "惯性寻找命令未被云台接受", resumable: false)
                    return
                }
            }
        }
    }

    private func beginSearchEpisode(resetEpisode: Bool) {
        guard enabled,
              let sessionID,
              let visionSessionID = activeVisionSessionID,
              let speedMode = activeSpeedMode
        else { return }

        if resetEpisode {
            searchDirection = lastKnownYawDirection
            searchHasReachedBoundary = false
            searchEpisodeStartedAtUptime = ProcessInfo.processInfo.systemUptime
            searchEpisodeTravelTenths = 0
            searchBoundaryTouches = 0
        }
        let generation = beginNewMotionGeneration()
        phase = .searching
        state = searchHasReachedBoundary
            ? .scanning(searchDirection)
            : .searching(searchDirection)
        canResumeSearch = false
        resetAcquisitionCounters()
        lastSubmittedCorrection = nil
        bluetooth.pausePersonTrackingWithStop(
            session: sessionID,
            reason: "人物出框，自动搜索前 STOP"
        )

        let initialDelay = max(
            PersonSearchPolicy.scanSettleDuration,
            speedMode.commandCooldown
        )
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.nanoseconds(initialDelay))
            } catch {
                return
            }
            var busyStartedAtUptime: TimeInterval?
            while !Task.isCancelled {
                guard let self,
                      self.enabled,
                      self.phase == .searching,
                      self.motionGeneration == generation,
                      self.sessionID == sessionID,
                      self.camera.isPersonTrackingSessionValid(visionSessionID)
                else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let scanDuration = Double(PersonSearchPolicy.scanDurationTenths) / 10.0
                let episodeDeadline = self.searchEpisodeStartedAtUptime
                    + PersonSearchPolicy.maximumScanEpisodeDuration
                if self.lastVisionSampleAtUptime == 0
                    || now - self.lastVisionSampleAtUptime
                    > PersonSearchPolicy.maximumVisionSilence {
                    self.pauseAutomaticMotion(
                        reason: "摄像头画面已停滞，扫描保持静止",
                        resumable: true
                    )
                    return
                }
                if now + scanDuration > episodeDeadline
                    || self.searchEpisodeTravelTenths
                        + PersonSearchPolicy.scanStepTenths
                    >= PersonSearchPolicy.maximumScanEpisodeTravelTenths {
                    self.pauseAutomaticMotion(
                        reason: "本轮扫描已到安全上限，可点击继续扫描",
                        resumable: true
                    )
                    return
                }

                guard let result = self.camera.withValidPersonTrackingSession(
                    visionSessionID,
                    operation: {
                        self.bluetooth.sendPersonSearchStep(
                            direction: self.searchDirection,
                            mode: .scan,
                            requestedAtUptime: now,
                            mustFinishByUptime: episodeDeadline,
                            session: sessionID
                        )
                    }
                ) else { return }
                switch result {
                case let .submitted(yawTenths, reachesSoftBoundary):
                    busyStartedAtUptime = nil
                    self.searchEpisodeTravelTenths += abs(yawTenths)
                    if reachesSoftBoundary {
                        do {
                            try await Task.sleep(
                                nanoseconds: Self.nanoseconds(
                                    scanDuration
                                )
                            )
                        } catch {
                            return
                        }
                        guard self.motionGeneration == generation,
                              self.phase == .searching
                        else { return }
                        self.handleSearchBoundaryReached()
                        return
                    }
                    let remaining = max(
                        0,
                        episodeDeadline - ProcessInfo.processInfo.systemUptime
                    )
                    do {
                        try await Task.sleep(
                            nanoseconds: Self.nanoseconds(
                                min(PersonSearchPolicy.scanCooldown, remaining)
                            )
                        )
                    } catch {
                        return
                    }
                case .busy:
                    if busyStartedAtUptime == nil {
                        busyStartedAtUptime = now
                    } else if now - (busyStartedAtUptime ?? now)
                        >= PersonSearchPolicy.commandMaximumAge {
                        self.pauseAutomaticMotion(
                            reason: "BLE 持续繁忙，本轮扫描已安全暂停",
                            resumable: true
                        )
                        return
                    }
                    do {
                        try await Task.sleep(
                            nanoseconds: Self.nanoseconds(PersonSearchPolicy.commandRetryInterval)
                        )
                    } catch {
                        return
                    }
                case .softBoundaryReached:
                    self.handleSearchBoundaryReached()
                    return
                case .hardBoundaryReached:
                    self.pauseAutomaticMotion(
                        reason: "已到当前安全包络边界；请关闭跟踪、人工回正并重新确认",
                        resumable: false
                    )
                    return
                case .safetyBudgetExhausted:
                    self.pauseAutomaticMotion(
                        reason: "已达到累计行程安全上限，请重新理线并重新启用跟踪",
                        resumable: false
                    )
                    return
                case .inactive, .failed:
                    self.pauseAutomaticMotion(reason: "自动扫描命令未被云台接受", resumable: false)
                    return
                }
            }
        }
    }

    private func handleSearchBoundaryReached() {
        searchBoundaryTouches += 1
        guard searchBoundaryTouches < PersonSearchPolicy.maximumScanBoundaryTouches else {
            pauseAutomaticMotion(
                reason: "已完成本轮左右扫描，可点击继续扫描",
                resumable: true
            )
            return
        }
        searchHasReachedBoundary = true
        searchDirection = searchDirection.opposite
        beginSearchEpisode(resetEpisode: false)
    }

    private func beginReacquisition(
        with sample: PersonVisionSample,
        resumeSearchIfRejected: Bool,
        candidateID: PersonCandidateID?
    ) {
        guard let sessionID else { return }
        _ = beginNewMotionGeneration()
        resumeSearchAfterCandidate = resumeSearchIfRejected
        phase = .reacquiring(
            settleUntilUptime: ProcessInfo.processInfo.systemUptime
                + PersonSearchPolicy.scanSettleDuration
        )
        state = .reacquiring
        canResumeSearch = false
        resetAcquisitionCounters()
        reacquisitionCandidateID = candidateID
        lastValidAtUptime = sample.observedAtUptime
        recentHorizontalObservations.removeAll(keepingCapacity: true)
        lastSubmittedCorrection = nil
        bluetooth.pausePersonTrackingWithStop(
            session: sessionID,
            reason: "扫描发现人物候选 STOP"
        )
    }

    private func pauseAutomaticMotion(reason: String, resumable: Bool) {
        guard enabled, let sessionID else { return }
        _ = beginNewMotionGeneration()
        canResumeSearch = resumable
        if resumable {
            phase = .searchPaused
            state = .searchPaused(reason)
        } else {
            phase = .motionPaused
            state = .motionPaused(reason)
        }
        bluetooth.pausePersonTrackingWithStop(
            session: sessionID,
            reason: "人物搜索安全暂停 STOP"
        )
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                guard let self, self.enabled else { return }
                self.checkForLostTarget()
            }
        }
    }

    private func checkForLostTarget() {
        let now = ProcessInfo.processInfo.systemUptime
        if phase.carriesLockedTarget,
           lastValidAtUptime > 0,
           now - lastValidAtUptime > PersonTrackingPolicy.lostTimeout {
            beginSearchEpisode(resetEpisode: true)
            return
        }
        if case let .reacquiring(settleUntilUptime) = phase,
           now >= settleUntilUptime,
           lastValidAtUptime > 0,
           now - lastValidAtUptime > PersonTrackingPolicy.lostTimeout {
            resetAcquisitionCounters()
            if resumeSearchAfterCandidate {
                beginSearchEpisode(resetEpisode: searchEpisodeStartedAtUptime == 0)
            } else {
                phase = .searchPaused
                state = .searchPaused("候选消失，等待人物重新进入画面")
                canResumeSearch = true
            }
        }
    }

    private func trustedCoastDirection() -> PersonSearchDirection? {
        guard recentHorizontalObservations.count >= 3,
              let last = recentHorizontalObservations.last,
              let correction = lastSubmittedCorrection,
              correction.yawTenths != 0
        else { return nil }
        return PersonSearchPolicy.coastDirection(
            recentCenterXs: recentHorizontalObservations.map(\.centerX),
            lastConfidence: last.confidence,
            lastYawTenths: correction.yawTenths
        )
    }

    private func recordHorizontalObservation(_ detection: PersonDetection) {
        recentHorizontalObservations.append(
            HorizontalObservation(
                centerX: detection.centerX,
                confidence: detection.confidence
            )
        )
        if recentHorizontalObservations.count > 4 {
            recentHorizontalObservations.removeFirst(
                recentHorizontalObservations.count - 4
            )
        }
    }

    @discardableResult
    private func beginNewMotionGeneration() -> UInt64 {
        motionGeneration &+= 1
        pendingCorrectionRetryTask?.cancel()
        pendingCorrectionRetryTask = nil
        coastTask?.cancel()
        coastTask = nil
        searchTask?.cancel()
        searchTask = nil
        return motionGeneration
    }

    private func resetAcquisitionCounters() {
        consecutiveValidDetections = 0
        acquisitionStartedAtUptime = nil
        lastAcquisitionDetection = nil
        reacquisitionCandidateID = nil
    }

    private func publishIdentitySnapshot(_ snapshot: PersonIdentitySnapshot) {
        visiblePeople = snapshot.visibleCandidates
        selectedPersonID = snapshot.lockedID
        selectedPersonDetection = snapshot.lockedDetection
    }

    private func smoothSelectedDetection(_ detection: PersonDetection) -> PersonDetection {
        guard let previous = smoothedSelectedDetection else {
            smoothedSelectedDetection = detection
            return detection
        }
        let alpha = 0.50
        let smoothed = PersonDetection(
            x: previous.x + (detection.x - previous.x) * alpha,
            y: previous.y + (detection.y - previous.y) * alpha,
            width: previous.width + (detection.width - previous.width) * alpha,
            height: previous.height + (detection.height - previous.height) * alpha,
            confidence: detection.confidence
        )
        smoothedSelectedDetection = smoothed
        return smoothed
    }

    private func prepareForTargetSelection() {
        camera.setPersonTrackingSeed(nil)
        phase = .acquiring
        state = .acquiring
        canResumeSearch = false
        lastValidAtUptime = 0
        consecutiveMisses = 0
        resetAcquisitionCounters()
        reversalBlockedUntilUptime = 0
        lastSubmittedCorrection = nil
        centerStopIssued = true
        recentHorizontalObservations.removeAll(keepingCapacity: true)
        lastKnownYawDirection = .right
        searchDirection = .right
        searchHasReachedBoundary = false
        searchEpisodeStartedAtUptime = 0
        searchEpisodeTravelTenths = 0
        searchBoundaryTouches = 0
        resumeSearchAfterCandidate = false
        smoothedSelectedDetection = nil
    }

    private func stopSupersededVisualMotionIfNeeded(
        reason: String,
        cooldownOverride: TimeInterval? = nil
    ) {
        guard !centerStopIssued,
              lastSubmittedCorrection != nil,
              let sessionID
        else { return }
        _ = beginNewMotionGeneration()
        centerStopIssued = true
        bluetooth.pausePersonTrackingWithStop(
            session: sessionID,
            reason: reason,
            cooldownOverride: cooldownOverride
        )
    }

    private func resetTargetState() {
        _ = beginNewMotionGeneration()
        camera.setPersonTrackingSeed(nil)
        identityTracker.reset()
        phase = .off
        activeVisionSessionID = nil
        lastSequence = 0
        lastVisionSampleAtUptime = 0
        lastValidAtUptime = 0
        consecutiveMisses = 0
        resetAcquisitionCounters()
        reversalBlockedUntilUptime = 0
        lastSubmittedCorrection = nil
        centerStopIssued = false
        recentHorizontalObservations.removeAll(keepingCapacity: true)
        lastKnownYawDirection = .right
        searchDirection = .right
        searchHasReachedBoundary = false
        searchEpisodeStartedAtUptime = 0
        searchEpisodeTravelTenths = 0
        searchBoundaryTouches = 0
        resumeSearchAfterCandidate = false
        canResumeSearch = false
        visiblePeople = []
        selectedPersonID = nil
        selectedPersonDetection = nil
        hasAnalyzedPeopleFrame = false
        smoothedSelectedDetection = nil
        hasMadeInitialAutomaticSelection = false
    }

    private func reversesDirection(
        _ next: PersonTrackingCorrection,
        comparedWith previous: PersonTrackingCorrection
    ) -> Bool {
        let yawReversed = next.yawTenths != 0
            && previous.yawTenths != 0
            && (next.yawTenths < 0) != (previous.yawTenths < 0)
        let pitchReversed = next.pitchTenths != 0
            && previous.pitchTenths != 0
            && (next.pitchTenths < 0) != (previous.pitchTenths < 0)
        return yawReversed || pitchReversed
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private func recomputeAvailability() {
        canEnable = appActive
            && safetyArmed
            && bluetooth.motionSafetyArmed
            && bluetooth.trackingOriginConfirmed
            && bluetooth.state.isReady
            && bluetooth.nudgeAvailable
            && camera.status.isRunning
            && !camera.motionCalibrationEnabled
            && !enabled
    }
}
