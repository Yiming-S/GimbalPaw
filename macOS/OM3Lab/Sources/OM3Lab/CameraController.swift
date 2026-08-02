@preconcurrency import AVFoundation
import Foundation

struct CameraDeviceDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
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
        case .configuring: return "正在配置 USB 摄像头"
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
    case running(id: String, name: String)
    case personSample(PersonVisionSample)
    case motionSample(GimbalMotionFrameSample)
    case stopped
    case error(String)
}

private final class CameraCaptureEngine: @unchecked Sendable {
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
    private var currentInputDeviceID: String?
    private var observerTokens: [NSObjectProtocol] = []

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
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let message = error?.localizedDescription ?? "摄像头会话发生未知错误"
                self?.personAnalyzer.setSession(nil)
                self?.personAnalyzer.setMotionSession(nil)
                self?.emit(.error(message))
            }
        )
        observerTokens.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: session,
                queue: nil
            ) { [weak self] _ in
                self?.personAnalyzer.setSession(nil)
                self?.personAnalyzer.setMotionSession(nil)
                self?.emit(.error("摄像头会话已中断，请确认设备未被其他应用占用后重新启动"))
            }
        )
    }

    deinit {
        personAnalyzer.detach(from: videoOutput)
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func refreshDevices() {
        queue.async { [weak self] in
            self?.refreshAndReconcile()
        }
    }

    func start(deviceID: String) {
        queue.async { [weak self] in
            self?.configureAndStart(deviceID: deviceID)
        }
    }

    func setPersonTrackingSession(_ lease: PersonVisionSessionLease?) {
        personAnalyzer.setSession(lease)
    }

    func setMotionCalibrationSession(_ lease: GimbalMotionSessionLease?) {
        personAnalyzer.setMotionSession(lease)
    }

    func stop() {
        personAnalyzer.setSession(nil)
        personAnalyzer.setMotionSession(nil)
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.emit(.stopped)
        }
    }

    private func refreshAndReconcile() {
        let devices = discovery.devices
        let descriptors = devices.map {
            CameraDeviceDescriptor(id: $0.uniqueID, name: $0.localizedName)
        }

        if let currentInput,
           !devices.contains(where: { $0.uniqueID == currentInput.device.uniqueID }) {
            personAnalyzer.setSession(nil)
            personAnalyzer.setMotionSession(nil)
            session.beginConfiguration()
            session.removeInput(currentInput)
            session.commitConfiguration()
            setCurrentInput(nil)
            if session.isRunning {
                session.stopRunning()
            }
            emit(.stopped)
        }

        emit(.devices(descriptors))
    }

    private func configureAndStart(deviceID: String) {
        personAnalyzer.resetForCameraChange()
        guard let device = discovery.devices.first(where: { $0.uniqueID == deviceID }) else {
            emit(.error("所选 USB 摄像头已断开"))
            refreshAndReconcile()
            return
        }

        if currentInput?.device.uniqueID == deviceID {
            if !session.isRunning {
                session.startRunning()
            }
            if session.isRunning {
                emit(.running(id: deviceID, name: device.localizedName))
            } else {
                emit(.error("摄像头未能启动，可能正被其他应用占用"))
            }
            return
        }

        let previousInput = currentInput
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
            setCurrentInput(newInput)

            if !session.isRunning {
                session.startRunning()
            }
            if session.isRunning {
                emit(.running(id: deviceID, name: device.localizedName))
            } else {
                emit(.error("摄像头未能启动，可能正被其他应用占用"))
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
            setCurrentInput(restoredInput)
            emit(.error("配置摄像头失败：\(error.localizedDescription)"))
        }
    }

    private func setCurrentInput(_ input: AVCaptureDeviceInput?) {
        currentInput = input
        inputStateLock.lock()
        currentInputDeviceID = input?.device.uniqueID
        inputStateLock.unlock()
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
    @Published private(set) var status: CameraStatus = .idle
    @Published private(set) var devices: [CameraDeviceDescriptor] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var personTrackingEnabled = false
    @Published private(set) var personSample: PersonVisionSample?
    @Published private(set) var motionCalibrationEnabled = false
    @Published private(set) var motionSample: GimbalMotionFrameSample?

    let session: AVCaptureSession
    private let engine: CameraCaptureEngine
    private var personVisionSessionLease: PersonVisionSessionLease?
    private var motionSessionLease: GimbalMotionSessionLease?

    init() {
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
    }

    func requestAccessAndRefresh() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status = .stopped
            engine.refreshDevices()
        case .notDetermined:
            status = .requestingPermission
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
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
        engine.refreshDevices()
    }

    func selectAndStart(_ deviceID: String) {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            requestAccessAndRefresh()
            return
        }
        setPersonTrackingEnabled(false)
        endMotionCalibration()
        selectedDeviceID = deviceID
        status = .configuring
        engine.start(deviceID: deviceID)
    }

    func startSelectedOrFirst() {
        guard let id = selectedDeviceID ?? devices.first?.id else {
            status = .error("没有发现外置 USB 摄像头")
            return
        }
        selectAndStart(id)
    }

    func stop() {
        setPersonTrackingEnabled(false)
        endMotionCalibration()
        status = .stopping
        engine.stop()
    }

    func setPersonTrackingEnabled(_ enabled: Bool) {
        guard !enabled || (status.isRunning && !motionCalibrationEnabled) else { return }
        personTrackingEnabled = enabled
        if enabled {
            let lease = PersonVisionSessionLease()
            personVisionSessionLease = lease
            engine.setPersonTrackingSession(lease)
        } else {
            engine.setPersonTrackingSession(nil)
            personVisionSessionLease = nil
            personSample = nil
        }
    }

    func beginMotionCalibration() -> UUID? {
        guard status.isRunning,
              !personTrackingEnabled,
              !motionCalibrationEnabled
        else { return nil }
        let lease = GimbalMotionSessionLease()
        motionSessionLease = lease
        motionCalibrationEnabled = true
        motionSample = nil
        engine.setMotionCalibrationSession(lease)
        return lease.id
    }

    func endMotionCalibration() {
        engine.setMotionCalibrationSession(nil)
        motionSessionLease = nil
        motionCalibrationEnabled = false
        motionSample = nil
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

    private func handle(_ event: CameraEngineEvent) {
        switch event {
        case let .devices(devices):
            self.devices = devices
            if let selectedDeviceID,
               !devices.contains(where: { $0.id == selectedDeviceID }) {
                self.selectedDeviceID = nil
            }
            if self.selectedDeviceID == nil {
                self.selectedDeviceID = devices.first?.id
            }
        case let .running(id, name):
            selectedDeviceID = id
            status = .running(name)
        case let .personSample(sample):
            guard personTrackingEnabled,
                  isPersonTrackingSessionValid(sample.sessionID)
            else { return }
            if let current = personSample, sample.sequence <= current.sequence {
                return
            }
            personSample = sample
        case let .motionSample(sample):
            guard motionCalibrationEnabled,
                  isMotionCalibrationSessionValid(sample.sessionID)
            else { return }
            if let current = motionSample, sample.sequence <= current.sequence {
                return
            }
            motionSample = sample
        case .stopped:
            setPersonTrackingEnabled(false)
            endMotionCalibration()
            status = .stopped
        case let .error(message):
            setPersonTrackingEnabled(false)
            endMotionCalibration()
            status = .error(message)
        }
    }
}
