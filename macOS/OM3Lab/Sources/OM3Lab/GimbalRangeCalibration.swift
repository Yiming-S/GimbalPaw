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

private struct TimedGimbalMotionVectorEstimate: Sendable {
    let estimate: GimbalMotionVectorEstimate
    let duration: TimeInterval
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
        OM3HardwareMotionLimits.probeCapDegrees(for: hardwareDirection)
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

    private var hardwareDirection: OM3HardwareMotionLimits.Direction {
        switch self {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        }
    }
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
    static let maximumAnalysisDuration: TimeInterval = 0.75
    /// Safe retries before a command is queued only reacquire a fresh still
    /// baseline. They never reuse an old frame or advance the motion ledger.
    static let preCommandRetryInitialDelay: TimeInterval = 0.30
    static let preCommandRetryMaximumDelay: TimeInterval = 2.0
    static let preCommandRetryMaximumAttempts = 6
    static let preCommandRetryMaximumDuration: TimeInterval = 15
    /// Once a command has been queued, recovery is observation-only: STOP,
    /// then take fresh frames against the same pre-command checkpoint. No
    /// probe command is automatically submitted a second time.
    static let postCommandObservationAttempts = GimbalRangeCalibrationAutomationPolicy
        .maximumObservationAttempts
    static let postCommandObservationGap: TimeInterval = 0.22
    /// Give the operator a visible STOP window between automatically verified
    /// outward steps, while avoiding a click for every normal step.
    static let automaticStepAdvanceDelay: TimeInterval = 0.65
    static let returnOriginObservationAttempts = 4
    static let returnOriginRequiredMatches = 2
    static let returnPreparationMaximumFailures = 3
    static let returnPreparationMaximumDuration: TimeInterval = 12
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

    static let yawStepDegrees = OM3HardwareMotionLimits.yawProbeStepDegrees
    static let pitchStepDegrees = OM3HardwareMotionLimits.pitchProbeStepDegrees
    static let yawSafetyMarginDegrees = OM3HardwareMotionLimits
        .trackingYawSafetyMarginDegrees
    static let pitchSafetyMarginDegrees = OM3HardwareMotionLimits
        .trackingPitchSafetyMarginDegrees

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
    @Published private(set) var canRetryCurrentStep = false
    @Published private(set) var requiresNoMovementConfirmation = false
    @Published private(set) var manualRecoveryPaused = false
    @Published private(set) var statusText = "尚未进行全向行程验证"
    @Published private(set) var detailText = "启动后按左、右、上、下自动连续验证；只在边界或异常时等待确认。"
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

    private struct ProbeEvaluation {
        let estimate: GimbalMotionEstimate
        let orthogonalEstimate: GimbalMotionEstimate
        let shiftSign: Int
        let reversesAcceptedDirection: Bool
        let shiftFraction: Double?
        let shiftBelowExpected: Bool
        let disposition: GimbalCalibrationProbeDisposition

        var hasTransientVisualUncertainty: Bool {
            guard disposition == .abortForUnknownPose,
                  GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
                    primaryVerdict: estimate.verdict,
                    orthogonalVerdict: orthogonalEstimate.verdict,
                    reversesAcceptedDirection: reversesAcceptedDirection,
                    shiftBelowExpected: shiftBelowExpected
                  )
            else { return false }
            return true
        }
    }

    private struct ConfirmedMovedEvidence {
        let evaluation: ProbeEvaluation
        let signature: GimbalMotionSignature
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
    private var lastTrustedPoseSignature: GimbalMotionSignature?
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
    private var preCommandRetryCount = 0
    private var preCommandRetryStartedAt: TimeInterval?
    private var measurements: [GimbalCalibrationDirection: GimbalRangeMeasurement] = [:]
    private var safetyArmed = false
    private var appActive = true
    /// App deactivation is a recoverable STOP, not a reason to erase every
    /// direction already measured. The old BLE/camera leases are deliberately
    /// released while inactive and may be renewed only after the operator
    /// returns, re-arms motion safety, and confirms a physical recenter.
    private var recoveringFromAppInactivity = false

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
                    if self.recoveringFromAppInactivity {
                        self.recomputeAvailability()
                        return
                    }
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
                    if self.recoveringFromAppInactivity {
                        self.recomputeAvailability()
                        return
                    }
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
                if self.isRunning,
                   self.cameraSessionID != nil,
                   !status.isRunning {
                    self.pauseForCameraRecovery(
                        "摄像头预览已中断；请恢复当前所选摄像头，并人工回正后继续。"
                    )
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
            if recoveringFromAppInactivity {
                statusText = "全向验证保持安全暂停"
                detailText = "已完成方向仍保留；返回 App 后重新打开运动安全确认、人工回正，再继续当前方向。"
            } else {
                fail("运动安全确认已关闭；本次结果已作废。", sendStop: true)
            }
        }
        recomputeAvailability()
    }

    func setAppActive(_ active: Bool, sendStopOnDisable: Bool = true) {
        appActive = active
        if isRunning, !active {
            pauseForAppInactivity(sendStop: sendStopOnDisable)
        }
        recomputeAvailability()
    }

    /// A focus change or system sheet can transiently make a macOS scene
    /// inactive. STOP immediately and discard only the pose ledger for the
    /// current direction; completed directions remain usable after a physical
    /// recenter. No automatic motion resumes merely because focus returns.
    private func pauseForAppInactivity(sendStop: Bool) {
        guard isRunning else { return }

        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        recoveringFromAppInactivity = true
        manualRecoveryPaused = true

        if let direction = currentDirection {
            resetCurrentDirectionLedger()
            updateProgress(for: direction, proposedExtent: 0)
        } else {
            latestMotionSample = nil
            directionOriginSignature = nil
            lastTrustedPoseSignature = nil
            awaitingStepDecision = false
            awaitingCenterConfirmation = false
            canContinueOutward = false
            canRetryCurrentStep = false
            requiresNoMovementConfirmation = false
            responseText = nil
            centerCheckText = nil
        }

        camera.endMotionCalibration()
        cameraSessionID = nil

        // Clear our lease identifier before ending the controller lease so
        // the synchronous published invalidation is recognized as intentional.
        if let session = bluetoothSessionID {
            bluetoothSessionID = nil
            bluetooth.endRangeCalibration(
                session: session,
                reason: "应用失去焦点：已安全暂停全向验证并保留已完成方向。",
                sendStop: sendStop
            )
        }

        statusText = "应用失去焦点，全向验证已安全暂停"
        detailText = "当前方向已作废，但此前完成方向仍保留；返回后重新打开运动安全确认、人工回正，再继续。"
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
            detailText = "请确认所选摄像头正在预览且人物跟踪已关闭。"
            recomputeAvailability()
            return
        }

        generation &+= 1
        let activeGeneration = generation
        self.bluetoothSessionID = bluetoothSessionID
        self.cameraSessionID = cameraSessionID
        latestMotionSample = nil
        directionOriginSignature = nil
        lastTrustedPoseSignature = nil
        successfulSteps = 0
        physicalSteps = 0
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        directionShiftSign = 0
        acceptedShiftMagnitudes.removeAll(keepingCapacity: true)
        directionNeedsRedo = false
        preCommandRetryCount = 0
        preCommandRetryStartedAt = nil
        measurements.removeAll()
        result = nil
        envelopeIsActive = false
        currentDirection = nil
        currentVerifiedExtentDegrees = 0
        isRunning = true
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        manualRecoveryPaused = false
        recoveringFromAppInactivity = false
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
            guard canRetryCurrentStep || requiresNoMovementConfirmation else { return }
            kind = .unverifiedResponse
        }
        finishDirection(direction, kind: kind)
    }

    /// Re-runs a probe only when the scene changed before the command. Once a
    /// motion command was sent, retrying could compound an unknown pose.
    func retryCurrentStep() {
        guard isRunning,
              sessionsAreValid,
              awaitingStepDecision,
              canRetryCurrentStep,
              let direction = currentDirection
        else { return }
        scheduleProbe(direction)
    }

    /// Continues after the operator has manually returned the gimbal to center.
    /// A focus-loss pause renews its deliberately released leases only after
    /// motion safety is explicitly re-armed. No unknown displacement is ever
    /// folded into the automatic return ledger.
    func confirmManualRecoveryAndRetryCurrentDirection() {
        guard isRunning,
              manualRecoveryPaused
        else { return }

        guard appActive else {
            statusText = "等待返回 OM3 Lab"
            detailText = "App 仍未激活；当前不会发送任何动作。"
            return
        }
        guard safetyArmed, bluetooth.motionSafetyArmed else {
            statusText = "请重新打开运动安全确认"
            detailText = "已完成方向仍保留；确认周围安全并重新解锁后，再确认人工回正。"
            return
        }

        if bluetoothSessionID.map({
            !bluetooth.isRangeCalibrationSessionValid($0)
        }) ?? true {
            guard recoveringFromAppInactivity,
                  let renewedBluetoothSessionID = bluetooth.beginRangeCalibration()
            else {
                fail("BLE 校准会话已失效；无法从人工恢复点继续。", sendStop: true)
                return
            }
            bluetoothSessionID = renewedBluetoothSessionID
        }
        guard camera.status.isRunning else {
            statusText = "等待当前所选摄像头恢复"
            detailText = "恢复真实预览后，再确认人工回正；当前不会发送任何动作。"
            return
        }
        if cameraSessionID == nil
            || cameraSessionID.map({ !camera.isMotionCalibrationSessionValid($0) }) == true {
            camera.endMotionCalibration()
            guard let renewedCameraSessionID = camera.beginMotionCalibration() else {
                statusText = "摄像头分析会话尚未恢复"
                detailText = "请确认预览正在运行且人物跟踪已关闭，然后再次确认人工回正。"
                return
            }
            cameraSessionID = renewedCameraSessionID
            latestMotionSample = nil
        }
        guard sessionsAreValid else {
            statusText = "校准会话尚未全部恢复"
            detailText = "当前不会发送动作；请检查 BLE 与摄像头预览后重试。"
            return
        }

        generation &+= 1
        let activeGeneration = generation
        operationTask?.cancel()
        recoveringFromAppInactivity = false
        guard let direction = currentDirection else {
            manualRecoveryPaused = false
            statusText = "摄像头已恢复，正在重新取得初始基线"
            detailText = "保持云台、摄像头和背景静止；确认稳定前不会发送动作。"
            responseText = nil
            operationTask = Task { [weak self] in
                await self?.prepareBaseline(generation: activeGeneration)
            }
            return
        }
        resetCurrentDirectionLedger()
        updateProgress(for: direction, proposedExtent: 0)
        manualRecoveryPaused = false
        statusText = "正在重新确认人工回正位置"
        detailText = "请保持云台、手机和场景静止；确认新的双轴基线后会重新验证\(direction.title)方向。"
        responseText = nil
        operationTask = Task { [weak self] in
            await self?.prepareRecoveredDirectionBaseline(
                direction,
                generation: activeGeneration
            )
        }
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
        while isCurrent(generation), !Task.isCancelled {
            guard let first = await waitForFreshSample(
                afterSequence: nil,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
            ) else {
                guard isCurrent(generation), !Task.isCancelled else { return }
                statusText = "正在等待所选摄像头帧"
                detailText = "验证会话仍保持；恢复预览后会自动重新取得静止基线，不会退出。"
                continue
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
                guard isCurrent(generation), !Task.isCancelled else { return }
                statusText = "基线帧暂时中断，正在等待恢复"
                detailText = "未发送任何动作；收到连续画面后会自动重试，不会结束全向验证。"
                continue
            }

            let timedBaselineEstimate = await analyzeTranslation(
                reference: first.signature,
                current: last.signature
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            guard timedBaselineEstimate.duration
                    <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration
            else {
                statusText = "画面分析暂时过慢，正在重新取基线"
                detailText = "未发送任何动作；分析恢复后会自动继续，不会退出验证。"
                continue
            }
            let baselineEstimate = timedBaselineEstimate.estimate
            guard case .noResponse = baselineEstimate.horizontal.verdict,
                  case .noResponse = baselineEstimate.vertical.verdict
            else {
                statusText = "正在等待画面稳定"
                detailText = "请保持云台、摄像头和背景静止；稳定后会自动取基线，不会退出或发送动作。"
                continue
            }

            beginDirection(.left)
            return
        }
    }

    private func prepareRecoveredDirectionBaseline(
        _ direction: GimbalCalibrationDirection,
        generation: UInt64
    ) async {
        var afterSequence = latestMotionSample?.sequence
        while isCurrent(generation), !Task.isCancelled {
            guard let first = await waitForFreshSample(
                afterSequence: afterSequence,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
            ) else {
                guard isCurrent(generation), !Task.isCancelled else { return }
                statusText = "人工回正已确认，正在等待摄像头"
                detailText = "未发送动作；当前所选摄像头恢复后会自动重新取基线。"
                continue
            }
            afterSequence = first.sequence

            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(GimbalRangeCalibrationPolicy.baselineDuration)
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            guard let last = await waitForFreshSample(
                afterSequence: first.sequence,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
            ) else {
                statusText = "重新取基线时画面暂时中断"
                detailText = "无需再次确认回正；收到连续画面后会自动重试。"
                continue
            }
            afterSequence = last.sequence

            let timedBaselineEstimate = await analyzeTranslation(
                reference: first.signature,
                current: last.signature
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            guard timedBaselineEstimate.duration
                    <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration
            else {
                statusText = "重新取基线分析较慢，正在自动重试"
                detailText = "未发送动作，也不需要再次点击人工回正确认。"
                continue
            }
            let baselineEstimate = timedBaselineEstimate.estimate
            guard case .noResponse = baselineEstimate.horizontal.verdict,
                  case .noResponse = baselineEstimate.vertical.verdict
            else {
                statusText = "人工回正后正在等待画面稳定"
                detailText = "请保持手机、云台和背景静止；稳定后会自动继续。"
                continue
            }

            directionOriginSignature = last.signature
            statusText = "人工回正基线已确认"
            detailText = "将从 0° 自动重新验证\(direction.title)；此前已完成方向的结果仍保留。"
            scheduleProbe(direction)
            return
        }
    }

    private func resetCurrentDirectionLedger() {
        if let currentDirection {
            measurements.removeValue(forKey: currentDirection)
        }
        currentVerifiedExtentDegrees = 0
        successfulSteps = 0
        physicalSteps = 0
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        directionShiftSign = 0
        acceptedShiftMagnitudes.removeAll(keepingCapacity: true)
        directionNeedsRedo = false
        preCommandRetryCount = 0
        preCommandRetryStartedAt = nil
        directionOriginSignature = nil
        lastTrustedPoseSignature = nil
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        centerCheckText = nil
    }

    private func beginDirection(_ direction: GimbalCalibrationDirection) {
        guard isRunning else { return }
        currentDirection = direction
        resetCurrentDirectionLedger()
        manualRecoveryPaused = false
        recoveringFromAppInactivity = false
        responseText = nil
        // The origin is fixed only after the first probe's two-frame
        // pre-command stillness gate succeeds. An arbitrary latest frame may
        // still contain camera/gimbal motion and must not authorize return.
        directionOriginSignature = nil
        statusText = "准备验证\(direction.title)行程"
        detailText = "每次只移动 \(direction.stepDegrees)°；可信同轴位移会自动继续，随时可按 STOP。"
        scheduleProbe(direction)
    }

    private func scheduleProbe(_ direction: GimbalCalibrationDirection) {
        guard isRunning else { return }
        generation &+= 1
        let activeGeneration = generation
        awaitingStepDecision = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
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
        guard let bluetoothSessionID else { return }
        if !bluetooth.nudgeAvailable {
            statusText = "正在等待动作互锁恢复"
            detailText = "前一个动作或 STOP 尚未完全结束；互锁释放前不会发送新的探测动作。"
        }
        guard await waitForNudgeAvailability(
            timeout: GimbalRangeCalibrationPolicy.commandCompletionTimeout,
            generation: generation
        ) else {
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "动作互锁暂未恢复；本步没有发送，可在互锁就绪后重试。"
            )
            return
        }
        guard let before = await waitForFreshSample(
                afterSequence: nil,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
              ),
              isCurrent(generation)
        else {
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "没有收到新的摄像头帧；本步没有发送，请恢复预览后重试。"
            )
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
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "步前静止检查时画面暂时中断；本步没有发送，请恢复预览后重试。"
            )
            return
        }
        let timedPreCommandEstimate = await analyzeTranslation(
            reference: before.signature,
            current: still.signature
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        let stillFrameAge = ProcessInfo.processInfo.systemUptime
            - still.observedAtUptime
        guard timedPreCommandEstimate.duration
                <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
              stillFrameAge <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge
        else {
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "步前画面分析完成时基线已过期；本步没有发送，请重试。"
            )
            return
        }
        let preCommandEstimate = timedPreCommandEstimate.estimate
        let preCommandDisposition = GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: false,
            primaryVerdict: preCommandEstimate.horizontal.verdict,
            orthogonalVerdict: preCommandEstimate.vertical.verdict
        )
        guard preCommandDisposition == .proceedToCommand else {
            // Nothing was commanded, so a fresh stillness check can be
            // retried automatically without changing the pose or ledger.
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "发送动作前画面仍在变化；保持场景静止后会自动重试。"
            )
            return
        }
        if let trustedPose = lastTrustedPoseSignature {
            let timedPoseContinuity = await analyzeTranslation(
                reference: trustedPose,
                current: still.signature
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            let continuitySampleAge = ProcessInfo.processInfo.systemUptime
                - still.observedAtUptime
            guard timedPoseContinuity.duration
                    <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
                  continuitySampleAge
                    <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge
            else {
                await retryBeforeCommandAutomatically(
                    direction,
                    generation: generation,
                    message: "相邻步骤姿态连续性分析超时或帧已过期；本步未发送。"
                )
                return
            }
            let continuity = timedPoseContinuity.estimate
            guard GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableStationary(
                continuity
            ) else {
                let detectedPoseJump: Bool
                if case .moved = continuity.horizontal.verdict {
                    detectedPoseJump = true
                } else if case .moved = continuity.vertical.verdict {
                    detectedPoseJump = true
                } else {
                    detectedPoseJump = false
                }
                if detectedPoseJump {
                    pauseForManualRecovery(
                        direction: direction,
                        bluetoothSessionID: bluetoothSessionID,
                        reason: "两步之间检测到未记账的姿态变化，可能有人碰动云台、支架或手机。"
                    )
                } else {
                    await retryBeforeCommandAutomatically(
                        direction,
                        generation: generation,
                        message: "暂时无法确认与上一步可信姿态一致；本步未发送，将重新取帧。"
                    )
                }
                return
            }
        } else {
            lastTrustedPoseSignature = still.signature
        }
        if directionOriginSignature == nil {
            directionOriginSignature = still.signature
        }

        statusText = "\(direction.title)探测至约 \(targetExtent)°"
        detailText = "正在发送单步动作；请随时观察碰撞、异响和线缆拉扯。"
        responseText = nil

        // Every probe re-checks the interlock immediately before submission.
        // The calibration lease excludes other motion, but this second wait
        // also closes the race with an asynchronous STOP/safety transition.
        guard await waitForNudgeAvailability(
            timeout: GimbalRangeCalibrationPolicy.commandCompletionTimeout,
            generation: generation
        ) else {
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "发送前动作互锁暂未恢复；本步没有发送，可在互锁就绪后重试。"
            )
            return
        }
        let submitted = bluetooth.sendRangeCalibrationNudge(
            yawDegrees: direction.yawDegrees,
            pitchDegrees: direction.pitchDegrees,
            label: "全向验证 · \(direction.title) \(direction.stepDegrees)°",
            session: bluetoothSessionID
        )
        guard submitted else {
            await retryBeforeCommandAutomatically(
                direction,
                generation: generation,
                message: "本步未能进入 BLE 发送队列，因此没有改变姿态；连接和互锁就绪后可重试。"
            )
            return
        }
        preCommandRetryCount = 0
        preCommandRetryStartedAt = nil

        guard await waitForNudgeCompletion(
            timeout: GimbalRangeCalibrationPolicy.commandCompletionTimeout,
            generation: generation
        ) else {
            guard isCurrent(generation) else { return }
            await recoverPostCommandObservation(
                direction: direction,
                reference: still.signature,
                afterSequence: latestMotionSample?.sequence ?? still.sequence,
                targetExtent: targetExtent,
                bluetoothSessionID: bluetoothSessionID,
                generation: generation,
                completedObservationAttempts: 0,
                stopAlreadyAccepted: false,
                automaticMovedAcceptanceAllowed: false,
                reason: "动作已提交但互锁完成状态超时"
            )
            return
        }
        let settleStartSequence = latestMotionSample?.sequence ?? still.sequence
        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(
                GimbalRangeCalibrationPolicy.postCommandSettleDuration
            )
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        guard let after = await waitForFreshSample(
                afterSequence: settleStartSequence,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
              ) else {
            guard isCurrent(generation) else { return }
            await recoverPostCommandObservation(
                direction: direction,
                reference: still.signature,
                afterSequence: settleStartSequence,
                targetExtent: targetExtent,
                bluetoothSessionID: bluetoothSessionID,
                generation: generation,
                completedObservationAttempts: 0,
                stopAlreadyAccepted: false,
                automaticMovedAcceptanceAllowed: false,
                reason: "动作后摄像头帧暂时中断"
            )
            return
        }

        let timedTranslationEstimate = await analyzeTranslation(
            reference: still.signature,
            current: after.signature
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        let analyzedSampleAge = ProcessInfo.processInfo.systemUptime
            - after.observedAtUptime
        guard timedTranslationEstimate.duration
                <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
              analyzedSampleAge <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge
        else {
            await recoverPostCommandObservation(
                direction: direction,
                reference: still.signature,
                afterSequence: after.sequence,
                targetExtent: targetExtent,
                bluetoothSessionID: bluetoothSessionID,
                generation: generation,
                completedObservationAttempts: 0,
                stopAlreadyAccepted: false,
                automaticMovedAcceptanceAllowed: true,
                reason: "动作后的首次画面分析超时或帧已过期"
            )
            return
        }
        let translationEstimate = timedTranslationEstimate.estimate
        let estimate = direction.axis == .horizontal
            ? translationEstimate.horizontal
            : translationEstimate.vertical
        let orthogonalEstimate = direction.axis == .horizontal
            ? translationEstimate.vertical
            : translationEstimate.horizontal
        let evaluation = makeProbeEvaluation(
            estimate: estimate,
            orthogonalEstimate: orthogonalEstimate
        )
        await processProbeEvaluation(
            direction,
            evaluation: evaluation,
            reference: still.signature,
            observationSignature: after.signature,
            afterSequence: after.sequence,
            targetExtent: targetExtent,
            bluetoothSessionID: bluetoothSessionID,
            generation: generation,
            observationAttempt: 1,
            stopAlreadyAccepted: false,
            automaticMovedAcceptanceAllowed: true
        )
    }

    private func makeProbeEvaluation(
        estimate: GimbalMotionEstimate,
        orthogonalEstimate: GimbalMotionEstimate
    ) -> ProbeEvaluation {
        let shiftSign = estimate.axisShift >= 0 ? 1 : -1
        let reversesAcceptedDirection: Bool
        if case .moved = estimate.verdict {
            reversesAcceptedDirection = directionShiftSign != 0
                && shiftSign != directionShiftSign
        } else {
            reversesAcceptedDirection = false
        }
        let shiftFraction: Double?
        if case .moved = estimate.verdict,
           acceptedShiftMagnitudes.count >= 2 {
            let expected = Double(medianAcceptedShiftMagnitude)
            shiftFraction = Double(abs(estimate.axisShift)) / max(expected, 1)
        } else {
            shiftFraction = nil
        }
        let shiftBelowExpected = shiftFraction.map {
            $0 < GimbalRangeCalibrationPolicy.minimumShiftFractionOfExpected
        } ?? false
        let disposition = GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: true,
            primaryVerdict: estimate.verdict,
            orthogonalVerdict: orthogonalEstimate.verdict,
            reversesAcceptedDirection: reversesAcceptedDirection,
            shiftBelowExpected: shiftBelowExpected
        )
        return ProbeEvaluation(
            estimate: estimate,
            orthogonalEstimate: orthogonalEstimate,
            shiftSign: shiftSign,
            reversesAcceptedDirection: reversesAcceptedDirection,
            shiftFraction: shiftFraction,
            shiftBelowExpected: shiftBelowExpected,
            disposition: disposition
        )
    }

    private func processProbeEvaluation(
        _ direction: GimbalCalibrationDirection,
        evaluation: ProbeEvaluation,
        reference: GimbalMotionSignature,
        observationSignature: GimbalMotionSignature,
        afterSequence: UInt64,
        targetExtent: Int,
        bluetoothSessionID: UUID,
        generation: UInt64,
        observationAttempt: Int,
        stopAlreadyAccepted: Bool,
        automaticMovedAcceptanceAllowed: Bool
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        let action = GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: evaluation.disposition,
            transientVisualUncertainty: evaluation.hasTransientVisualUncertainty,
            observationAttempt: observationAttempt
        )

        switch action {
        case .acceptMovedStep:
            guard automaticMovedAcceptanceAllowed else {
                pauseForManualRecovery(
                    direction: direction,
                    bluetoothSessionID: bluetoothSessionID,
                    reason: "动作完成状态曾超时；即使看到位移，也不能自动按完整一步记账。",
                    stopAlreadyAccepted: stopAlreadyAccepted
                )
                return
            }
            guard let confirmedEvidence = await confirmAutomaticMovedEvidence(
                direction: direction,
                firstEvaluation: evaluation,
                reference: reference,
                firstObservation: observationSignature,
                afterSequence: afterSequence,
                generation: generation
            ) else {
                await recoverPostCommandObservation(
                    direction: direction,
                    reference: reference,
                    afterSequence: afterSequence,
                    targetExtent: targetExtent,
                    bluetoothSessionID: bluetoothSessionID,
                    generation: generation,
                    completedObservationAttempts: observationAttempt,
                    stopAlreadyAccepted: stopAlreadyAccepted,
                    automaticMovedAcceptanceAllowed: true,
                    reason: "自动记账需要两份一致且帧间静止的高置信度画面"
                )
                return
            }
            let confirmedEvaluation = confirmedEvidence.evaluation
            pendingVerdict = .moved
            pendingShiftSign = confirmedEvaluation.shiftSign
            pendingShiftMagnitude = (
                abs(evaluation.estimate.axisShift)
                    + abs(confirmedEvaluation.estimate.axisShift)
            ) / 2
            lastTrustedPoseSignature = confirmedEvidence.signature
            acceptPendingMovedStep(direction)
            updateProgress(for: direction, proposedExtent: currentVerifiedExtentDegrees)
            if currentVerifiedExtentDegrees >= direction.probeLimitDegrees {
                finishDirection(direction, kind: .engineeringCap)
                return
            }
            statusText = "已自动确认\(direction.title) \(currentVerifiedExtentDegrees)°"
            responseText = "摄像头连续检测到可信同轴位移；即将自动验证下一步，随时可按 STOP。"
            detailText = "正常步进无需点击；边界无响应、回正不一致或姿态冲突时才会暂停。"
            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(
                    GimbalRangeCalibrationPolicy.automaticStepAdvanceDelay
                )
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            scheduleProbe(direction)

        case .requestNoMovementConfirmation:
            let stopAccepted = stopAlreadyAccepted
                || bluetooth.stopRangeCalibrationMotion(
                    session: bluetoothSessionID,
                    reason: "自检无响应 STOP"
                )
            guard stopAccepted, sessionsAreValid else {
                fail(
                    "动作无响应且 STOP 未被可靠接受或校准会话已失效；验证已终止，请立即人工回正。",
                    sendStop: true
                )
                return
            }
            presentStepDecision(
                verdict: .noResponse,
                retryAllowed: false,
                requiresPhysicalNoMovementConfirmation: true,
                status: "\(direction.title)无可验证响应，已 STOP",
                response: "禁止重试或继续向外。请现场确认实体确实完全未移动；确认后只会按此前已验证路径返程。若不能确认，请取消并人工回正。"
            )
            updateProgress(for: direction, proposedExtent: targetExtent)

        case .resampleObservation:
            await recoverPostCommandObservation(
                direction: direction,
                reference: reference,
                afterSequence: afterSequence,
                targetExtent: targetExtent,
                bluetoothSessionID: bluetoothSessionID,
                generation: generation,
                completedObservationAttempts: observationAttempt,
                stopAlreadyAccepted: stopAlreadyAccepted,
                automaticMovedAcceptanceAllowed: automaticMovedAcceptanceAllowed,
                reason: "动作后的画面证据暂时不稳定"
            )

        case .pauseForManualRecovery:
            let reason = unknownPoseReason(
                estimate: evaluation.estimate,
                orthogonalEstimate: evaluation.orthogonalEstimate,
                reversesAcceptedDirection: evaluation.reversesAcceptedDirection,
                shiftFraction: evaluation.shiftFraction
            )
            pauseForManualRecovery(
                direction: direction,
                bluetoothSessionID: bluetoothSessionID,
                reason: reason,
                stopAlreadyAccepted: stopAlreadyAccepted
            )
        }
    }

    private func confirmAutomaticMovedEvidence(
        direction: GimbalCalibrationDirection,
        firstEvaluation: ProbeEvaluation,
        reference: GimbalMotionSignature,
        firstObservation: GimbalMotionSignature,
        afterSequence: UInt64,
        generation: UInt64
    ) async -> ConfirmedMovedEvidence? {
        guard GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
            primary: firstEvaluation.estimate,
            orthogonal: firstEvaluation.orthogonalEstimate,
            axis: direction.axis
        ) else { return nil }

        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(
                GimbalRangeCalibrationPolicy.postCommandObservationGap
            )
        )
        guard isCurrent(generation), !Task.isCancelled,
              let secondSample = await waitForFreshSample(
                afterSequence: afterSequence,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
              )
        else { return nil }

        async let referenceEstimateTask = analyzeTranslation(
            reference: reference,
            current: secondSample.signature
        )
        async let interFrameEstimateTask = analyzeTranslation(
            reference: firstObservation,
            current: secondSample.signature
        )
        let (referenceEstimate, interFrameEstimate) = await (
            referenceEstimateTask,
            interFrameEstimateTask
        )
        guard isCurrent(generation), !Task.isCancelled else { return nil }
        let sampleAge = ProcessInfo.processInfo.systemUptime
            - secondSample.observedAtUptime
        guard referenceEstimate.duration
                <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
              interFrameEstimate.duration
                <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
              sampleAge <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge,
              GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableStationary(
                interFrameEstimate.estimate
              )
        else { return nil }

        let secondTranslation = referenceEstimate.estimate
        let secondEstimate = direction.axis == .horizontal
            ? secondTranslation.horizontal
            : secondTranslation.vertical
        let secondOrthogonalEstimate = direction.axis == .horizontal
            ? secondTranslation.vertical
            : secondTranslation.horizontal
        guard GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
                primary: secondEstimate,
                orthogonal: secondOrthogonalEstimate,
                axis: direction.axis
              ),
              GimbalRangeCalibrationAutomaticEvidencePolicy
                .movedObservationsAreConsistent(
                    firstEvaluation.estimate,
                    secondEstimate
                )
        else { return nil }

        let secondEvaluation = makeProbeEvaluation(
            estimate: secondEstimate,
            orthogonalEstimate: secondOrthogonalEstimate
        )
        guard secondEvaluation.disposition == .awaitMovedStepConfirmation else {
            return nil
        }
        return ConfirmedMovedEvidence(
            evaluation: secondEvaluation,
            signature: secondSample.signature
        )
    }

    /// A queued probe is never submitted again automatically. Recovery sends
    /// STOP once, then only waits for a newer frame and re-runs registration
    /// against the exact pre-command checkpoint.
    private func recoverPostCommandObservation(
        direction: GimbalCalibrationDirection,
        reference: GimbalMotionSignature,
        afterSequence: UInt64,
        targetExtent: Int,
        bluetoothSessionID: UUID,
        generation: UInt64,
        completedObservationAttempts: Int,
        stopAlreadyAccepted: Bool,
        automaticMovedAcceptanceAllowed: Bool,
        reason: String
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        let stopAccepted = stopAlreadyAccepted
            || bluetooth.stopRangeCalibrationMotion(
                session: bluetoothSessionID,
                reason: "动作后只观察恢复 STOP"
            )
        guard stopAccepted, sessionsAreValid else {
            fail(
                "动作后画面不确定，且 STOP 未被可靠接受或校准会话已失效；验证已终止，请立即人工回正。",
                sendStop: true
            )
            return
        }
        guard await waitForNudgeAvailability(
            timeout: GimbalRangeCalibrationPolicy.commandCompletionTimeout,
            generation: generation
        ) else {
            guard isCurrent(generation) else { return }
            pauseForManualRecovery(
                direction: direction,
                bluetoothSessionID: bluetoothSessionID,
                reason: "STOP 后动作互锁未恢复，不能自动判断静止姿态。",
                stopAlreadyAccepted: true
            )
            return
        }

        let nextAttempt = completedObservationAttempts + 1
        guard nextAttempt <= GimbalRangeCalibrationPolicy.postCommandObservationAttempts else {
            pauseForManualRecovery(
                direction: direction,
                bluetoothSessionID: bluetoothSessionID,
                reason: "\(reason)，自动重新取样次数已用尽。",
                stopAlreadyAccepted: true
            )
            return
        }

        awaitingStepDecision = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        statusText = "已 STOP，正在自动重新判断本步"
        detailText = "只重新取画面，不会再次发送探测动作（第 \(nextAttempt)/\(GimbalRangeCalibrationPolicy.postCommandObservationAttempts) 次）。"
        responseText = reason
        try? await Task.sleep(
            nanoseconds: Self.nanoseconds(
                GimbalRangeCalibrationPolicy.postCommandObservationGap
            )
        )
        guard isCurrent(generation), !Task.isCancelled else { return }

        guard let sample = await waitForFreshSample(
            afterSequence: afterSequence,
            timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
            generation: generation
        ) else {
            await recoverPostCommandObservation(
                direction: direction,
                reference: reference,
                afterSequence: afterSequence,
                targetExtent: targetExtent,
                bluetoothSessionID: bluetoothSessionID,
                generation: generation,
                completedObservationAttempts: nextAttempt,
                stopAlreadyAccepted: true,
                automaticMovedAcceptanceAllowed: automaticMovedAcceptanceAllowed,
                reason: "STOP 后仍未收到新的摄像头帧"
            )
            return
        }

        let timedEstimate = await analyzeTranslation(
            reference: reference,
            current: sample.signature
        )
        guard isCurrent(generation), !Task.isCancelled else { return }
        let analyzedSampleAge = ProcessInfo.processInfo.systemUptime
            - sample.observedAtUptime
        guard timedEstimate.duration
                <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
              analyzedSampleAge <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge
        else {
            await recoverPostCommandObservation(
                direction: direction,
                reference: reference,
                afterSequence: sample.sequence,
                targetExtent: targetExtent,
                bluetoothSessionID: bluetoothSessionID,
                generation: generation,
                completedObservationAttempts: nextAttempt,
                stopAlreadyAccepted: true,
                automaticMovedAcceptanceAllowed: automaticMovedAcceptanceAllowed,
                reason: "STOP 后画面分析仍然超时或帧已过期"
            )
            return
        }

        let translation = timedEstimate.estimate
        let estimate = direction.axis == .horizontal
            ? translation.horizontal
            : translation.vertical
        let orthogonalEstimate = direction.axis == .horizontal
            ? translation.vertical
            : translation.horizontal
        let evaluation = makeProbeEvaluation(
            estimate: estimate,
            orthogonalEstimate: orthogonalEstimate
        )
        await processProbeEvaluation(
            direction,
            evaluation: evaluation,
            reference: reference,
            observationSignature: sample.signature,
            afterSequence: sample.sequence,
            targetExtent: targetExtent,
            bluetoothSessionID: bluetoothSessionID,
            generation: generation,
            observationAttempt: nextAttempt,
            stopAlreadyAccepted: true,
            automaticMovedAcceptanceAllowed: automaticMovedAcceptanceAllowed
        )
    }

    private func pauseForManualRecovery(
        direction: GimbalCalibrationDirection,
        bluetoothSessionID: UUID,
        reason: String,
        stopAlreadyAccepted: Bool = false
    ) {
        let stopAccepted = stopAlreadyAccepted
            || bluetooth.stopRangeCalibrationMotion(
                session: bluetoothSessionID,
                reason: "姿态未知，等待人工回正 STOP"
            )
        let recoveryAction = GimbalRangeCalibrationRecoveryPolicy.action(
            stopAccepted: stopAccepted,
            sessionsAreValid: sessionsAreValid
        )
        guard recoveryAction == .pauseForManualRecovery else {
            fail(
                "动作后姿态未知，且 STOP 未被可靠接受或校准会话已失效；验证已终止，请立即人工回正。",
                sendStop: true
            )
            return
        }

        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        manualRecoveryPaused = true
        recoveringFromAppInactivity = false
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        responseText = "\(reason) 已 STOP；不会按未知账本自动重试或返程。"
        centerCheckText = nil
        statusText = "\(direction.title)验证已暂停，等待人工回正"
        detailText = "请人工将云台回到本轮开始时的中心位置。确认后只清空并重试当前方向，已完成方向会保留。"
    }

    /// A Continuity Camera interruption invalidates the camera lease but does
    /// not have to erase directions that were already verified. STOP remains
    /// mandatory; resuming later always requires a new camera lease and an
    /// explicit physical recenter confirmation.
    private func pauseForCameraRecovery(_ reason: String) {
        guard isRunning,
              let bluetoothSessionID,
              bluetooth.isRangeCalibrationSessionValid(bluetoothSessionID)
        else {
            fail("摄像头中断且 BLE 校准会话已失效；验证已终止，请立即人工回正。", sendStop: true)
            return
        }
        let stopAccepted = bluetooth.stopRangeCalibrationMotion(
            session: bluetoothSessionID,
            reason: "摄像头中断，等待人工恢复 STOP"
        )
        guard stopAccepted else {
            fail("摄像头中断且 STOP 未被可靠接受；验证已终止，请立即人工回正。", sendStop: true)
            return
        }

        generation &+= 1
        operationTask?.cancel()
        operationTask = nil
        camera.endMotionCalibration()
        cameraSessionID = nil
        latestMotionSample = nil
        manualRecoveryPaused = true
        recoveringFromAppInactivity = false
        awaitingStepDecision = false
        awaitingCenterConfirmation = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        pendingVerdict = nil
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        responseText = "\(reason) 已发送 STOP；不会自动重试、返程或清空已完成方向。"
        centerCheckText = nil
        statusText = "摄像头已中断，验证暂停"
        detailText = "恢复当前所选摄像头后，人工将云台回正，再从当前方向重新验证。"
    }

    private func unknownPoseReason(
        estimate: GimbalMotionEstimate,
        orthogonalEstimate: GimbalMotionEstimate,
        reversesAcceptedDirection: Bool,
        shiftFraction: Double?
    ) -> String {
        let reasonText: String
        if case let .inconclusive(analyzerReason) = estimate.verdict {
            // Keep the analyzer's concrete failure reason visible to the
            // operator while appending the numeric registration evidence.
            reasonText = "主轴画面判断不可靠（\(analyzerReason)）。"
        } else if case .moved = orthogonalEstimate.verdict {
            reasonText = "检测到正交轴位移，装置可能被碰动或支架松动。"
        } else if case let .inconclusive(orthogonalReason) = orthogonalEstimate.verdict {
            reasonText = "正交轴画面判断不可靠（\(orthogonalReason)）。"
        } else if reversesAcceptedDirection {
            reasonText = "本步位移方向与此前相反，可能发生回弹、二次居中或误检。"
        } else if let shiftFraction,
                  shiftFraction < GimbalRangeCalibrationPolicy.minimumShiftFractionOfExpected {
            reasonText = "已检测到实体位移，但幅度仅约为此前每步的 \(Int(shiftFraction * 100))%，实际姿态不能由整步账本还原。"
        } else {
            reasonText = "动作结果无法由已验证步数安全还原。"
        }
        let diagnostics = String(
            format: "视觉数据：主轴 %+d px / residual %.3f / confidence %.2f；正交 %+d px / residual %.3f / confidence %.2f。",
            estimate.axisShift,
            estimate.bestError,
            estimate.confidence,
            orthogonalEstimate.axisShift,
            orthogonalEstimate.bestError,
            orthogonalEstimate.confidence
        )
        return "\(reasonText) \(diagnostics)"
    }

    private func presentStepDecision(
        verdict: PendingVerdict,
        retryAllowed: Bool,
        requiresPhysicalNoMovementConfirmation: Bool,
        status: String,
        response: String
    ) {
        pendingVerdict = verdict
        pendingShiftSign = 0
        pendingShiftMagnitude = 0
        awaitingStepDecision = true
        canContinueOutward = false
        canRetryCurrentStep = retryAllowed
        requiresNoMovementConfirmation = requiresPhysicalNoMovementConfirmation
        statusText = status
        responseText = response
        detailText = "正常同轴步进会自动继续；只有边界无响应或姿态不确定时需要现场确认。"
    }

    private func retryBeforeCommandAutomatically(
        _ direction: GimbalCalibrationDirection,
        generation: UInt64,
        message: String
    ) async {
        guard isCurrent(generation), !Task.isCancelled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if preCommandRetryStartedAt == nil {
            preCommandRetryStartedAt = now
        }
        preCommandRetryCount += 1
        let retryDuration = now - (preCommandRetryStartedAt ?? now)
        if preCommandRetryCount >= GimbalRangeCalibrationPolicy.preCommandRetryMaximumAttempts
            || retryDuration >= GimbalRangeCalibrationPolicy.preCommandRetryMaximumDuration {
            presentStepDecision(
                verdict: .inconclusive,
                retryAllowed: true,
                requiresPhysicalNoMovementConfirmation: false,
                status: "\(direction.title)自动等待已达上限",
                response: "本步始终没有发送，姿态账本仍然可信。可再次重试，或按已确认路径结束本方向并返程。"
            )
            return
        }
        let exponent = Double(min(max(0, preCommandRetryCount - 1), 4))
        let delay = min(
            GimbalRangeCalibrationPolicy.preCommandRetryMaximumDelay,
            GimbalRangeCalibrationPolicy.preCommandRetryInitialDelay * pow(2, exponent)
        )
        awaitingStepDecision = false
        canContinueOutward = false
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        pendingVerdict = nil
        statusText = "\(direction.title)探测条件未就绪，正在自动等待"
        detailText = "本步尚未发送，不会改变姿态；约 \(String(format: "%.1f", delay)) 秒后自动重新取帧。"
        responseText = message
        try? await Task.sleep(nanoseconds: Self.nanoseconds(delay))
        guard isCurrent(generation), !Task.isCancelled else { return }
        scheduleProbe(direction)
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
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
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
            canRetryCurrentStep = false
            requiresNoMovementConfirmation = false
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
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
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
        detailText = "返程后会用连续画面复核起点；匹配成功会自动进入下一方向。"

        // The return aggregates verified steps into larger relative moves at
        // the same angular rate as the probes (stepDegrees per second), which
        // cuts several interlock waits per direction.
        var remainingDegrees = physicalSteps * direction.stepDegrees
        var returnPreparationFailures = 0
        let returnPreparationStartedAt = ProcessInfo.processInfo.systemUptime
        func preparationBudgetIsExhausted() -> Bool {
            returnPreparationFailures += 1
            return returnPreparationFailures
                    >= GimbalRangeCalibrationPolicy.returnPreparationMaximumFailures
                || ProcessInfo.processInfo.systemUptime - returnPreparationStartedAt
                    >= GimbalRangeCalibrationPolicy.returnPreparationMaximumDuration
        }
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
                guard isCurrent(generation) else { return }
                guard sessionsAreValid else {
                    fail("返程前校准会话已失效；验证已终止。", sendStop: true)
                    return
                }
                if preparationBudgetIsExhausted() {
                    pauseForManualRecovery(
                        direction: direction,
                        bluetoothSessionID: bluetoothSessionID,
                        reason: "返程块尚未发送，但动作互锁连续未恢复；已停止自动等待。"
                    )
                    return
                }
                statusText = "返程互锁暂忙，正在自动等待"
                detailText = "当前返程块尚未发送，账本未改变；互锁恢复后会自动继续。"
                try? await Task.sleep(nanoseconds: Self.nanoseconds(0.5))
                continue
            }
            let submitted = bluetooth.sendRangeCalibrationNudge(
                yawDegrees: yawSign * chunkDegrees,
                pitchDegrees: pitchSign * chunkDegrees,
                durationTenths: durationTenths,
                label: "全向验证返程 · \(direction.title) 剩余 \(remainingDegrees)°",
                session: bluetoothSessionID
            )
            guard submitted else {
                guard isCurrent(generation) else { return }
                guard sessionsAreValid else {
                    fail("返程块未入队且校准会话已失效；验证已终止。", sendStop: true)
                    return
                }
                if preparationBudgetIsExhausted() {
                    pauseForManualRecovery(
                        direction: direction,
                        bluetoothSessionID: bluetoothSessionID,
                        reason: "返程块连续未能进入发送队列；已停止自动重试。"
                    )
                    return
                }
                statusText = "返程块未入队，正在自动重试"
                detailText = "未发送任何动作，剩余返程角度保持 \(remainingDegrees)°。"
                try? await Task.sleep(nanoseconds: Self.nanoseconds(0.5))
                continue
            }
            guard await waitForNudgeCompletion(
                    timeout: motionTimeout,
                    generation: generation
                  ) else {
                guard isCurrent(generation) else { return }
                pauseForManualRecovery(
                    direction: direction,
                    bluetoothSessionID: bluetoothSessionID,
                    reason: "返程动作未能可靠完成，当前姿态需要人工重新建立。"
                )
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
        let originAutomaticallyVerified: Bool
        if let origin = directionOriginSignature {
            originAutomaticallyVerified = await verifyReturnOrigin(
                reference: origin,
                initialSample: settledSample,
                generation: generation
            )
        } else {
            originAutomaticallyVerified = false
        }
        guard isCurrent(generation), !Task.isCancelled else { return }

        successfulSteps = 0
        physicalSteps = 0
        currentVerifiedExtentDegrees = 0
        awaitingCenterConfirmation = true
        updateProgress(for: direction, proposedExtent: direction.probeLimitDegrees)
        if originAutomaticallyVerified {
            centerCheckText = "连续画面与本方向起点一致，已自动确认返程。"
            statusText = "已自动确认回到\(direction.title)起点"
            detailText = "即将自动进入下一方向；如现场观察异常请立即按 STOP。"
            try? await Task.sleep(
                nanoseconds: Self.nanoseconds(
                    GimbalRangeCalibrationPolicy.automaticStepAdvanceDelay
                )
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            confirmReturnedToCenter()
        } else {
            measurements.removeValue(forKey: direction)
            directionNeedsRedo = true
            centerCheckText = "连续画面未能可靠匹配本方向起点，请检查实体姿态。"
            statusText = "返程复核不确定，请确认云台起点"
            detailText = "自动复核已重试多次；人工回正确认后只会重做当前方向，已完成方向保留。"
        }
    }

    private func verifyReturnOrigin(
        reference: GimbalMotionSignature,
        initialSample: GimbalMotionFrameSample?,
        generation: UInt64
    ) async -> Bool {
        var nextSample = initialSample
        var afterSequence = initialSample?.sequence ?? latestMotionSample?.sequence
        var consecutiveMatches = 0
        var previousMatchingSample: GimbalMotionFrameSample?

        for attempt in 0..<GimbalRangeCalibrationPolicy.returnOriginObservationAttempts {
            guard isCurrent(generation), !Task.isCancelled else { return false }
            if attempt > 0 {
                try? await Task.sleep(
                    nanoseconds: Self.nanoseconds(
                        GimbalRangeCalibrationPolicy.postCommandObservationGap
                    )
                )
            }
            let sample: GimbalMotionFrameSample
            if let nextSample {
                sample = nextSample
            } else if let fresh = await waitForFreshSample(
                afterSequence: afterSequence,
                timeout: GimbalRangeCalibrationPolicy.sampleTimeout,
                generation: generation
            ) {
                sample = fresh
            } else {
                consecutiveMatches = 0
                previousMatchingSample = nil
                continue
            }
            nextSample = nil
            afterSequence = sample.sequence

            let timedEstimate = await analyzeTranslation(
                reference: reference,
                current: sample.signature
            )
            guard isCurrent(generation), !Task.isCancelled else { return false }
            let sampleAge = ProcessInfo.processInfo.systemUptime
                - sample.observedAtUptime
            guard timedEstimate.duration
                    <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
                  sampleAge <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge,
                  GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableStationary(
                    timedEstimate.estimate
                  )
            else {
                consecutiveMatches = 0
                previousMatchingSample = nil
                continue
            }

            if let previousSample = previousMatchingSample {
                let interFrameEstimate = await analyzeTranslation(
                    reference: previousSample.signature,
                    current: sample.signature
                )
                guard isCurrent(generation), !Task.isCancelled else { return false }
                let ageAfterInterFrameAnalysis = ProcessInfo.processInfo.systemUptime
                    - sample.observedAtUptime
                guard interFrameEstimate.duration
                        <= GimbalRangeCalibrationPolicy.maximumAnalysisDuration,
                      ageAfterInterFrameAnalysis
                        <= GimbalRangeCalibrationPolicy.maximumFreshSampleAge,
                      GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableStationary(
                        interFrameEstimate.estimate
                      )
                else {
                    // The current frame matches the origin, but the pair was
                    // not stationary. It can only become the first sample of
                    // a new consecutive pair, never complete the old pair.
                    consecutiveMatches = 1
                    previousMatchingSample = sample
                    continue
                }
                consecutiveMatches += 1
            } else {
                consecutiveMatches = 1
            }
            previousMatchingSample = sample
            if consecutiveMatches
                >= GimbalRangeCalibrationPolicy.returnOriginRequiredMatches {
                return true
            }
        }
        return false
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
        // Validate against the shared OM3 sanity ceiling while the sessions are
        // still alive:
        // once they are torn down, a failed install can no longer route its
        // STOP through the calibration lease.
        guard OM3HardwareMotionLimits.isValidCalibratedTrackingEnvelope(envelope) else {
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
                reason: "四向行程验证完成，返程已由连续画面或人工确认。",
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
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        manualRecoveryPaused = false
        recoveringFromAppInactivity = false
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
        lastTrustedPoseSignature = nil
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
        canRetryCurrentStep = false
        requiresNoMovementConfirmation = false
        manualRecoveryPaused = false
        recoveringFromAppInactivity = false
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

    /// Registration is CPU-bound. Keep it off the main actor so camera/BLE
    /// state changes and an operator STOP are never queued behind image work.
    private func analyzeTranslation(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature
    ) async -> TimedGimbalMotionVectorEstimate {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let estimate = await Task.detached(priority: .userInitiated) {
            GimbalMotionAnalysis.estimateTranslation(
                reference: reference,
                current: current
            )
        }.value
        return TimedGimbalMotionVectorEstimate(
            estimate: estimate,
            duration: ProcessInfo.processInfo.systemUptime - startedAt
        )
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
