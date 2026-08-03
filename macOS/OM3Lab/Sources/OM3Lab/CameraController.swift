@preconcurrency import AVFoundation
import Foundation

struct CameraDeviceDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum CameraSelectionPolicy {
    /// Automatic selection is exact-ID only. The remembered display name is
    /// informational and must never make a different physical camera an
    /// implicit fallback.
    static func rememberedDevice(
        in devices: [CameraDeviceDescriptor],
        rememberedID: String?
    ) -> CameraDeviceDescriptor? {
        guard let rememberedID else { return nil }
        return devices.first(where: { $0.id == rememberedID })
    }

    static func initialSelection(
        from devices: [CameraDeviceDescriptor],
        rememberedID: String?
    ) -> String? {
        rememberedDevice(in: devices, rememberedID: rememberedID)?.id
    }

    static func runningDeviceAction(
        runningDeviceID: String?,
        selectedDeviceID: String?,
        userStopped: Bool
    ) -> CameraRunningDeviceAction {
        guard let runningDeviceID else { return .none }
        guard !userStopped else { return .stop }
        guard let selectedDeviceID else { return .stop }
        if runningDeviceID == selectedDeviceID {
            return .none
        }
        return .switchTo(selectedDeviceID)
    }
}

enum CameraRunningDeviceAction: Equatable {
    case none
    case switchTo(String)
    case stop
}

enum CameraAutomaticRetryPolicy {
    /// Five retries after the initial attempt, capped at an eight-second wait.
    /// A fresh device connection or an explicit refresh restores this budget.
    static let delaysMilliseconds: [UInt64] = [500, 1_000, 2_000, 4_000, 8_000]

    static func delayMilliseconds(afterFailure failureCount: Int) -> UInt64? {
        guard failureCount > 0,
              failureCount <= delaysMilliseconds.count
        else { return nil }
        return delaysMilliseconds[failureCount - 1]
    }
}

enum CameraStartEventPolicy {
    static func acceptsRunningEvent(
        generation: UInt64,
        deviceID: String,
        activeGeneration: UInt64?,
        activeDeviceID: String?,
        selectedDeviceID: String?
    ) -> Bool {
        generation == activeGeneration
            && deviceID == activeDeviceID
            && deviceID == selectedDeviceID
    }

    static func acceptsStoppedEvent(
        generation: UInt64?,
        activeGeneration: UInt64?,
        commandGeneration: UInt64
    ) -> Bool {
        if let generation {
            return generation == commandGeneration
        }
        return activeGeneration == nil
    }

    static func acceptsErrorEvent(
        generation: UInt64?,
        activeGeneration: UInt64?,
        commandGeneration: UInt64
    ) -> Bool {
        if let activeGeneration {
            return generation == activeGeneration
        }
        if let generation {
            return generation == commandGeneration
        }
        return true
    }
}

enum CameraStatus: Equatable {
    case idle
    case requestingPermission
    case configuring
    case stopping
    case running(String)
    case stopped
    case denied
    case error(String)

    var title: String {
        switch self {
        case .idle: return "摄像头尚未启用"
        case .requestingPermission: return "正在请求摄像头权限"
        case .configuring: return "正在配置摄像头"
        case .stopping: return "正在停止摄像头"
        case let .running(name): return "正在预览 \(name)"
        case .stopped: return "预览已停止"
        case .denied: return "未获摄像头权限"
        case let .error(message): return message
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

private enum CameraEngineEvent: Sendable {
    case devices([CameraDeviceDescriptor])
    case running(generation: UInt64, id: String, name: String)
    case interruptionEnded(generation: UInt64, id: String)
    case personSample(PersonVisionSample)
    case motionSample(GimbalMotionFrameSample)
    case stopped(generation: UInt64?)
    case error(
        generation: UInt64?,
        message: String,
        runningDeviceID: String?,
        allowsAutomaticRetry: Bool
    )
}

private final class CameraCaptureEngine: @unchecked Sendable {
    private struct InputSnapshot: Sendable {
        let deviceID: String?
        let generation: UInt64?
    }

    private struct CenterStageSnapshot {
        let controlMode: AVCaptureDevice.CenterStageControlMode
        let enabled: Bool
    }

    private enum ImageStabilityOwner: Equatable {
        case personTracking
        case motionCalibration
    }

    let session = AVCaptureSession()
    var onEvent: (@Sendable (CameraEngineEvent) -> Void)?

    private let queue = DispatchQueue(
        label: "com.yimingshen.om3lab.camera",
        qos: .userInitiated
    )
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external],
        mediaType: .video,
        position: .unspecified
    )
    private let videoOutput = AVCaptureVideoDataOutput()
    private let personAnalyzer = PersonVisionAnalyzer()
    private let inputStateLock = NSLock()
    private var currentInput: AVCaptureDeviceInput?
    private var currentInputGeneration: UInt64?
    private var currentInputDeviceID: String?
    private var currentInputGenerationSnapshot: UInt64?
    private var observerTokens: [NSObjectProtocol] = []
    private var centerStageSnapshot: CenterStageSnapshot?
    private var imageStabilityOwner: ImageStabilityOwner?

    init() {
        videoOutput.alwaysDiscardsLateVideoFrames = true
        personAnalyzer.attach(to: videoOutput)
        personAnalyzer.onSample = { [weak self] sample in
            self?.emit(.personSample(sample))
        }
        personAnalyzer.onMotionSample = { [weak self] sample in
            self?.emit(.motionSample(sample))
        }

        let center = NotificationCenter.default
        observerTokens.append(
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in self?.refreshAndReconcile() }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                guard let self else { return }
                if let device = notification.object as? AVCaptureDevice,
                   self.isCurrentInputDevice(device.uniqueID) {
                    // Revoke analysis immediately on the notification thread. The
                    // capture-session reconciliation below is intentionally serialized,
                    // but no frame from that gap may be allowed to steer the gimbal.
                    self.personAnalyzer.setSession(nil)
                    self.personAnalyzer.setMotionSession(nil)
                }
                self.queue.async { [weak self] in self?.refreshAndReconcile() }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: nil
            ) { [weak self] notification in
                guard let self else { return }
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let message = error?.localizedDescription ?? "摄像头会话发生未知错误"
                let input = self.inputSnapshot()
                self.personAnalyzer.setSession(nil)
                self.personAnalyzer.setMotionSession(nil)
                self.queue.async { [weak self] in
                    guard let self,
                          let generation = input.generation
                    else { return }
                    self.emit(.error(
                        generation: generation,
                        message: message,
                        runningDeviceID: nil,
                        allowsAutomaticRetry: true
                    ))
                }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                let input = self.inputSnapshot()
                self.personAnalyzer.setSession(nil)
                self.personAnalyzer.setMotionSession(nil)
                self.queue.async { [weak self] in
                    guard let self,
                          let generation = input.generation
                    else { return }
                    self.emit(.error(
                        generation: generation,
                        message: "摄像头会话已中断；结束占用后会尝试恢复预览",
                        runningDeviceID: nil,
                        allowsAutomaticRetry: false
                    ))
                }
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                let input = self.inputSnapshot()
                self.queue.async { [weak self] in
                    guard let self,
                          let generation = input.generation,
                          let deviceID = input.deviceID
                    else { return }
                    self.emit(.interruptionEnded(
                        generation: generation,
                        id: deviceID
                    ))
                }
            }
        )
    }

    deinit {
        personAnalyzer.detach(from: videoOutput)
        restoreCenterStageControl()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refreshDevices() {
        queue.async { [weak self] in
            self?.refreshAndReconcile()
        }
    }

    func start(deviceID: String, generation: UInt64) {
        queue.async { [weak self] in
            self?.configureAndStart(deviceID: deviceID, generation: generation)
        }
    }

    func setPersonTrackingSession(_ lease: PersonVisionSessionLease?) {
        personAnalyzer.setSession(lease)
        if lease == nil {
            personAnalyzer.setTrackingSeed(nil)
        }
    }

    func setPersonTrackingSeed(_ detection: PersonDetection?) {
        personAnalyzer.setTrackingSeed(detection)
    }

    func setMotionCalibrationSession(_ lease: GimbalMotionSessionLease?) {
        personAnalyzer.setMotionSession(lease)
    }

    func stop(generation: UInt64) {
        personAnalyzer.setSession(nil)
        personAnalyzer.setMotionSession(nil)
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.emit(.stopped(generation: generation))
        }
    }

    private func refreshAndReconcile() {
        let devices = discovery.devices
        let descriptors = devices.map {
            CameraDeviceDescriptor(id: $0.uniqueID, name: $0.localizedName)
        }

        if let currentInput,
           !devices.contains(where: { $0.uniqueID == currentInput.device.uniqueID }) {
            let disconnectedGeneration = currentInputGeneration
            personAnalyzer.setSession(nil)
            personAnalyzer.setMotionSession(nil)
            session.beginConfiguration()
            session.removeInput(currentInput)
            session.commitConfiguration()
            setCurrentInput(nil, generation: nil)
            if session.isRunning {
                session.stopRunning()
            }
            emit(.stopped(generation: disconnectedGeneration))
        }

        emit(.devices(descriptors))
    }

    private func configureAndStart(deviceID: String, generation: UInt64) {
        personAnalyzer.resetForCameraChange()
        guard let device = discovery.devices.first(where: { $0.uniqueID == deviceID }) else {
            emit(.error(
                generation: generation,
                message: "所选摄像头已断开",
                runningDeviceID: activeRunningDeviceID,
                allowsAutomaticRetry: true
            ))
            refreshAndReconcile()
            return
        }

        if currentInput?.device.uniqueID == deviceID {
            setCurrentInput(currentInput, generation: generation)
            if !session.isRunning {
                session.startRunning()
            }
            if session.isRunning {
                emit(.running(
                    generation: generation,
                    id: deviceID,
                    name: device.localizedName
                ))
            } else {
                emit(.error(
                    generation: generation,
                    message: "摄像头未能启动，可能正被其他应用占用",
                    runningDeviceID: nil,
                    allowsAutomaticRetry: true
                ))
            }
            return
        }

        let previousInput = currentInput
        let previousInputGeneration = currentInputGeneration
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        if let previousInput {
            session.removeInput(previousInput)
        }

        var addedInput: AVCaptureDeviceInput?
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                throw CameraConfigurationError.cannotAddInput
            }
            session.addInput(newInput)
            addedInput = newInput

            if !session.outputs.contains(where: { $0 === videoOutput }) {
                guard session.canAddOutput(videoOutput) else {
                    throw CameraConfigurationError.cannotAddVideoOutput
                }
                session.addOutput(videoOutput)
            }
            configureVideoOutputFormat()
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0
                }
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
            }
            session.commitConfiguration()
            setCurrentInput(newInput, generation: generation)

            if !session.isRunning {
                session.startRunning()
            }
            if session.isRunning {
                emit(.running(
                    generation: generation,
                    id: deviceID,
                    name: device.localizedName
                ))
            } else {
                emit(.error(
                    generation: generation,
                    message: "摄像头未能启动，可能正被其他应用占用",
                    runningDeviceID: nil,
                    allowsAutomaticRetry: true
                ))
            }
        } catch {
            if let addedInput {
                session.removeInput(addedInput)
            }
            var restoredInput: AVCaptureDeviceInput?
            if let previousInput, session.canAddInput(previousInput) {
                session.addInput(previousInput)
                restoredInput = previousInput
            }
            session.commitConfiguration()
            setCurrentInput(
                restoredInput,
                generation: restoredInput == nil ? nil : previousInputGeneration
            )
            emit(.error(
                generation: generation,
                message: "配置摄像头失败：\(error.localizedDescription)",
                runningDeviceID: activeRunningDeviceID,
                allowsAutomaticRetry: true
            ))
        }
    }

    private var activeRunningDeviceID: String? {
        guard session.isRunning else { return nil }
        return currentInput?.device.uniqueID
    }

    private func setCurrentInput(
        _ input: AVCaptureDeviceInput?,
        generation: UInt64?
    ) {
        currentInput = input
        currentInputGeneration = generation
        inputStateLock.lock()
        currentInputDeviceID = input?.device.uniqueID
        currentInputGenerationSnapshot = generation
        inputStateLock.unlock()
    }

    private func inputSnapshot() -> InputSnapshot {
        inputStateLock.lock()
        defer { inputStateLock.unlock() }
        return InputSnapshot(
            deviceID: currentInputDeviceID,
            generation: currentInputGenerationSnapshot
        )
    }

    private func configureVideoOutputFormat() {
        let preferredFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
            kCVPixelFormatType_32ARGB,
        ]
        guard let selected = preferredFormats.first(where: {
            videoOutput.availableVideoPixelFormatTypes.contains($0)
        }) else {
            // Keep AVFoundation's native choice. The motion analyzer will fail
            // closed if that format cannot be copied safely.
            videoOutput.videoSettings = [:]
            return
        }
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(selected),
        ]
    }

    private func isCurrentInputDevice(_ deviceID: String) -> Bool {
        inputStateLock.lock()
        defer { inputStateLock.unlock() }
        return currentInputDeviceID == deviceID
    }

    /// Takes exclusive control of Continuity Camera's digital framing for one
    /// analysis owner. Center Stage would otherwise move the pixels underneath
    /// both physical calibration and person tracking, masking especially the
    /// vertical error that Pitch is supposed to correct.
    private func beginImageStability(owner: ImageStabilityOwner) -> Bool {
        queue.sync { [weak self] in
            guard let self,
                  self.currentInput != nil,
                  self.session.isRunning,
                  self.centerStageSnapshot == nil,
                  self.imageStabilityOwner == nil
            else { return false }

            let snapshot = CenterStageSnapshot(
                controlMode: AVCaptureDevice.centerStageControlMode,
                enabled: AVCaptureDevice.isCenterStageEnabled
            )
            self.centerStageSnapshot = snapshot
            self.imageStabilityOwner = owner
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
            guard AVCaptureDevice.centerStageControlMode == .app,
                  !AVCaptureDevice.isCenterStageEnabled
            else {
                self.restoreCenterStageControl()
                return false
            }
            if owner == .motionCalibration {
                self.setAutoAdjustmentsLockedOnQueue(true)
            }
            return true
        }
    }

    private func endImageStability(owner: ImageStabilityOwner) {
        // Restoration finishes synchronously before another analysis mode can
        // start, so no delayed Center Stage reframing can enter a new lease.
        queue.sync { [weak self] in
            guard let self, self.imageStabilityOwner == owner else { return }
            if owner == .motionCalibration {
                self.setAutoAdjustmentsLockedOnQueue(false)
            }
            self.restoreCenterStageControl()
        }
    }

    func beginPersonTrackingImageStability() -> Bool {
        beginImageStability(owner: .personTracking)
    }

    func endPersonTrackingImageStability() {
        endImageStability(owner: .personTracking)
    }

    func beginMotionCalibrationImageStability() -> Bool {
        beginImageStability(owner: .motionCalibration)
    }

    func endMotionCalibrationImageStability() {
        endImageStability(owner: .motionCalibration)
    }

    private func setAutoAdjustmentsLockedOnQueue(_ locked: Bool) {
        guard let device = currentInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if locked {
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            }
        } catch {
            // Unsupported on this device; calibration falls back to the
            // exposure-delta and temporal-consistency guards.
        }
    }

    private func restoreCenterStageControl() {
        guard let snapshot = centerStageSnapshot else {
            imageStabilityOwner = nil
            return
        }
        // `centerStageEnabled` is writable only while the app owns or shares
        // control. Restore the boolean first, then return the original mode.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = snapshot.enabled
        AVCaptureDevice.centerStageControlMode = snapshot.controlMode
        centerStageSnapshot = nil
        imageStabilityOwner = nil
    }

    private func emit(_ event: CameraEngineEvent) {
        onEvent?(event)
    }
}

private enum CameraConfigurationError: LocalizedError {
    case cannotAddInput
    case cannotAddVideoOutput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            return "无法把该设备加入摄像头会话"
        case .cannotAddVideoOutput:
            return "无法建立人物分析视频输出"
        }
    }
}

@MainActor
final class CameraController: ObservableObject {
    private static let rememberedDeviceIDKey = "rememberedCamera.deviceID"
    private static let rememberedDeviceNameKey = "rememberedCamera.displayName"

    @Published private(set) var status: CameraStatus = .idle
    @Published private(set) var devices: [CameraDeviceDescriptor] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var personTrackingEnabled = false
    @Published private(set) var motionCalibrationEnabled = false

    /// Direct main-thread delivery for the ~12.5 Hz vision samples. Publishing
    /// these through @Published used to invalidate every camera observer's
    /// whole view tree per frame and added a Combine hop to the freshness-
    /// budgeted path. Single consumer each: the two coordinators.
    var onPersonSample: ((PersonVisionSample) -> Void)?
    var onMotionSample: ((GimbalMotionFrameSample) -> Void)?

    private var lastPersonSampleSequence: UInt64 = 0
    private var lastMotionSampleSequence: UInt64 = 0
    private var rememberedDeviceID: String?
    private var rememberedDeviceName: String?
    /// Last device that the engine positively reported as running. This is
    /// deliberately separate from `selectedDeviceID`, which is the desired
    /// input and can change while a previous start event is still in flight.
    private var runningDeviceID: String?
    private var userStoppedPreview = false
    /// A manual choice of a different, not-yet-validated camera suppresses
    /// fallback to the old memory until that manual choice actually runs.
    private var automaticReconnectEnabled = true
    private var lastAutomaticAttemptedDeviceID: String?
    private var automaticRetryFailureCount = 0
    private var automaticRetryTask: Task<Void, Never>?
    private var lastDiscoveredDeviceIDs: Set<String> = []
    private var commandGeneration: UInt64 = 0
    private var activeStartGeneration: UInt64?
    private var activeStartDeviceID: String?

    let session: AVCaptureSession
    private let engine: CameraCaptureEngine
    private var personVisionSessionLease: PersonVisionSessionLease?
    private var motionSessionLease: GimbalMotionSessionLease?

    init() {
        let defaults = UserDefaults.standard
        rememberedDeviceID = defaults.string(forKey: Self.rememberedDeviceIDKey)
        rememberedDeviceName = defaults.string(forKey: Self.rememberedDeviceNameKey)

        let engine = CameraCaptureEngine()
        self.engine = engine
        session = engine.session
        engine.onEvent = { [weak self] event in
            // Person samples originate on one serial Vision queue. Dispatching
            // directly to the main queue preserves their FIFO sequence, including
            // the nil/lost boundary before a newly acquired person sample.
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = .stopped
            engine.refreshDevices()
        case .denied, .restricted:
            status = .denied
        case .notDetermined:
            break
        @unknown default:
            status = .error("未知摄像头权限状态")
        }
    }

    func requestAccessAndRefresh() {
        guard status != .requestingPermission else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if status.isRecoverableCameraError {
                resetAutomaticRecoveryBudget()
            }
            status = .stopped
            engine.refreshDevices()
        case .notDetermined:
            status = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.resetAutomaticRecoveryBudget()
                        self.status = .stopped
                        self.engine.refreshDevices()
                    } else {
                        self.status = .denied
                    }
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .error("未知摄像头权限状态")
        }
    }

    func refreshDevices() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            requestAccessAndRefresh()
            return
        }
        resetAutomaticRecoveryBudget()
        engine.refreshDevices()
    }

    func selectAndStart(_ deviceID: String) {
        guard devices.contains(where: { $0.id == deviceID }) else {
            selectedDeviceID = nil
            status = .error("所选摄像头已断开，请重新选择")
            return
        }
        userStoppedPreview = false
        automaticReconnectEnabled = deviceID == rememberedDeviceID
        resetAutomaticRecoveryBudget()
        selectedDeviceID = deviceID
        start(deviceID)
    }

    @discardableResult
    private func start(_ deviceID: String) -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            requestAccessAndRefresh()
            return false
        }
        guard selectedDeviceID == deviceID,
              devices.contains(where: { $0.id == deviceID })
        else {
            status = .error("所选摄像头已断开，请重新选择")
            return false
        }
        revokeAnalysisLeases()
        if runningDeviceID != deviceID {
            runningDeviceID = nil
        }
        commandGeneration &+= 1
        let generation = commandGeneration
        activeStartGeneration = generation
        activeStartDeviceID = deviceID
        status = .configuring
        engine.start(deviceID: deviceID, generation: generation)
        return true
    }

    func startSelectedOrFirst() {
        if let selectedDeviceID,
           devices.contains(where: { $0.id == selectedDeviceID }) {
            selectAndStart(selectedDeviceID)
            return
        }
        if let remembered = CameraSelectionPolicy.rememberedDevice(
            in: devices,
            rememberedID: rememberedDeviceID
        ) {
            selectAndStart(remembered.id)
            return
        }
        selectedDeviceID = nil
        if let rememberedDeviceName {
            status = .error("上次使用的摄像头 \(rememberedDeviceName) 暂未连接；请选择其他设备")
        } else if devices.isEmpty {
            status = .error("没有发现可用摄像头")
        } else {
            status = .error("请选择一个摄像头")
        }
    }

    func stop() {
        userStoppedPreview = true
        resetAutomaticRecoveryBudget()
        revokeAnalysisLeases()
        status = .stopping
        requestEngineStop()
    }

    func setPersonTrackingEnabled(_ enabled: Bool) {
        guard enabled != personTrackingEnabled else { return }
        if enabled {
            guard status.isRunning,
                  runningDeviceID != nil,
                  runningDeviceID == selectedDeviceID,
                  !motionCalibrationEnabled,
                  engine.beginPersonTrackingImageStability()
            else { return }
            let lease = PersonVisionSessionLease()
            personVisionSessionLease = lease
            engine.setPersonTrackingSession(lease)
            personTrackingEnabled = true
        } else {
            engine.setPersonTrackingSession(nil)
            personVisionSessionLease = nil
            engine.endPersonTrackingImageStability()
            personTrackingEnabled = false
        }
    }

    /// Seeds (or clears) the correlation tracker with the locked target's
    /// latest detector-confirmed box.
    func setPersonTrackingSeed(_ detection: PersonDetection?) {
        guard personTrackingEnabled || detection == nil else { return }
        engine.setPersonTrackingSeed(detection)
    }

    func beginMotionCalibration() -> UUID? {
        guard status.isRunning,
              runningDeviceID != nil,
              runningDeviceID == selectedDeviceID,
              !personTrackingEnabled,
              !motionCalibrationEnabled
        else { return nil }
        guard engine.beginMotionCalibrationImageStability() else { return nil }
        let lease = GimbalMotionSessionLease()
        motionSessionLease = lease
        motionCalibrationEnabled = true
        engine.setMotionCalibrationSession(lease)
        return lease.id
    }

    func endMotionCalibration() {
        engine.setMotionCalibrationSession(nil)
        if motionCalibrationEnabled {
            engine.endMotionCalibrationImageStability()
        }
        motionSessionLease = nil
        motionCalibrationEnabled = false
    }

    func isMotionCalibrationSessionValid(_ sessionID: UUID) -> Bool {
        guard motionCalibrationEnabled,
              let lease = motionSessionLease,
              lease.id == sessionID
        else { return false }
        return lease.isValid
    }

    func isPersonTrackingSessionValid(_ sessionID: UUID) -> Bool {
        guard personTrackingEnabled,
              let lease = personVisionSessionLease,
              lease.id == sessionID
        else { return false }
        return lease.isValid
    }

    func withValidPersonTrackingSession<Result>(
        _ sessionID: UUID,
        operation: () -> Result
    ) -> Result? {
        guard personTrackingEnabled,
              let lease = personVisionSessionLease,
              lease.id == sessionID
        else { return nil }
        return lease.withValidity(operation)
    }

    private func revokeAnalysisLeases() {
        setPersonTrackingEnabled(false)
        endMotionCalibration()
    }

    private func invalidateActiveStart() {
        activeStartGeneration = nil
        activeStartDeviceID = nil
    }

    private func requestEngineStop() {
        commandGeneration &+= 1
        let generation = commandGeneration
        invalidateActiveStart()
        engine.stop(generation: generation)
    }

    private func cancelScheduledAutomaticRetry(resetFailureCount: Bool) {
        automaticRetryTask?.cancel()
        automaticRetryTask = nil
        if resetFailureCount {
            automaticRetryFailureCount = 0
        }
    }

    private func resetAutomaticRecoveryBudget() {
        cancelScheduledAutomaticRetry(resetFailureCount: true)
        lastAutomaticAttemptedDeviceID = nil
    }

    private func beginAutomaticStart(_ deviceID: String) {
        guard automaticReconnectEnabled,
              !userStoppedPreview,
              deviceID == rememberedDeviceID,
              selectedDeviceID == deviceID,
              devices.contains(where: { $0.id == deviceID })
        else { return }
        cancelScheduledAutomaticRetry(resetFailureCount: false)
        lastAutomaticAttemptedDeviceID = deviceID
        _ = start(deviceID)
    }

    private func scheduleAutomaticRetry(for deviceID: String) {
        guard automaticReconnectEnabled,
              !userStoppedPreview,
              deviceID == rememberedDeviceID,
              selectedDeviceID == deviceID,
              devices.contains(where: { $0.id == deviceID })
        else { return }

        automaticRetryFailureCount += 1
        guard let delayMilliseconds = CameraAutomaticRetryPolicy.delayMilliseconds(
            afterFailure: automaticRetryFailureCount
        ) else { return }

        automaticRetryTask?.cancel()
        automaticRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task<Never, Never>.sleep(
                    nanoseconds: delayMilliseconds * 1_000_000
                )
            } catch {
                return
            }
            guard let self else { return }
            self.automaticRetryTask = nil
            guard self.activeStartGeneration == nil,
                  self.status == .stopped || self.status.isRecoverableCameraError
            else { return }
            self.beginAutomaticStart(deviceID)
        }
    }

    private func handle(_ event: CameraEngineEvent) {
        switch event {
        case let .devices(discoveredDevices):
            // Every discovered camera remains visible and manually selectable.
            // Automatic recovery is exact-ID only and therefore cannot turn a
            // sole unrelated camera into an implicit fallback.
            devices = discoveredDevices
            let currentDeviceIDs = Set(discoveredDevices.map(\.id))
            let remembered = CameraSelectionPolicy.rememberedDevice(
                in: discoveredDevices,
                rememberedID: rememberedDeviceID
            )
            let rememberedJustAppeared = remembered.map {
                !lastDiscoveredDeviceIDs.contains($0.id)
            } ?? false
            lastDiscoveredDeviceIDs = currentDeviceIDs

            if let selectedDeviceID,
               !currentDeviceIDs.contains(selectedDeviceID) {
                if activeStartDeviceID == selectedDeviceID {
                    invalidateActiveStart()
                }
                self.selectedDeviceID = nil
                revokeAnalysisLeases()
            }
            if selectedDeviceID == nil,
               automaticReconnectEnabled,
               let remembered {
                selectedDeviceID = remembered.id
            }
            if rememberedJustAppeared {
                resetAutomaticRecoveryBudget()
            }

            switch CameraSelectionPolicy.runningDeviceAction(
                runningDeviceID: runningDeviceID,
                selectedDeviceID: selectedDeviceID,
                userStopped: userStoppedPreview
            ) {
            case .none:
                break
            case let .switchTo(deviceID):
                revokeAnalysisLeases()
                guard activeStartDeviceID != deviceID else { return }
                guard automaticRetryTask == nil else { return }
                invalidateActiveStart()
                if automaticReconnectEnabled,
                   deviceID == rememberedDeviceID {
                    beginAutomaticStart(deviceID)
                } else {
                    _ = start(deviceID)
                }
                return
            case .stop:
                invalidateActiveStart()
                revokeAnalysisLeases()
                if status != .stopping {
                    status = .stopping
                    requestEngineStop()
                }
                return
            }

            guard automaticReconnectEnabled,
                  !userStoppedPreview,
                  runningDeviceID == nil,
                  activeStartGeneration == nil,
                  automaticRetryTask == nil,
                  let remembered,
                  selectedDeviceID == remembered.id,
                  rememberedJustAppeared || lastAutomaticAttemptedDeviceID != remembered.id,
                  status == .stopped || status == .idle || status.isRecoverableCameraError
            else { return }
            beginAutomaticStart(remembered.id)

        case let .running(generation, id, name):
            let acceptsEvent = CameraStartEventPolicy.acceptsRunningEvent(
                generation: generation,
                deviceID: id,
                activeGeneration: activeStartGeneration,
                activeDeviceID: activeStartDeviceID,
                selectedDeviceID: selectedDeviceID
            ) && devices.contains(where: { $0.id == id })
            guard acceptsEvent else {
                if status.isRunning,
                   selectedDeviceID == id {
                    return
                }
                revokeAnalysisLeases()
                if userStoppedPreview {
                    requestEngineStop()
                    return
                }
                if activeStartGeneration != nil {
                    // A newer start is already queued; its generation is the
                    // only event allowed to publish state or update memory.
                    return
                }
                guard let selectedDeviceID,
                      devices.contains(where: { $0.id == selectedDeviceID })
                else {
                    requestEngineStop()
                    return
                }
                if automaticReconnectEnabled,
                   selectedDeviceID == rememberedDeviceID {
                    beginAutomaticStart(selectedDeviceID)
                } else {
                    _ = start(selectedDeviceID)
                }
                return
            }

            runningDeviceID = id
            invalidateActiveStart()
            cancelScheduledAutomaticRetry(resetFailureCount: true)
            lastAutomaticAttemptedDeviceID = id
            rememberedDeviceID = id
            rememberedDeviceName = name
            automaticReconnectEnabled = true
            let defaults = UserDefaults.standard
            defaults.set(id, forKey: Self.rememberedDeviceIDKey)
            defaults.set(name, forKey: Self.rememberedDeviceNameKey)
            status = .running(name)

        case let .interruptionEnded(generation, id):
            guard generation == commandGeneration,
                  !userStoppedPreview,
                  activeStartGeneration == nil,
                  automaticRetryTask == nil,
                  let selectedDeviceID,
                  selectedDeviceID == id,
                  devices.contains(where: { $0.id == selectedDeviceID })
            else { return }
            cancelScheduledAutomaticRetry(resetFailureCount: false)
            if automaticReconnectEnabled,
               selectedDeviceID == rememberedDeviceID {
                beginAutomaticStart(selectedDeviceID)
            } else {
                _ = start(selectedDeviceID)
            }

        case let .personSample(sample):
            guard personTrackingEnabled,
                  runningDeviceID == selectedDeviceID,
                  isPersonTrackingSessionValid(sample.sessionID),
                  sample.sequence > lastPersonSampleSequence
            else { return }
            lastPersonSampleSequence = sample.sequence
            onPersonSample?(sample)
        case let .motionSample(sample):
            guard motionCalibrationEnabled,
                  runningDeviceID == selectedDeviceID,
                  isMotionCalibrationSessionValid(sample.sessionID),
                  sample.sequence > lastMotionSampleSequence
            else { return }
            lastMotionSampleSequence = sample.sequence
            onMotionSample?(sample)

        case let .stopped(generation):
            guard CameraStartEventPolicy.acceptsStoppedEvent(
                generation: generation,
                activeGeneration: activeStartGeneration,
                commandGeneration: commandGeneration
            ) else { return }
            let preserveError = status.isRecoverableCameraError
            runningDeviceID = nil
            invalidateActiveStart()
            revokeAnalysisLeases()
            if !preserveError {
                status = .stopped
            }

        case let .error(
            generation,
            message,
            reportedRunningDeviceID,
            allowsAutomaticRetry
        ):
            guard CameraStartEventPolicy.acceptsErrorEvent(
                generation: generation,
                activeGeneration: activeStartGeneration,
                commandGeneration: commandGeneration
            ) else {
                // A superseded configuration attempt cannot overwrite the
                // status, selection, retry budget, or remembered camera.
                return
            }
            let failedDeviceID = activeStartDeviceID ?? selectedDeviceID
            invalidateActiveStart()
            runningDeviceID = reportedRunningDeviceID == selectedDeviceID
                ? reportedRunningDeviceID
                : nil
            revokeAnalysisLeases()
            guard !userStoppedPreview else { return }
            status = .error(message)

            if allowsAutomaticRetry,
               let failedDeviceID,
               failedDeviceID == rememberedDeviceID {
                scheduleAutomaticRetry(for: failedDeviceID)
            }
            if let reportedRunningDeviceID,
               reportedRunningDeviceID != selectedDeviceID {
                // A failed switch may have restored the previous input. It is
                // never allowed to remain as a silent fallback.
                requestEngineStop()
            }
        }
    }

}

private extension CameraStatus {
    var isRecoverableCameraError: Bool {
        if case .error = self { return true }
        return false
    }
}
