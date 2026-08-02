import Combine
import Foundation

/// An atomically revocable lease for low-resolution camera motion samples.
/// The capture queue checks the lease before publishing every copied frame.
final class GimbalMotionSessionLease: @unchecked Sendable {
    let id = UUID()

    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func revoke() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

struct GimbalMotionFrameSample: Equatable, Sendable {
    let sessionID: UUID
    let signature: GimbalMotionSignature
    let sequence: UInt64
    let observedAtUptime: TimeInterval
}

enum GimbalCalibrationDirection: Int, CaseIterable, Identifiable, Sendable {
    case left
    case right
    case up
    case down

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .left: return "向左"
        case .right: return "向右"
        case .up: return "向上"
        case .down: return "向下"
        }
    }

    var shortTitle: String {
        switch self {
        case .left: return "左"
        case .right: return "右"
        case .up: return "上"
        case .down: return "下"
        }
    }

    var axis: GimbalMotionAxis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }

    var stepDegrees: Int {
        switch self {
        case .left, .right: return GimbalRangeCalibrationPolicy.yawStepDegrees
        case .up, .down: return GimbalRangeCalibrationPolicy.pitchStepDegrees
        }
    }

    var probeLimitDegrees: Int {
        switch self {
        case .left, .right: return GimbalRangeCalibrationPolicy.yawProbeLimitDegrees
        case .up, .down: return GimbalRangeCalibrationPolicy.pitchProbeLimitDegrees
        }
    }

    var safetyMarginDegrees: Int {
        switch self {
        case .left, .right: return GimbalRangeCalibrationPolicy.yawSafetyMarginDegrees
        case .up, .down: return GimbalRangeCalibrationPolicy.pitchSafetyMarginDegrees
        }
    }

    var yawDegrees: Int {
        switch self {
        case .left: return -stepDegrees
        case .right: return stepDegrees
        case .up, .down: return 0
        }
    }

    var pitchDegrees: Int {
        switch self {
        case .up: return -stepDegrees
        case .down: return stepDegrees
        case .left, .right: return 0
        }
    }

    var oppositeYawDegrees: Int { -yawDegrees }
    var oppositePitchDegrees: Int { -pitchDegrees }
}

enum GimbalRangeMeasurementKind: Equatable, Sendable {
    /// The operator stopped at the last visually verified safe step.
    case operatorLimit
    /// The camera could not verify the attempted next step; this is not proof
    /// of a mechanical stop and may also mean blockage or a failed BLE action.
    case unverifiedResponse
    /// The app's conservative engineering probe cap was reached. The physical
    /// mechanism may have additional travel beyond this value.
    case engineeringCap
}

struct GimbalRangeMeasurement: Equatable, Sendable, Identifiable {
    let direction: GimbalCalibrationDirection
    let verifiedExtentDegrees: Int
    let safetyMarginDegrees: Int
    let usableExtentDegrees: Int
    let kind: GimbalRangeMeasurementKind

    var id: GimbalCalibrationDirection { direction }

    var note: String {
        switch kind {
        case .operatorLimit: return "人工安全端点"
        case .unverifiedResponse: return "疑似端点/阻塞"
        case .engineeringCap: return "已到应用验证上限"
        }
    }
}

struct GimbalRangeCalibrationResult: Equatable, Sendable {
    let measurements: [GimbalRangeMeasurement]
    let completedAt: Date

    func measurement(for direction: GimbalCalibrationDirection) -> GimbalRangeMeasurement? {
        measurements.first { $0.direction == direction }
    }

    var envelope: GimbalTrackingEnvelope? {
        guard let left = measurement(for: .left),
              let right = measurement(for: .right),
              let up = measurement(for: .up),
              let down = measurement(for: .down)
        else { return nil }
        let envelope = GimbalTrackingEnvelope(
            leftYawTenths: left.usableExtentDegrees * 10,
            rightYawTenths: right.usableExtentDegrees * 10,
            upPitchTenths: up.usableExtentDegrees * 10,
            downPitchTenths: down.usableExtentDegrees * 10
        )
        return envelope
    }
}

enum GimbalRangeCalibrationPolicy {
    static let analysisInterval: TimeInterval = 0.08
    static let baselineDuration: TimeInterval = 0.75
    static let postCommandSettleDuration: TimeInterval = 0.18
    static let commandCompletionTimeout: TimeInterval = 3.5
    static let sampleTimeout: TimeInterval = 1.2
    static let maximumFreshSampleAge: TimeInterval = 0.45
    /// A short pre-command window that must show a still scene on both axes.
    /// Without it, a person walking through the frame makes every probe look
    /// like verified gimbal motion even when the command never executed.
    static let preStepStillnessGap: TimeInterval = 0.12
    /// A step whose measured image shift falls below this fraction of the
    /// running median of previously confirmed steps is treated as partial
    /// travel (typically the mechanism nearing its end stop) and is not
    /// credited as a full step.
    static let minimumShiftFractionOfExpected = 0.45
    /// The return leg aggregates up to this many verified outward steps into
    /// one relative move at the same angular rate as the probes.
    static let maximumReturnChunkSteps = 3

    static let yawStepDegrees = 5
    static let pitchStepDegrees = 2

    // These are application verification caps, not DJI mechanical limits.
    static let yawProbeLimitDegrees = 100
    static let pitchProbeLimitDegrees = 36
    static let yawSafetyMarginDegrees = 10
    static let pitchSafetyMarginDegrees = 6

    static func usableExtent(
        verifiedExtentDegrees: Int,
        direction: GimbalCalibrationDirection
    ) -> Int {
        max(0, verifiedExtentDegrees - direction.safetyMarginDegrees)
    }
}

@MainActor
final class GimbalRangeCalibrationCoordinator: ObservableObject {
    @Published private(set) var canStart = false
    @Published private(set) var isRunning = false
    @Published private(set) var awaitingStepDecision = false
    @Published private(set) var awaitingCenterConfirmation = false
    @Published private(set) var canContinueOutward = false
    @Published private(set) var statusText = "尚未进行全向行程验证"
    @Published private(set) var detailText = "启动后会按左、右、上、下逐步验证，并在每一步等待人工确认。"
    @Published private(set) var responseText: String?
    @Published private(set) var centerCheckText: String?
    @Published private(set) var progress = 0.0
    @Published private(set) var currentDirection: GimbalCalibrationDirection?
    @Published private(set) var currentVerifiedExtentDegrees = 0
    @Published private(set) var result: GimbalRangeCalibrationResult?
    @Published private(set) var envelopeIsActive = false

    private enum PendingVerdict {
        case moved
        case noResponse
        case inconclusive
    }

    private let bluetooth: OM3BluetoothController
    private let camera: CameraController
    private let tracking: PersonTrackingCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var operationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var bluetoothSessionID: UUID?
    private var cameraSessionID: UUID?
    private var latestMotionSample: GimbalMotionFrameSample?
    private var directionOriginSignature: GimbalMotionSignature?
    private var successfulSteps = 0
    /// Steps whose motion the camera verified, including a final step the
    /// operator declined to credit toward the envelope. The return leg must
    /// undo physical travel, not the credited extent.
    private var physicalSteps = 0
    private var pendingVerdict: PendingVerdict?
    private var pendingShiftSign = 0
    private var pendingShiftMagnitude = 0
    private var directionShiftSign = 0
    private var acceptedShiftMagnitudes: [Int] = []
    private var directionNeedsRedo = false
    private var measurements: [GimbalCalibrationDirection: GimbalRangeMeasurement] = [:]
    private var safetyArmed = false
    private var appActive = true

    init(
        bluetooth: OM3BluetoothController,
        camera: CameraController,
        tracking: PersonTrackingCoordinator
    ) {
        self.bluetooth = bluetooth
        self.camera = camera
        self.tracking = tracking

        bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if self.isRunning, !state.isReady {
                    self.fail("BLE 连接已失效；本次结果已作废。", sendStop: false)
                }
                self.recomputeAvailability()
            }
            .store(in: &cancellables)

        bluetooth.$nudgeAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeAvailability() }
            .store(in: &cancellables)

        bluetooth.$motionSafetyArmed
            .receive(on: RunLoop.main)
            .sink { [weak self] armed in
                guard let self else { return }
                if self.isRunning,
                   self.bluetoothSessionID != nil,
                   !armed {
                    // The Bluetooth safety transition owns the single STOP.
                    self.fail("底层运动安全锁已关闭；本次结果已作废。", sendStop: false)
                }
                self.recomputeAvailability()
            }
            .store(in: &cancellables)

        bluetooth.$rangeCalibrationActive
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                guard let self else { return }
                if self.isRunning,
                   self.bluetoothSessionID != nil,
                   !active {
                    // Session invalidation originates in a stronger Bluetooth
                    // shutdown path which already owns STOP or has disconnected.
                    self.fail("底层校准会话已失效；本次结果已作废。", sendStop: false)
                }
                self.recomputeAvailability()
            }
            .store(in: &cancellables)

        bluetooth.$calibratedTrackingEnvelope
            .receive(on: RunLoop.main)
            .sink { [weak self] envelope in
                guard let self else { return }
                self.envelopeIsActive = envelope != nil
                if envelope == nil, self.result != nil, !self.isRunning {
                    self.detailText = "上次测量值仍可查看，但扩展范围已失效；请回正后重新验证。"
                }
            }
            .store(in: &cancellables)

        camera.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if self.isRunning, !status.isRunning {
                    self.fail("摄像头预览已停止；本次结果已作废。", sendStop: true)
                }
                self.recomputeAvailability()
            }
            .store(in: &cancellables)

        // Direct main-thread callback; see CameraController.onMotionSample.
        camera.onMotionSample = { [weak self] sample in
            guard let self,
                  sample.sessionID == self.cameraSessionID,
                  self.camera.isMotionCalibrationSessionValid(sample.sessionID)
            else { return }
            if let latest = self.latestMotionSample,
               sample.sequence <= latest.sequence {
                return
            }
            self.latestMotionSample = sample
        }

        tracking.$enabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if self.isRunning, enabled {
                    self.fail("人物跟踪已启动；全向验证已停止并作废。", sendStop: true)
                }
                self.recomputeAvailability()
            }
            .store(in: &cancellables)
    }

    deinit {
        operationTask?.cancel()
    }

    func setSafetyArmed(_ armed: Bool) {
        safetyArmed = armed
        if isRunning, !armed {
            fail("运动安全确认已关闭；本次结果已作废。", sendStop: true)
        }
        recomputeAvailability()
    }

    func setAppActive(_ active: Bool, sendStopOnDisable: Bool = true) {
        appActive = active
        if isRunning, !active {
            fail(
                "应用进入后台；本次结果已作废。",
                sendStop: sendStopOnDisable
            )
        }
        recomputeAvailability()
    }

    /// Call only after the UI has obtained explicit confirmation that the OM3
    /// is centered, balanced, clear of obstacles, and its soft cable has slack.
    func start() {
        recomputeAvailability()
        guard canStart else {
            statusText = "当前不能开始全向验证"
            detailText = "需要 OM3、摄像头、安全确认和动作互锁同时就绪。"
            return
        }
        guard let bluetoothSessionID = bluetooth.beginRangeCalibration() else {
            recomputeAvailability()
            return
        }
        guard let cameraSessionID = camera.beginMotionCalibration() else {
            bluetooth.endRangeCalibration(
                session: bluetoothSessionID,
                reason: "摄像头运动分析未能启动。",
                sendStop: false
            )
            statusText = "无法启动摄像头运动分析"
            detailText = "请确认 USB 摄像头正在预览且人物跟踪已关闭。"
            recomputeAvailability()
            return
        }

        generation &+= 1
        let activeGeneration = generation
        self.bluetoothSessionID = bluetoothSessionID
        self.cameraSessionID = cameraSessionID
        latestMotionSample = nil
        directionOriginSignature = nil
        successfulSteps = 0
        physicalSteps = 0
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        directionShiftSign = 0
        acceptedShiftMagnitudes.removeAll(keepingCapacity: true)
        directionNeedsRedo = false
        measurements.removeAll()
        result = nil
        envelopeIsActive = false
        currentDirection = nil
        currentVerifiedExtentDegrees = 0
        isRunning = true
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        responseText = nil
        centerCheckText = nil
        progress = 0
        statusText = "正在检查静止画面"
        detailText = "请勿触碰云台、底座或线缆，并让镜头对准有纹理的静止场景。"
        recomputeAvailability()

        operationTask = Task { [weak self] in
            await self?.prepareBaseline(generation: activeGeneration)
        }
    }

    func confirmObservedStepAndContinue() {
        guard isRunning,
              sessionsAreValid,
              awaitingStepDecision,
              canContinueOutward,
              pendingVerdict == .moved,
              let direction = currentDirection
        else { return }

        acceptPendingMovedStep(direction)
        if currentVerifiedExtentDegrees >= direction.probeLimitDegrees {
            finishDirection(direction, kind: .engineeringCap)
        } else {
            scheduleProbe(direction)
        }
    }

    func stopAtCurrentSafeExtent() {
        guard isRunning,
              sessionsAreValid,
              awaitingStepDecision,
              let direction = currentDirection,
              let pendingVerdict
        else { return }

        let kind: GimbalRangeMeasurementKind
        switch pendingVerdict {
        case .moved:
            // The operator chose to stop on this very step, usually because
            // they saw something the camera did not. The step is therefore not
            // credited toward the envelope, but its physical travel must still
            // be undone on the return leg.
            physicalSteps += 1
            kind = .operatorLimit
        case .noResponse, .inconclusive:
            kind = .unverifiedResponse
        }
        finishDirection(direction, kind: kind)
    }

    /// Re-runs the current probe after a noResponse/inconclusive verdict, so a
    /// transient glitch (lighting, a person passing) does not force the whole
    /// direction to end at the previous step.
    func retryCurrentStep() {
        guard isRunning,
              sessionsAreValid,
              awaitingStepDecision,
              pendingVerdict != .moved,
              let direction = currentDirection
        else { return }
        scheduleProbe(direction)
    }

    func confirmReturnedToCenter() {
        guard isRunning else { return }
        guard sessionsAreValid else {
            fail("校准会话已失效；不能启用本次测量。", sendStop: true)
            return
        }
        guard
              awaitingCenterConfirmation,
              let completedDirection = currentDirection
        else { return }

        awaitingCenterConfirmation = false
        centerCheckText = nil
        if directionNeedsRedo {
            directionNeedsRedo = false
            beginDirection(completedDirection)
            return
        }
        if let index = GimbalCalibrationDirection.allCases.firstIndex(of: completedDirection),
           index + 1 < GimbalCalibrationDirection.allCases.count {
            beginDirection(GimbalCalibrationDirection.allCases[index + 1])
        } else {
            completeCalibration()
        }
    }

    func cancel() {
        guard isRunning else { return }
        fail("已取消全向行程验证；请人工确认云台已回正。", sendStop: true)
    }

    func emergencyStop() {
        if isRunning {
            fail("已发送 STOP；中途停止后姿态未知，本次结果已作废。", sendStop: true)
        } else {
            bluetooth.stopMotion(reason: "手动 STOP")
        }
    }

    private func prepareBaseline(generation: UInt64) async {
        guard let first = await waitForFreshSample(
            afterSequence: nil,
            timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
            generation: generation
        ) else {
            failIfCurrent(
                generation,
                message: "没有收到可用摄像头帧；全向验证未开始。"
            )
            return
        }

        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(GimbalRangeCalibrationPolicy.baselineDuration)
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard let last = await waitForFreshSample(
            afterSequence: first.sequence,
            timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
            generation: generation
        ) else {
            // Without this, a camera hiccup here left the coordinator running
            // forever with no pending decision and no live task.
            failIfCurrent(
                generation,
                message: "基线检查期间摄像头帧中断；全向验证未开始。"
            )
            return
        }

        let horizontal = GimbalMotionAnalysis.estimate(
            reference: first.signature,
            current: last.signature,
            axis: .horizontal
        )
        let vertical = GimbalMotionAnalysis.estimate(
            reference: first.signature,
            current: last.signature,
            axis: .vertical
        )
        guard case .noResponse = horizontal.verdict,
              case .noResponse = vertical.verdict
        else {
            failIfCurrent(
                generation,
                message: "基线画面不够稳定或纹理不足；请换静止场景后重试。"
            )
            return
        }

        beginDirection(.left)
    }

    private func beginDirection(_ direction: GimbalCalibrationDirection) {
        guard isRunning else { return }
        currentDirection = direction
        currentVerifiedExtentDegrees = 0
        successfulSteps = 0
        physicalSteps = 0
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        directionShiftSign = 0
        acceptedShiftMagnitudes.removeAll(keepingCapacity: true)
        directionNeedsRedo = false
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        responseText = nil
        centerCheckText = nil
        directionOriginSignature = latestMotionSample?.signature
        statusText = "准备验证\(direction.title)行程"
        detailText = "每次只移动 \(direction.stepDegrees)°；观察实体、线缆和预览后再确认下一步。"
        scheduleProbe(direction)
    }

    private func scheduleProbe(_ direction: GimbalCalibrationDirection) {
        guard isRunning else { return }
        generation &+= 1
        let activeGeneration = generation
        awaitingStepDecision = false
        canContinueOutward = false
        pendingVerdict = nil
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            await self?.issueProbe(direction, generation: activeGeneration)
        }
    }

    private func issueProbe(
        _ direction: GimbalCalibrationDirection,
        generation: UInt64
    ) async {
        guard let bluetoothSessionID,
              let before = await waitForFreshSample(
                afterSequence: nil,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
              ),
              isCurrent(generation)
        else {
            failIfCurrent(generation, message: "摄像头帧已中断；本次结果已作废。")
            return
        }
        let targetExtent = currentVerifiedExtentDegrees + direction.stepDegrees

        // The probe verdict is only meaningful against a scene that was still
        // right before the command. A person walking through the frame would
        // otherwise verify every step, even one the gimbal never executed.
        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(GimbalRangeCalibrationPolicy.preStepStillnessGap)
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard let still = await waitForFreshSample(
            afterSequence: before.sequence,
            timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
            generation: generation
        ) else {
            failIfCurrent(generation, message: "摄像头帧已中断；本次结果已作废。")
            return
        }
        let preHorizontal = GimbalMotionAnalysis.estimate(
            reference: before.signature,
            current: still.signature,
            axis: .horizontal
        )
        let preVertical = GimbalMotionAnalysis.estimate(
            reference: before.signature,
            current: still.signature,
            axis: .vertical
        )
        guard case .noResponse = preHorizontal.verdict,
              case .noResponse = preVertical.verdict
        else {
            // Nothing was commanded, so no STOP is needed; the operator can
            // retry once the scene is still again.
            presentStepDecision(
                verdict: .inconclusive,
                status: "步前画面不静止，已暂停本步",
                response: "发送动作前画面已在变化（人员走动、光照或支架抖动）；请让场景静止后重试本步。"
            )
            updateProgress(for: direction, proposedExtent: targetExtent)
            return
        }
        if directionOriginSignature == nil {
            directionOriginSignature = still.signature
        }

        statusText = "\(direction.title)探测至约 \(targetExtent)°"
        detailText = "正在发送单步动作；请随时观察碰撞、异响和线缆拉扯。"
        responseText = nil

        let submitted = bluetooth.sendRangeCalibrationNudge(
            yawDegrees: direction.yawDegrees,
            pitchDegrees: direction.pitchDegrees,
            label: "全向验证 · \(direction.title) \(direction.stepDegrees)°",
            session: bluetoothSessionID
        )
        guard submitted else {
            failIfCurrent(generation, message: "自检步进未能进入 BLE 发送队列。")
            return
        }

        guard await waitForNudgeCompletion(
            timeout: GimbalRangeCalibrationPolicy.commandCompletionTimeout,
            generation: generation
        ) else {
            failIfCurrent(generation, message: "自检步进未在限定时间内完成。")
            return
        }
        let settleStartSequence = latestMotionSample?.sequence ?? still.sequence
        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(
                GimbalRangeCalibrationPolicy.postCommandSettleDuration
            )
        )
        guard isCurrent(generation), !Task.isCancelled,
              let after = await waitForFreshSample(
                afterSequence: settleStartSequence,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
              )
        else {
            failIfCurrent(generation, message: "动作后摄像头帧已中断。")
            return
        }

        let estimate = GimbalMotionAnalysis.estimate(
            reference: still.signature,
            current: after.signature,
            axis: direction.axis
        )
        let orthogonalEstimate = GimbalMotionAnalysis.estimate(
            reference: still.signature,
            current: after.signature,
            axis: direction.axis == .horizontal ? .vertical : .horizontal
        )
        evaluateProbeOutcome(
            direction,
            estimate: estimate,
            orthogonalEstimate: orthogonalEstimate,
            targetExtent: targetExtent,
            bluetoothSessionID: bluetoothSessionID
        )
        updateProgress(for: direction, proposedExtent: targetExtent)
    }

    private func evaluateProbeOutcome(
        _ direction: GimbalCalibrationDirection,
        estimate: GimbalMotionEstimate,
        orthogonalEstimate: GimbalMotionEstimate,
        targetExtent: Int,
        bluetoothSessionID: UUID
    ) {
        switch estimate.verdict {
        case .moved:
            if case .moved = orthogonalEstimate.verdict {
                stopForUnreliableStep(
                    bluetoothSessionID: bluetoothSessionID,
                    status: "检测到正交方向画面位移，已 STOP",
                    response: "画面同时沿另一轴移动，装置可能被碰动或支架松动；请检查后重试本步。"
                )
                return
            }
            let shiftSign = estimate.axisShift >= 0 ? 1 : -1
            if directionShiftSign != 0, shiftSign != directionShiftSign {
                stopForUnreliableStep(
                    bluetoothSessionID: bluetoothSessionID,
                    status: "画面位移方向与此前相反，已 STOP",
                    response: "本步位移与本方向此前步幅方向相反，疑似回弹、二次居中或误检；不能计入行程。"
                )
                return
            }
            if acceptedShiftMagnitudes.count >= 2 {
                let expected = Double(medianAcceptedShiftMagnitude)
                let fraction = Double(abs(estimate.axisShift)) / max(expected, 1)
                if fraction < GimbalRangeCalibrationPolicy.minimumShiftFractionOfExpected {
                    _ = bluetooth.stopRangeCalibrationMotion(
                        session: bluetoothSessionID,
                        reason: "自检位移明显小于预期 STOP"
                    )
                    presentStepDecision(
                        verdict: .inconclusive,
                        status: "画面位移明显小于此前步幅，已 STOP",
                        response: "实际位移约为此前每步的 \(Int(fraction * 100))%，疑似接近端点或受阻；该步不计入行程，请在此结束该方向。"
                    )
                    return
                }
            }
            pendingVerdict = .moved
            pendingShiftSign = shiftSign
            pendingShiftMagnitude = abs(estimate.axisShift)
            awaitingStepDecision = true
            canContinueOutward = true
            statusText = "等待确认：\(direction.title)约 \(targetExtent)°"
            responseText = "摄像头检测到同轴画面位移。请确认实体确实完成动作且仍有安全余量。"
            detailText = "每一步都必须由现场人员确认；画面分析不能证明机械端点。"
        case .noResponse:
            stopForUnreliableStep(
                bluetoothSessionID: bluetoothSessionID,
                verdict: .noResponse,
                status: "\(direction.title)无可验证响应，已 STOP",
                response: "这可能是端点、阻塞、线缆受力、BLE 未执行或摄像头未随云台运动；不能继续向外。"
            )
        case let .inconclusive(reason):
            stopForUnreliableStep(
                bluetoothSessionID: bluetoothSessionID,
                status: "画面判断不可靠，已 STOP",
                response: "\(reason) 可重试本步、按当前已确认行程返程，或取消后改善场景重试。"
            )
        }
    }

    private func stopForUnreliableStep(
        bluetoothSessionID: UUID,
        verdict: PendingVerdict = .inconclusive,
        status: String,
        response: String
    ) {
        _ = bluetooth.stopRangeCalibrationMotion(
            session: bluetoothSessionID,
            reason: "自检画面结论不可靠 STOP"
        )
        presentStepDecision(verdict: verdict, status: status, response: response)
    }

    private func presentStepDecision(
        verdict: PendingVerdict,
        status: String,
        response: String
    ) {
        pendingVerdict = verdict
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        awaitingStepDecision = true
        canContinueOutward = false
        statusText = status
        responseText = response
        detailText = "每一步都必须由现场人员确认；画面分析不能证明机械端点。"
    }

    private var medianAcceptedShiftMagnitude: Int {
        let sorted = acceptedShiftMagnitudes.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func acceptPendingMovedStep(_ direction: GimbalCalibrationDirection) {
        successfulSteps += 1
        physicalSteps += 1
        currentVerifiedExtentDegrees = successfulSteps * direction.stepDegrees
        if pendingShiftSign != 0 {
            directionShiftSign = pendingShiftSign
        }
        if pendingShiftMagnitude > 0 {
            acceptedShiftMagnitudes.append(pendingShiftMagnitude)
        }
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        awaitingStepDecision = false
        canContinueOutward = false
        responseText = nil
    }

    private func finishDirection(
        _ direction: GimbalCalibrationDirection,
        kind: GimbalRangeMeasurementKind
    ) {
        guard isRunning else { return }
        let verified = successfulSteps * direction.stepDegrees
        let usable = GimbalRangeCalibrationPolicy.usableExtent(
            verifiedExtentDegrees: verified,
            direction: direction
        )
        guard usable > 0 else {
            // A weak direction no longer discards the whole session: return to
            // origin, then re-run the same direction after the operator
            // confirms recentering. Other directions' measurements survive.
            directionNeedsRedo = true
            awaitingStepDecision = false
            canContinueOutward = false
            pendingVerdict = nil
            responseText = "\(direction.title)确认行程不足（余量需超过 \(direction.safetyMarginDegrees)°）；回正确认后将重试该方向。"
            beginReturn(direction)
            return
        }
        measurements[direction] = GimbalRangeMeasurement(
            direction: direction,
            verifiedExtentDegrees: verified,
            safetyMarginDegrees: direction.safetyMarginDegrees,
            usableExtentDegrees: usable,
            kind: kind
        )
        awaitingStepDecision = false
        canContinueOutward = false
        pendingVerdict = nil
        responseText = nil
        beginReturn(direction)
    }

    private func beginReturn(_ direction: GimbalCalibrationDirection) {
        generation &+= 1
        let activeGeneration = generation
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            await self?.returnToDirectionOrigin(direction, generation: activeGeneration)
        }
    }

    private func returnToDirectionOrigin(
        _ direction: GimbalCalibrationDirection,
        generation: UInt64
    ) async {
        guard let bluetoothSessionID else { return }
        statusText = "正在按已确认路径从\(direction.title)返程"
        detailText = "返程完成后仍需人工确认回正；应用不会仅凭指令积分认定原点。"

        // The return aggregates verified steps into larger relative moves at
        // the same angular rate as the probes (stepDegrees per second), which
        // cuts several interlock waits per direction.
        var remainingDegrees = physicalSteps * direction.stepDegrees
        let yawSign = direction.oppositeYawDegrees == 0
            ? 0
            : direction.oppositeYawDegrees / direction.stepDegrees
        let pitchSign = direction.oppositePitchDegrees == 0
            ? 0
            : direction.oppositePitchDegrees / direction.stepDegrees
        while remainingDegrees > 0 {
            guard isCurrent(generation), !Task.isCancelled else { return }
            let chunkDegrees = min(
                remainingDegrees,
                direction.stepDegrees * GimbalRangeCalibrationPolicy.maximumReturnChunkSteps
            )
            let durationTenths = UInt8(
                min(40, max(10, chunkDegrees * 10 / direction.stepDegrees))
            )
            let motionTimeout = max(
                GimbalRangeCalibrationPolicy.commandCompletionTimeout,
                Double(durationTenths) / 10.0 + 1.5
            )
            guard await waitForNudgeAvailability(
                timeout: motionTimeout,
                generation: generation
            ) else {
                failIfCurrent(generation, message: "返程互锁超时；请人工回正。")
                return
            }
            let submitted = bluetooth.sendRangeCalibrationNudge(
                yawDegrees: yawSign * chunkDegrees,
                pitchDegrees: pitchSign * chunkDegrees,
                durationTenths: durationTenths,
                label: "全向验证返程 · \(direction.title) 剩余 \(remainingDegrees)°",
                session: bluetoothSessionID
            )
            guard submitted,
                  await waitForNudgeCompletion(
                    timeout: motionTimeout,
                    generation: generation
                  )
            else {
                failIfCurrent(generation, message: "返程动作未能可靠提交；请人工回正。")
                return
            }
            remainingDegrees -= chunkDegrees
        }

        guard isCurrent(generation), !Task.isCancelled else { return }
        // The origin comparison must use a frame captured after the last
        // return move settled, never a stale or mid-motion sample.
        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(
                GimbalRangeCalibrationPolicy.postCommandSettleDuration
            )
        )
        let settledSample = await waitForFreshSample(
            afterSequence: latestMotionSample?.sequence,
            timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
            generation: generation
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        let originCheck: String
        if let origin = directionOriginSignature,
           let current = settledSample?.signature {
            let estimate = GimbalMotionAnalysis.estimate(
                reference: origin,
                current: current,
                axis: direction.axis
            )
            switch estimate.verdict {
            case .noResponse:
                originCheck = "预览与本方向起点大致一致，但仍需检查实体姿态。"
            case .moved:
                originCheck = "预览仍与起点存在位移；请勿直接继续，先人工确认回正。"
            case .inconclusive:
                originCheck = "摄像头无法可靠判断是否回到起点，请以实体姿态为准。"
            }
        } else {
            originCheck = "没有足够画面用于回正复核，请以实体姿态为准。"
        }

        successfulSteps = 0
        physicalSteps = 0
        currentVerifiedExtentDegrees = 0
        awaitingCenterConfirmation = true
        centerCheckText = originCheck
        statusText = "请确认云台已回到验证起点"
        detailText = "只有确认回正后才会开始下一个方向；若不确定，请取消并重新置中。"
        updateProgress(for: direction, proposedExtent: direction.probeLimitDegrees)
    }

    private func completeCalibration() {
        guard isRunning,
              sessionsAreValid,
              GimbalCalibrationDirection.allCases.allSatisfy({ measurements[$0] != nil })
        else {
            fail("四个方向尚未全部完成；本次结果已作废。", sendStop: true)
            return
        }

        let ordered = GimbalCalibrationDirection.allCases.compactMap { measurements[$0] }
        let completedResult = GimbalRangeCalibrationResult(
            measurements: ordered,
            completedAt: Date()
        )
        guard let envelope = completedResult.envelope else {
            fail("验证结果无法形成有效安全包络。", sendStop: true)
            return
        }
        // Validate against the install caps while the sessions are still alive:
        // once they are torn down, a failed install can no longer route its
        // STOP through the calibration lease.
        guard envelope.leftYawTenths <= 900,
              envelope.rightYawTenths <= 900,
              envelope.upPitchTenths <= 300,
              envelope.downPitchTenths <= 300
        else {
            fail("验证结果超出可启用上限；本次结果已作废。", sendStop: true)
            return
        }

        operationTask?.cancel()
        operationTask = nil
        generation &+= 1
        camera.endMotionCalibration()
        cameraSessionID = nil
        if let session = bluetoothSessionID {
            bluetoothSessionID = nil
            bluetooth.endRangeCalibration(
                session: session,
                reason: "四向行程验证完成并已人工确认回正。",
                sendStop: false
            )
        }
        guard bluetooth.installCalibratedTrackingEnvelope(envelope) else {
            fail("范围已测得，但未能启用到人物跟踪。", sendStop: true)
            return
        }

        result = completedResult
        isRunning = false
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        currentDirection = nil
        currentVerifiedExtentDegrees = 0
        responseText = nil
        centerCheckText = nil
        progress = 1
        envelopeIsActive = true
        statusText = "四向安全行程验证完成"
        detailText = "已扣除保护余量，并仅对下一次人物跟踪启用；手动点动、STOP、断线或跟踪结束都会使其失效。"
        recomputeAvailability()
    }

    private func fail(_ message: String, sendStop: Bool) {
        guard isRunning || bluetoothSessionID != nil || cameraSessionID != nil else {
            statusText = "全向验证未完成"
            detailText = message
            return
        }
        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        camera.endMotionCalibration()
        cameraSessionID = nil
        if let session = bluetoothSessionID {
            bluetoothSessionID = nil
            bluetooth.endRangeCalibration(
                session: session,
                reason: message,
                sendStop: sendStop
            )
        } else if sendStop, bluetooth.state.isReady {
            // The calibration lease may already be torn down (e.g. a failed
            // envelope install right after completion); the requested STOP
            // must still go out.
            bluetooth.stopMotion(reason: message)
        }
        latestMotionSample = nil
        directionOriginSignature = nil
        successfulSteps = 0
        physicalSteps = 0
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        directionShiftSign = 0
        acceptedShiftMagnitudes.removeAll(keepingCapacity: true)
        directionNeedsRedo = false
        measurements.removeAll()
        result = nil
        isRunning = false
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        currentDirection = nil
        currentVerifiedExtentDegrees = 0
        responseText = nil
        centerCheckText = nil
        progress = 0
        envelopeIsActive = false
        statusText = "全向验证未完成"
        detailText = message
        recomputeAvailability()
    }

    private func failIfCurrent(_ generation: UInt64, message: String) {
        guard isCurrent(generation) else { return }
        fail(message, sendStop: true)
    }

    private func waitForFreshSample(
        afterSequence: UInt64?,
        timeout: TimeInterval,
        generation: UInt64
    ) async -> GimbalMotionFrameSample? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isCurrent(generation), !Task.isCancelled,
                  let cameraSessionID,
                  camera.isMotionCalibrationSessionValid(cameraSessionID)
            else { return nil }
            if let sample = latestMotionSample,
               sample.sessionID == cameraSessionID,
               afterSequence.map({ sample.sequence > $0 }) ?? true,
               ProcessInfo.processInfo.systemUptime - sample.observedAtUptime
                    <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge {
                return sample
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    private func waitForNudgeCompletion(
        timeout: TimeInterval,
        generation: UInt64
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var observedBusy = !bluetooth.nudgeAvailable
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isCurrent(generation), !Task.isCancelled else { return false }
            if !bluetooth.nudgeAvailable {
                observedBusy = true
            } else if observedBusy {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    private func waitForNudgeAvailability(
        timeout: TimeInterval,
        generation: UInt64
    ) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isCurrent(generation), !Task.isCancelled else { return false }
            if bluetooth.nudgeAvailable { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return false
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        isRunning && self.generation == generation && sessionsAreValid
    }

    private var sessionsAreValid: Bool {
        guard let bluetoothSessionID,
              let cameraSessionID
        else { return false }
        return bluetooth.isRangeCalibrationSessionValid(bluetoothSessionID)
            && camera.isMotionCalibrationSessionValid(cameraSessionID)
    }

    private func updateProgress(
        for direction: GimbalCalibrationDirection,
        proposedExtent: Int
    ) {
        let completedDirections = Double(direction.rawValue)
        let directionFraction = min(
            1,
            Double(proposedExtent) / Double(direction.probeLimitDegrees)
        )
        progress = min(1, (completedDirections + directionFraction) / 4.0)
    }

    private func recomputeAvailability() {
        canStart = !isRunning
            && appActive
            && safetyArmed
            && bluetooth.state.isReady
            && bluetooth.motionSafetyArmed
            && bluetooth.nudgeAvailable
            && !bluetooth.personTrackingActive
            && !bluetooth.rangeCalibrationActive
            && camera.status.isRunning
            && !camera.personTrackingEnabled
            && !camera.motionCalibrationEnabled
            && !tracking.enabled
    }

    private static func nanoseconds(_ duration: TimeInterval) -> UInt64 {
        UInt64(max(0, duration) * 1_000_000_000)
    }
}
