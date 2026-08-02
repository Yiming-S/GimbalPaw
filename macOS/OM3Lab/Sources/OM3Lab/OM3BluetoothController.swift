import AppKit
import CoreBluetooth
import Foundation

enum OM3ConnectionState: Equatable {
    case unavailable(String)
    case idle
    case scanning
    case connecting(String)
    case discovering(String)
    case ready(String)
    case disconnecting
    case error(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isDiscovering: Bool {
        if case .discovering = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .discovering, .disconnecting:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case let .unavailable(reason): return reason
        case .idle: return "蓝牙已就绪"
        case .scanning: return "正在扫描 BLE 设备"
        case let .connecting(name): return "正在连接 \(name)"
        case let .discovering(name): return "正在验证 \(name)"
        case let .ready(name): return "\(name) 已就绪"
        case .disconnecting: return "正在安全断开"
        case let .error(message): return message
        }
    }
}

struct OM3DiscoveredDevice: Identifiable {
    let id: UUID
    fileprivate let peripheral: CBPeripheral
    var name: String
    var rssi: Int

    var isLikelyOM3: Bool {
        let normalized = name.lowercased()
        return normalized.contains("om3")
            || normalized.contains("osmo mobile 3")
            || normalized.contains("dji")
    }
}

struct OM3LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

enum PersonTrackingCommandResult: Equatable {
    case submitted(PersonTrackingCorrection)
    case busy
    case boundaryReached
    case safetyBudgetExhausted
    case inactive
    case failed
}

enum PersonSearchCommandResult: Equatable {
    case submitted(yawTenths: Int, reachesSoftBoundary: Bool)
    case busy
    case softBoundaryReached
    case hardBoundaryReached
    case safetyBudgetExhausted
    case inactive
    case failed
}

final class OM3BluetoothController: NSObject, ObservableObject {
    private static let serviceUUID = CBUUID(string: "FFF0")
    private static let notifyUUID = CBUUID(string: "FFF4")
    private static let writeUUID = CBUUID(string: "FFF5")
    private static let packetLimit = 8
    private static let rememberedPeripheralIDKey = "rememberedOM3.peripheralID"
    private static let rememberedPeripheralNameKey = "rememberedOM3.displayName"
    private static let rememberedProtocolVersionKey = "rememberedOM3.protocolVersion"
    private static let rememberedProtocolVersion = 1

    @Published private(set) var state: OM3ConnectionState = .unavailable("正在初始化蓝牙")
    @Published private(set) var devices: [OM3DiscoveredDevice] = []
    @Published private(set) var nudgeAvailable = false
    @Published private(set) var motionSafetyArmed = false
    @Published private(set) var trackingOriginConfirmed = false
    @Published private(set) var personTrackingActive = false
    @Published private(set) var rangeCalibrationActive = false
    @Published private(set) var calibratedTrackingEnvelope: GimbalTrackingEnvelope?
    @Published private(set) var rememberedDeviceName: String?
    @Published private(set) var automaticReconnectInProgress = false
    @Published private(set) var logs: [OM3LogEntry] = [
        OM3LogEntry(timestamp: Date(), message: "待机：请先安装负载、完成配平并整理线缆。"),
    ]
    /// Per-chunk TX hex and raw RX notifications reach ~30 log lines per
    /// second in the fast tracking profile; each one used to shift a
    /// @Published array on the main thread. Off by default.
    @Published private(set) var verboseLogging = UserDefaults.standard.bool(
        forKey: "om3.verboseLogging"
    )

    func setVerboseLogging(_ enabled: Bool) {
        verboseLogging = enabled
        UserDefaults.standard.set(enabled, forKey: "om3.verboseLogging")
    }

    private enum PacketCompletion {
        case none
        case manual(token: UUID, delay: TimeInterval)
        case tracking(
            session: UUID,
            token: UUID,
            delay: TimeInterval,
            motionDelta: PersonTrackingCorrection?
        )
    }

    private struct Packet {
        let label: String
        let chunks: [Data]
        let completion: PacketCompletion
        let expiresAtUptime: TimeInterval?
        var nextChunk = 0
    }

    private enum ConnectionIntent: Equatable {
        case none
        case manual(target: UUID, attempt: UUID)
        case automatic(target: UUID, attempt: UUID)
        case automaticSearch(target: UUID, generation: UInt64)
        case manualDisconnect(target: UUID)
        case validationFailed(target: UUID)

        var target: UUID? {
            switch self {
            case .none:
                return nil
            case let .manual(target, _),
                 let .automatic(target, _),
                 let .automaticSearch(target, _),
                 let .manualDisconnect(target),
                 let .validationFailed(target):
                return target
            }
        }

        var isAutomatic: Bool {
            switch self {
            case .automatic, .automaticSearch:
                return true
            default:
                return false
            }
        }
    }

    private enum ConnectionOrigin: Equatable {
        case manual
        case automatic
    }

    private var central: CBCentralManager!
    private var connectionIntent: ConnectionIntent = .none
    private var rememberedPeripheralID: UUID?
    private var automaticReconnectSuppressedForSession = false
    private var automaticReconnectPausedByValidationFailure = false
    private var reconnectGeneration: UInt64 = 0
    private var reconnectAttempt = 0
    private var connectionEpoch: UInt64 = 0
    private var retainedPeripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var packets: [Packet] = []
    private var disconnectRequestedFor: UUID?
    private var disconnectNeedsWriteGrace = false
    private var disconnectCancelScheduled = false
    private var nudgeCooldownToken = UUID()
    private var activeRangeCalibrationSession: UUID?
    private var activeTrackingSession: UUID?
    private var activeTrackingSpeedMode: PersonTrackingSpeedMode?
    private var activeTrackingEnvelope = GimbalTrackingEnvelope.conservativeDefault
    private var trackingCommandAvailable = false
    private var trackingCooldownToken = UUID()
    private var trackingYawBudgetTenths = 0
    private var trackingPitchBudgetTenths = 0
    private var trackingYawTravelTenths = 0
    private var trackingPitchTravelTenths = 0

    private var terminationObserver: NSObjectProtocol?

    override init() {
        super.init()
        loadRememberedDevice()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        // SwiftUI's onDisappear is not reliably delivered on quit, so the
        // best-effort STOP must also hang off app termination. Power-off
        // remains the only real failsafe.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendBestEffortStopBeforeTermination()
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private func sendBestEffortStopBeforeTermination() {
        guard state.isReady else { return }
        motionSafetyArmed = false
        trackingOriginConfirmed = false
        invalidateRangeCalibration()
        discardCalibratedTrackingEnvelope(reason: nil)
        enqueueStop(label: "应用退出 STOP")
        // One brief run-loop pass gives CoreBluetooth a chance to hand the
        // frame to the controller before the process exits.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            appendLog("无法扫描：请先在系统设置中打开蓝牙。")
            return
        }
        guard activePeripheral == nil else {
            appendLog("请先断开当前 OM3，再重新扫描。")
            return
        }

        cancelAutomaticReconnect(suppressForSession: true)
        automaticReconnectPausedByValidationFailure = false
        connectionIntent = .none
        devices.removeAll()
        retainedPeripherals.removeAll()
        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        appendLog("开始扫描所有 BLE 广播；连接后再验证 FFF0 服务。")
    }

    func stopScanning() {
        central.stopScan()
        if connectionIntent.isAutomatic {
            cancelAutomaticReconnect(suppressForSession: true)
            appendLog("已取消本次运行的自动连接；下次启动仍会尝试。")
        }
        connectionIntent = .none
        if state == .scanning {
            state = .idle
            appendLog("扫描已停止。")
        }
    }

    func connect(to id: UUID) {
        guard central.state == .poweredOn else { return }
        guard activePeripheral == nil else {
            appendLog("已有连接任务在进行；请先断开再选择其他设备。")
            return
        }
        guard let peripheral = retainedPeripherals[id] else {
            appendLog("该设备已离开扫描范围，请重新扫描。")
            return
        }

        cancelAutomaticReconnect(suppressForSession: true)
        automaticReconnectPausedByValidationFailure = false
        beginConnection(to: peripheral, origin: .manual)
    }

    func disconnect() {
        cancelAutomaticReconnect(suppressForSession: true)
        central.stopScan()
        guard let peripheral = activePeripheral else {
            connectionIntent = .none
            automaticReconnectInProgress = false
            state = central.state == .poweredOn ? .idle : state
            appendLog("已取消本次运行的自动连接；已保留下次启动的设备记忆。")
            return
        }
        guard state != .disconnecting else { return }

        let identifier = peripheral.identifier
        let wasReady = state.isReady
        if wasReady {
            enqueueStop(label: "断开前 STOP")
        }
        disconnectRequestedFor = identifier
        connectionIntent = .manualDisconnect(target: identifier)
        disconnectNeedsWriteGrace = wasReady
        disconnectCancelScheduled = false
        state = .disconnecting
        appendLog("已锁定运动控制，准备断开连接。")
        scheduleDisconnectWhenWritesAreSubmitted()

        // A bounded fallback prevents a permanently back-pressured peripheral from
        // leaving the UI stuck in disconnecting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.disconnectRequestedFor == identifier,
                  self.activePeripheral?.identifier == identifier
            else { return }
            if self.packets.isEmpty {
                self.appendLog("断开回调超时；再次请求断开 BLE。")
            } else {
                self.appendLog("发送队列未在 2 秒内排空；强制断开 BLE。")
            }
            self.central.cancelPeripheralConnection(peripheral)
        }
    }

    func setMotionSafetyArmed(_ armed: Bool) {
        if armed {
            guard state.isReady,
                  nudgeAvailable,
                  !personTrackingActive,
                  !rangeCalibrationActive
            else {
                motionSafetyArmed = false
                trackingOriginConfirmed = false
                appendLog("运动安全确认暂不能开启：请等待 STOP 或当前动作完全结束。")
                return
            }
            motionSafetyArmed = true
            trackingOriginConfirmed = true
            appendLog("运动安全确认已解锁。")
            return
        }

        let wasArmed = motionSafetyArmed
        motionSafetyArmed = false
        trackingOriginConfirmed = false
        invalidateRangeCalibration()
        discardCalibratedTrackingEnvelope(reason: nil)
        if wasArmed, state.isReady {
            enqueueStop(label: "安全确认关闭 STOP")
        }
    }

    func sendNudge(yawDegrees: Int, pitchDegrees: Int, label: String) {
        guard state.isReady else {
            appendLog("控制被拦截：OM3 尚未就绪。")
            return
        }
        guard motionSafetyArmed else {
            appendLog("控制被拦截：请先打开运动安全确认。")
            return
        }
        guard nudgeAvailable else {
            appendLog("点动互锁中：请等待当前 1 秒动作结束，或按 STOP。")
            return
        }
        guard !personTrackingActive else {
            appendLog("手动点动被拦截：请先关闭人物跟踪。")
            return
        }
        guard !rangeCalibrationActive else {
            appendLog("手动点动被拦截：全向行程验证正在运行。")
            return
        }
        guard calibratedTrackingEnvelope == nil else {
            appendLog("手动点动被拦截：校准范围已绑定当前原点；请直接启动人物跟踪，或关闭安全确认后重新置中。")
            return
        }

        do {
            let frame = try OM3Protocol.relativeNudge(
                yawDegrees: yawDegrees,
                pitchDegrees: pitchDegrees
            )
            trackingOriginConfirmed = false
            let token = lockNudges()
            if !enqueue(
                frame,
                label: label,
                completion: .manual(token: token, delay: 1.15),
                expiresAtUptime: nil
            ),
               nudgeCooldownToken == token,
               state.isReady {
                nudgeCooldownToken = UUID()
                nudgeAvailable = true
            }
        } catch {
            appendLog("构帧失败：\(error.localizedDescription)")
        }
    }

    func beginRangeCalibration() -> UUID? {
        guard state.isReady,
              motionSafetyArmed,
              nudgeAvailable,
              !personTrackingActive,
              activeTrackingSession == nil,
              activeRangeCalibrationSession == nil
        else {
            appendLog("全向行程验证无法启动：请等待 OM3、当前动作和安全互锁就绪。")
            return nil
        }

        discardCalibratedTrackingEnvelope(reason: nil)
        trackingOriginConfirmed = true
        let session = UUID()
        activeRangeCalibrationSession = session
        rangeCalibrationActive = true
        appendLog("全向行程验证已取得独占控制；每一步都需要人工确认。")
        return session
    }

    func isRangeCalibrationSessionValid(_ session: UUID) -> Bool {
        state.isReady
            && motionSafetyArmed
            && rangeCalibrationActive
            && activeRangeCalibrationSession == session
    }

    @discardableResult
    func sendRangeCalibrationNudge(
        yawDegrees: Int,
        pitchDegrees: Int,
        durationTenths: UInt8 = OM3Protocol.testDurationTenths,
        label: String,
        session: UUID
    ) -> Bool {
        guard state.isReady,
              motionSafetyArmed,
              activeRangeCalibrationSession == session,
              rangeCalibrationActive,
              !personTrackingActive,
              nudgeAvailable
        else {
            appendLog("自检步进被拦截：校准会话或运动互锁已失效。")
            return false
        }

        do {
            let frame = try OM3Protocol.relativeMove(
                yawTenths: yawDegrees * 10,
                pitchTenths: pitchDegrees * 10,
                durationTenths: durationTenths
            )
            let token = lockNudges()
            // The interlock must outlast the declared motion; aggregated
            // return moves run longer than the standard 1.0-second nudge.
            let submitted = enqueue(
                frame,
                label: label,
                completion: .manual(
                    token: token,
                    delay: Double(durationTenths) / 10.0 + 0.15
                ),
                expiresAtUptime: nil
            )
            if !submitted,
               nudgeCooldownToken == token,
               state.isReady {
                nudgeCooldownToken = UUID()
                nudgeAvailable = true
            }
            return submitted
        } catch {
            appendLog("自检步进构帧失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Sends a best-effort STOP without ending the calibration lease. This is
    /// used after an unverified visual response so no further outward step can
    /// be issued before the operator decides what happened.
    @discardableResult
    func stopRangeCalibrationMotion(session: UUID, reason: String) -> Bool {
        guard state.isReady,
              activeRangeCalibrationSession == session,
              rangeCalibrationActive
        else { return false }
        trackingOriginConfirmed = false
        do {
            let stopToken = lockNudges()
            let stop = makePacket(
                try OM3Protocol.stopMessage(),
                label: reason,
                completion: .manual(token: stopToken, delay: 1.15),
                expiresAtUptime: nil
            )
            prioritizeStopPacket(stop)
            return true
        } catch {
            appendLog("自检 STOP 构帧失败：\(error.localizedDescription)")
            return false
        }
    }

    func endRangeCalibration(
        session: UUID,
        reason: String,
        sendStop: Bool
    ) {
        guard activeRangeCalibrationSession == session else { return }
        invalidateRangeCalibration()
        trackingOriginConfirmed = false
        appendLog(reason)
        if sendStop, state.isReady {
            motionSafetyArmed = false
            enqueueStop(label: "全向行程验证结束 STOP")
        }
    }

    @discardableResult
    func installCalibratedTrackingEnvelope(_ envelope: GimbalTrackingEnvelope) -> Bool {
        guard state.isReady,
              motionSafetyArmed,
              !rangeCalibrationActive,
              !personTrackingActive,
              envelope.leftYawTenths <= 900,
              envelope.rightYawTenths <= 900,
              envelope.upPitchTenths <= 300,
              envelope.downPitchTenths <= 300
        else {
            appendLog("校准范围未启用：连接、安全状态或范围数据无效。")
            return false
        }
        calibratedTrackingEnvelope = envelope
        trackingOriginConfirmed = true
        appendLog(
            "下一次人物跟踪启用校准范围：左 \(formatTenths(envelope.leftYawTenths))° / 右 \(formatTenths(envelope.rightYawTenths))° / 上 \(formatTenths(envelope.upPitchTenths))° / 下 \(formatTenths(envelope.downPitchTenths))°。"
        )
        return true
    }

    func beginPersonTracking(speedMode: PersonTrackingSpeedMode) -> UUID? {
        guard state.isReady,
              motionSafetyArmed,
              trackingOriginConfirmed,
              nudgeAvailable,
              !rangeCalibrationActive,
              activeTrackingSession == nil,
              activeTrackingSpeedMode == nil
        else {
            appendLog("人物跟踪无法启动：请等待 OM3 和当前动作就绪。")
            return nil
        }

        let session = UUID()
        activeTrackingSession = session
        activeTrackingSpeedMode = speedMode
        activeTrackingEnvelope = calibratedTrackingEnvelope ?? .conservativeDefault
        personTrackingActive = true
        trackingCommandAvailable = true
        trackingCooldownToken = UUID()
        trackingYawBudgetTenths = 0
        trackingPitchBudgetTenths = 0
        trackingYawTravelTenths = 0
        trackingPitchTravelTenths = 0
        nudgeAvailable = false
        nudgeCooldownToken = UUID()
        appendLog("人物跟踪已启用：进入目标获取状态。")
        return session
    }

    func sendPersonTrackingCorrection(
        _ correction: PersonTrackingCorrection,
        observedAtUptime: TimeInterval,
        session: UUID
    ) -> PersonTrackingCommandResult {
        guard state.isReady,
              motionSafetyArmed,
              activeTrackingSession == session,
              let activeTrackingSpeedMode,
              personTrackingActive
        else { return .inactive }
        guard trackingCommandAvailable else { return .busy }
        guard !correction.isZero else { return .busy }
        let combinedMagnitude = hypot(
            Double(correction.yawTenths),
            Double(correction.pitchTenths)
        )
        guard abs(correction.yawTenths) <= activeTrackingSpeedMode.yawMaximumTenths,
              abs(correction.pitchTenths) <= activeTrackingSpeedMode.pitchMaximumTenths,
              combinedMagnitude <= Double(activeTrackingSpeedMode.combinedMaximumTenths) + 0.01
        else {
            appendLog("人物跟踪修正超出当前速度档位上限，已拦截。")
            return .failed
        }
        let expiresAtUptime = observedAtUptime + activeTrackingSpeedMode.maximumSampleAge
        guard ProcessInfo.processInfo.systemUptime <= expiresAtUptime else {
            return .busy
        }

        guard let submittedCorrection = PersonTrackingPolicy
            .correctionClampedToNetSafetyBoundary(
                correction,
                currentYawTenths: trackingYawBudgetTenths,
                currentPitchTenths: trackingPitchBudgetTenths,
                envelope: activeTrackingEnvelope
            )
        else { return .boundaryReached }

        let nextYawBudget = trackingYawBudgetTenths + submittedCorrection.yawTenths
        let nextPitchBudget = trackingPitchBudgetTenths + submittedCorrection.pitchTenths
        let nextYawTravel = trackingYawTravelTenths + abs(submittedCorrection.yawTenths)
        let nextPitchTravel = trackingPitchTravelTenths + abs(submittedCorrection.pitchTenths)
        guard activeTrackingEnvelope.contains(
            yawTenths: nextYawBudget,
            pitchTenths: nextPitchBudget
        ) else {
            return .boundaryReached
        }
        guard nextYawTravel <= 900, nextPitchTravel <= 300 else {
            return .safetyBudgetExhausted
        }

        do {
            let frame = try OM3Protocol.relativeMove(
                yawTenths: submittedCorrection.yawTenths,
                pitchTenths: submittedCorrection.pitchTenths,
                durationTenths: activeTrackingSpeedMode.commandDurationTenths
            )
            trackingCommandAvailable = false
            let token = UUID()
            trackingCooldownToken = token
            let label = "人物跟踪 · Yaw \(formatTenths(submittedCorrection.yawTenths))° / Pitch \(formatTenths(submittedCorrection.pitchTenths))°"
            let submitted = enqueue(
                frame,
                label: label,
                completion: .tracking(
                    session: session,
                    token: token,
                    delay: activeTrackingSpeedMode.commandCooldown,
                    motionDelta: submittedCorrection
                ),
                expiresAtUptime: expiresAtUptime
            )
            guard submitted else {
                trackingCommandAvailable = true
                return .failed
            }
            return .submitted(submittedCorrection)
        } catch {
            trackingCommandAvailable = true
            appendLog("人物跟踪构帧失败：\(error.localizedDescription)")
            return .failed
        }
    }

    func sendPersonSearchStep(
        direction: PersonSearchDirection,
        mode: PersonSearchMotionMode,
        requestedAtUptime: TimeInterval,
        mustFinishByUptime: TimeInterval,
        session: UUID
    ) -> PersonSearchCommandResult {
        guard state.isReady,
              motionSafetyArmed,
              activeTrackingSession == session,
              activeTrackingSpeedMode != nil,
              personTrackingActive
        else { return .inactive }
        guard trackingCommandAvailable else { return .busy }

        let yawTenths: Int
        let reachesSoftBoundary: Bool
        let durationTenths: UInt8
        let cooldown: TimeInterval
        switch mode {
        case .coast:
            guard let step = PersonSearchPolicy.coastStep(
                currentYawTenths: trackingYawBudgetTenths,
                direction: direction
            ) else {
                return .softBoundaryReached
            }
            yawTenths = step.yawTenths
            reachesSoftBoundary = step.reachesSoftBoundary
            durationTenths = PersonSearchPolicy.coastDurationTenths
            cooldown = PersonSearchPolicy.coastCooldown
        case .scan:
            guard let step = PersonSearchPolicy.scanStep(
                currentYawTenths: trackingYawBudgetTenths,
                direction: direction
            ) else {
                return .softBoundaryReached
            }
            yawTenths = step.yawTenths
            reachesSoftBoundary = step.reachesSoftBoundary
            durationTenths = PersonSearchPolicy.scanDurationTenths
            cooldown = PersonSearchPolicy.scanCooldown
        }

        let latestFirstWriteAtUptime = PersonSearchPolicy.latestFirstWriteUptime(
            requestedAtUptime: requestedAtUptime,
            mustFinishByUptime: mustFinishByUptime,
            durationTenths: durationTenths
        )
        guard ProcessInfo.processInfo.systemUptime <= latestFirstWriteAtUptime else {
            return .busy
        }
        let nextYawBudget = trackingYawBudgetTenths + yawTenths
        guard activeTrackingEnvelope.contains(
            yawTenths: nextYawBudget,
            pitchTenths: trackingPitchBudgetTenths
        ) else {
            return .hardBoundaryReached
        }
        let nextYawTravel = trackingYawTravelTenths + abs(yawTenths)
        guard nextYawTravel <= 900 else {
            return .safetyBudgetExhausted
        }

        do {
            let frame = try OM3Protocol.relativeMove(
                yawTenths: yawTenths,
                pitchTenths: 0,
                durationTenths: durationTenths
            )
            trackingCommandAvailable = false
            let token = UUID()
            trackingCooldownToken = token
            let action = mode == .coast ? "出框惯性" : "自动扫描"
            let label = "人物搜索 · \(action) Yaw \(formatTenths(yawTenths))°"
            let submitted = enqueue(
                frame,
                label: label,
                completion: .tracking(
                    session: session,
                    token: token,
                    delay: cooldown,
                    motionDelta: PersonTrackingCorrection(
                        yawTenths: yawTenths,
                        pitchTenths: 0
                    )
                ),
                expiresAtUptime: latestFirstWriteAtUptime
            )
            guard submitted else {
                trackingCommandAvailable = true
                return .failed
            }
            return .submitted(
                yawTenths: yawTenths,
                reachesSoftBoundary: reachesSoftBoundary
            )
        } catch {
            trackingCommandAvailable = true
            appendLog("人物搜索构帧失败：\(error.localizedDescription)")
            return .failed
        }
    }

    @discardableResult
    func pausePersonTrackingWithStop(
        session: UUID,
        reason: String,
        cooldownOverride: TimeInterval? = nil
    ) -> Bool {
        guard state.isReady,
              activeTrackingSession == session,
              let activeTrackingSpeedMode,
              personTrackingActive
        else { return false }

        trackingCommandAvailable = false
        let token = UUID()
        trackingCooldownToken = token
        do {
            let stop = makePacket(
                try OM3Protocol.stopMessage(),
                label: reason,
                completion: .tracking(
                    session: session,
                    token: token,
                    delay: max(
                        cooldownOverride ?? activeTrackingSpeedMode.commandCooldown,
                        PersonTrackingPolicy.minimumStopCooldown
                    ),
                    motionDelta: nil
                ),
                expiresAtUptime: nil
            )
            prioritizeStopPacket(stop)
            return true
        } catch {
            appendLog("人物丢失 STOP 构帧失败：\(error.localizedDescription)")
            return false
        }
    }

    func endPersonTracking(session: UUID, reason: String, sendStop: Bool = true) {
        guard activeTrackingSession == session else { return }
        invalidatePersonTracking()
        discardCalibratedTrackingEnvelope(
            reason: "人物跟踪结束后姿态已离开校准原点；扩展范围已失效。"
        )
        appendLog(reason)
        if sendStop, state.isReady {
            enqueueStop(label: "人物跟踪关闭 STOP")
        } else if state.isReady {
            nudgeAvailable = true
        }
        motionSafetyArmed = false
        trackingOriginConfirmed = false
        appendLog("人物跟踪结束：请人工回正后重新打开运动安全确认。")
    }

    func stopMotion(reason: String = "STOP") {
        guard state.isReady else {
            appendLog("STOP 未发送：OM3 尚未就绪。")
            return
        }
        motionSafetyArmed = false
        invalidateRangeCalibration()
        trackingOriginConfirmed = false
        discardCalibratedTrackingEnvelope(reason: "STOP 后姿态不再可确认；扩展范围已失效。")
        enqueueStop(label: reason)
    }

    func bestEffortStopWhenAppBecomesInactive() {
        guard state.isReady else { return }
        motionSafetyArmed = false
        trackingOriginConfirmed = false
        invalidateRangeCalibration()
        discardCalibratedTrackingEnvelope(reason: nil)
        enqueueStop(label: "应用转入后台 STOP")
    }

    private func loadRememberedDevice() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.rememberedProtocolVersionKey)
                == Self.rememberedProtocolVersion,
              let rawID = defaults.string(forKey: Self.rememberedPeripheralIDKey),
              let identifier = UUID(uuidString: rawID)
        else { return }

        rememberedPeripheralID = identifier
        rememberedDeviceName = defaults.string(forKey: Self.rememberedPeripheralNameKey)
    }

    private func rememberValidatedDevice(_ peripheral: CBPeripheral, name: String) {
        rememberedPeripheralID = peripheral.identifier
        rememberedDeviceName = name
        let defaults = UserDefaults.standard
        defaults.set(peripheral.identifier.uuidString, forKey: Self.rememberedPeripheralIDKey)
        defaults.set(name, forKey: Self.rememberedPeripheralNameKey)
        defaults.set(
            Self.rememberedProtocolVersion,
            forKey: Self.rememberedProtocolVersionKey
        )

        automaticReconnectSuppressedForSession = false
        automaticReconnectPausedByValidationFailure = false
        automaticReconnectInProgress = false
        reconnectGeneration &+= 1
        appendLog("已记住 \(name)；以后启动应用会自动连接。")
    }

    private func beginConnection(to peripheral: CBPeripheral, origin: ConnectionOrigin) {
        guard central.state == .poweredOn, activePeripheral == nil else { return }

        central.stopScan()
        clearConnectionArtifacts()
        activePeripheral = peripheral
        retainedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        let attempt = UUID()
        switch origin {
        case .manual:
            connectionIntent = .manual(target: peripheral.identifier, attempt: attempt)
            automaticReconnectInProgress = false
        case .automatic:
            connectionIntent = .automatic(target: peripheral.identifier, attempt: attempt)
            automaticReconnectInProgress = true
        }

        let name = displayName(for: peripheral)
        state = .connecting(name)
        appendLog(
            origin == .automatic
                ? "正在自动连接 \(name)…"
                : "正在连接 \(name)…"
        )
        central.connect(
            peripheral,
            options: [
                CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
                CBConnectPeripheralOptionEnableAutoReconnect: true,
            ]
        )
    }

    private func startAutomaticReconnect(reason: String) {
        guard central.state == .poweredOn,
              activePeripheral == nil,
              let rememberedPeripheralID,
              !automaticReconnectSuppressedForSession,
              !automaticReconnectPausedByValidationFailure
        else { return }

        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        automaticReconnectInProgress = true
        central.stopScan()

        let retrieved = central.retrievePeripherals(withIdentifiers: [rememberedPeripheralID])
        if let peripheral = retrieved.first(where: {
            $0.identifier == rememberedPeripheralID
        }) {
            appendLog("正在找回已记住的 OM3（\(reason)）。")
            beginConnection(to: peripheral, origin: .automatic)
            return
        }

        connectionIntent = .automaticSearch(
            target: rememberedPeripheralID,
            generation: generation
        )
        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        appendLog("系统暂时无法恢复已记住的 UUID；正在扫描同一设备。")
    }

    private func scheduleAutomaticReconnect(reason: String) {
        guard central.state == .poweredOn,
              activePeripheral == nil,
              rememberedPeripheralID != nil,
              !automaticReconnectSuppressedForSession,
              !automaticReconnectPausedByValidationFailure
        else { return }

        reconnectGeneration &+= 1
        let generation = reconnectGeneration
        let delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 15, 30]
        let baseDelay = reconnectAttempt < delays.count
            ? delays[reconnectAttempt]
            : 60
        reconnectAttempt += 1
        let delay = baseDelay * Double.random(in: 0.8...1.2)
        automaticReconnectInProgress = true
        appendLog(
            String(format: "\(reason)；将在 %.1f 秒后自动重试。", delay)
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.reconnectGeneration == generation,
                  self.central.state == .poweredOn,
                  self.activePeripheral == nil,
                  !self.automaticReconnectSuppressedForSession,
                  !self.automaticReconnectPausedByValidationFailure
            else { return }
            self.startAutomaticReconnect(reason: "重试")
        }
    }

    private func cancelAutomaticReconnect(suppressForSession: Bool) {
        reconnectGeneration &+= 1
        automaticReconnectInProgress = false
        if suppressForSession {
            automaticReconnectSuppressedForSession = true
        }
        if case .automaticSearch = connectionIntent {
            central?.stopScan()
        }
    }

    @discardableResult
    private func enqueue(
        _ frame: Data,
        label: String,
        completion: PacketCompletion,
        expiresAtUptime: TimeInterval?
    ) -> Bool {
        guard state.isReady else { return false }
        guard packets.count < Self.packetLimit else {
            appendLog("发送队列已满；\(label) 未加入队列。")
            return false
        }
        packets.append(
            makePacket(
                frame,
                label: label,
                completion: completion,
                expiresAtUptime: expiresAtUptime
            )
        )
        pumpWrites()
        return true
    }

    private func lockNudges() -> UUID {
        nudgeAvailable = false
        let token = UUID()
        nudgeCooldownToken = token
        return token
    }

    private func scheduleNudgeUnlock(for token: UUID, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.nudgeCooldownToken == token,
                  self.state.isReady
            else { return }
            self.nudgeAvailable = true
        }
    }

    private func scheduleTrackingUnlock(
        session: UUID,
        token: UUID,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.activeTrackingSession == session,
                  self.trackingCooldownToken == token,
                  self.personTrackingActive,
                  self.state.isReady
            else { return }
            self.trackingCommandAvailable = true
        }
    }

    private func enqueueStop(label: String) {
        do {
            invalidatePersonTracking()
            // STOP also owns the current interlock. This prevents a new nudge from
            // being queued behind a back-pressured STOP frame.
            let stopToken = lockNudges()
            let stop = makePacket(
                try OM3Protocol.stopMessage(),
                label: label,
                completion: .manual(token: stopToken, delay: 1.15),
                expiresAtUptime: nil
            )
            prioritizeStopPacket(stop)
        } catch {
            appendLog("STOP 构帧失败：\(error.localizedDescription)")
        }
    }

    private func makePacket(
        _ frame: Data,
        label: String,
        completion: PacketCompletion,
        expiresAtUptime: TimeInterval?
    ) -> Packet {
        precondition(frame.count == 21, "OM3 rotation frames must be exactly 21 bytes")
        return Packet(
            label: label,
            chunks: [frame.subdata(in: 0..<20), frame.subdata(in: 20..<21)],
            completion: completion,
            expiresAtUptime: expiresAtUptime
        )
    }

    private func prioritizeStopPacket(_ stop: Packet) {
        // Never discard byte 21 of a frame whose first 20 bytes were already sent.
        if let head = packets.first, head.nextChunk > 0 {
            packets = [head, stop]
        } else {
            packets = [stop]
        }
        pumpWrites()
    }

    private func pumpWrites() {
        let canTransmit = state.isReady || state == .disconnecting
        guard canTransmit,
              let peripheral = activePeripheral,
              peripheral.state == .connected,
              let characteristic = writeCharacteristic,
              characteristic.properties.contains(.writeWithoutResponse)
        else { return }

        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= 20 else {
            failConnection("FFF5 的 ATT 写入上限小于 20 字节")
            return
        }

        while peripheral.canSendWriteWithoutResponse, !packets.isEmpty {
            var packet = packets.removeFirst()
            if packet.nextChunk == 0,
               let expiresAtUptime = packet.expiresAtUptime,
               ProcessInfo.processInfo.systemUptime > expiresAtUptime {
                appendLog("已丢弃过期的人物跟踪修正。")
                handleDroppedPacket(packet)
                continue
            }
            let expiredAfterFirstChunk = packet.nextChunk > 0
                && packet.expiresAtUptime.map {
                    ProcessInfo.processInfo.systemUptime > $0
                } == true
            let chunk = packet.chunks[packet.nextChunk]
            peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            if verboseLogging {
                appendLog(
                    "TX \(packet.label) [\(packet.nextChunk + 1)/2] · \(OM3Protocol.hex(chunk))"
                )
            }
            packet.nextChunk += 1

            if packet.nextChunk < packet.chunks.count {
                packets.insert(packet, at: 0)
            } else {
                if verboseLogging {
                    appendLog("\(packet.label) 已交给 CoreBluetooth（无设备 ACK）。")
                }
                var trackingMotionWasCommitted = false
                if expiredAfterFirstChunk,
                   case let .tracking(session, _, _, motionDelta) = packet.completion {
                    if session == activeTrackingSession,
                       let motionDelta {
                        commitTrackingMotion(motionDelta)
                        trackingMotionWasCommitted = true
                    }
                    appendLog("人物动作在分片发送中已过期；补齐尾字节后立即发送 STOP。")
                    let stopQueued = pausePersonTrackingWithStop(
                        session: session,
                        reason: "过期人物动作尾帧 STOP"
                    )
                    if stopQueued {
                        return
                    }
                    // The session may already have been invalidated by a stronger
                    // STOP path. Continue pumping so that its queued STOP cannot be
                    // stranded behind the just-completed tail byte.
                    continue
                }
                switch packet.completion {
                case .none:
                    break
                case let .manual(token, delay):
                    guard token == nudgeCooldownToken else { break }
                    scheduleNudgeUnlock(for: token, after: delay)
                case let .tracking(session, token, delay, motionDelta):
                    guard session == activeTrackingSession else { break }
                    if let motionDelta, !trackingMotionWasCommitted {
                        commitTrackingMotion(motionDelta)
                    }
                    guard token == trackingCooldownToken else { break }
                    scheduleTrackingUnlock(session: session, token: token, after: delay)
                }
            }
        }
        scheduleDisconnectWhenWritesAreSubmitted()
    }

    private func handleDroppedPacket(_ packet: Packet) {
        if case let .tracking(session, token, _, _) = packet.completion,
           session == activeTrackingSession,
           token == trackingCooldownToken,
           personTrackingActive {
            trackingCommandAvailable = true
        }
    }

    private func scheduleDisconnectWhenWritesAreSubmitted() {
        guard state == .disconnecting,
              packets.isEmpty,
              !disconnectCancelScheduled,
              let identifier = disconnectRequestedFor,
              let peripheral = activePeripheral,
              peripheral.identifier == identifier
        else { return }

        disconnectCancelScheduled = true
        let delay = disconnectNeedsWriteGrace ? 0.2 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral] in
            guard let self, let peripheral else { return }
            guard self.disconnectRequestedFor == identifier,
                  self.activePeripheral?.identifier == identifier
            else { return }
            self.central.cancelPeripheralConnection(peripheral)
        }
    }

    private func handlePeripheralDisconnected(
        _ central: CBCentralManager,
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }

        let intent = connectionIntent
        let wasManualDisconnect: Bool
        if case let .manualDisconnect(target) = intent {
            wasManualDisconnect = target == peripheral.identifier
        } else {
            wasManualDisconnect = disconnectRequestedFor == peripheral.identifier
        }
        let wasValidationFailure: Bool
        if case let .validationFailed(target) = intent {
            wasValidationFailure = target == peripheral.identifier
        } else {
            wasValidationFailure = false
        }
        let isRememberedTarget = rememberedPeripheralID == peripheral.identifier

        clearConnectionArtifacts()
        automaticReconnectInProgress = false

        if wasValidationFailure {
            if isReconnecting {
                central.cancelPeripheralConnection(peripheral)
            }
            activePeripheral = nil
            connectionIntent = .validationFailed(target: peripheral.identifier)
            appendLog("协议验证失败；已暂停自动重连，请手动扫描验证。")
            return
        }

        if wasManualDisconnect || automaticReconnectSuppressedForSession {
            if isReconnecting {
                central.cancelPeripheralConnection(peripheral)
            }
            activePeripheral = nil
            connectionIntent = .none
            state = central.state == .poweredOn ? .idle : .unavailable("蓝牙不可用")
            appendLog("OM3 已断开；运动控制已锁定。")
            return
        }

        if isReconnecting, isRememberedTarget {
            retainedPeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            activePeripheral = peripheral
            connectionIntent = .automatic(
                target: peripheral.identifier,
                attempt: UUID()
            )
            automaticReconnectInProgress = true
            state = .connecting(rememberedDeviceName ?? displayName(for: peripheral))
            if let error {
                appendLog(
                    "OM3 意外断开：\(error.localizedDescription)。系统正在自动重连，运动已锁定。"
                )
            } else {
                appendLog("OM3 链路已断开；系统正在自动重连，运动已锁定。")
            }
            return
        }

        if isReconnecting {
            // Auto-reconnect is only accepted for the UUID that previously passed
            // the complete OM3 GATT validation.
            central.cancelPeripheralConnection(peripheral)
        }
        activePeripheral = nil
        connectionIntent = .none
        state = central.state == .poweredOn ? .idle : .unavailable("蓝牙不可用")
        if let error {
            appendLog("OM3 意外断开：\(error.localizedDescription)。运动控制已锁定。")
        } else {
            appendLog("OM3 已断开；运动控制已锁定。")
        }

        if isRememberedTarget {
            scheduleAutomaticReconnect(reason: "OM3 连接已中断")
        }
    }

    private func clearConnectionArtifacts() {
        connectionEpoch &+= 1
        packets.removeAll()
        notifyCharacteristic = nil
        writeCharacteristic = nil
        nudgeAvailable = false
        motionSafetyArmed = false
        trackingOriginConfirmed = false
        invalidateRangeCalibration()
        discardCalibratedTrackingEnvelope(reason: nil)
        nudgeCooldownToken = UUID()
        invalidatePersonTracking()
        disconnectRequestedFor = nil
        disconnectNeedsWriteGrace = false
        disconnectCancelScheduled = false
    }

    private func invalidatePersonTracking() {
        activeTrackingSession = nil
        activeTrackingSpeedMode = nil
        activeTrackingEnvelope = .conservativeDefault
        personTrackingActive = false
        trackingCommandAvailable = false
        trackingCooldownToken = UUID()
        trackingYawBudgetTenths = 0
        trackingPitchBudgetTenths = 0
        trackingYawTravelTenths = 0
        trackingPitchTravelTenths = 0
    }

    /// Motion budgets describe frames whose complete 21 bytes were handed to
    /// CoreBluetooth. A packet dropped before its first byte, or replaced by a
    /// higher-priority STOP, must never move this estimate.
    private func commitTrackingMotion(_ delta: PersonTrackingCorrection) {
        trackingYawBudgetTenths += delta.yawTenths
        trackingPitchBudgetTenths += delta.pitchTenths
        trackingYawTravelTenths += abs(delta.yawTenths)
        trackingPitchTravelTenths += abs(delta.pitchTenths)
    }

    private func invalidateRangeCalibration() {
        activeRangeCalibrationSession = nil
        rangeCalibrationActive = false
    }

    private func discardCalibratedTrackingEnvelope(reason: String?) {
        guard calibratedTrackingEnvelope != nil else { return }
        calibratedTrackingEnvelope = nil
        if let reason {
            appendLog(reason)
        }
    }

    private func formatTenths(_ value: Int) -> String {
        String(format: "%+.1f", Double(value) / 10.0)
    }

    private func failConnection(_ message: String) {
        central.stopScan()
        let failedIdentifier = activePeripheral?.identifier
        if let failedIdentifier {
            connectionIntent = .validationFailed(target: failedIdentifier)
        }
        automaticReconnectPausedByValidationFailure = true
        automaticReconnectSuppressedForSession = true
        cancelAutomaticReconnect(suppressForSession: true)
        clearConnectionArtifacts()
        state = .error(message)
        appendLog("连接失败：\(message)")
        if let activePeripheral, activePeripheral.state != .disconnected {
            central.cancelPeripheralConnection(activePeripheral)
        } else {
            activePeripheral = nil
        }
    }

    private func appendLog(_ message: String) {
        logs.insert(OM3LogEntry(timestamp: Date(), message: message), at: 0)
        if logs.count > 100 {
            logs.removeLast(logs.count - 100)
        }
    }

    private func displayName(for peripheral: CBPeripheral) -> String {
        peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "未命名 BLE 设备"
    }

    private func sortDevices() {
        devices.sort {
            if $0.isLikelyOM3 != $1.isLikelyOM3 { return $0.isLikelyOM3 }
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

extension OM3BluetoothController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if activePeripheral == nil {
                if rememberedPeripheralID != nil,
                   !automaticReconnectSuppressedForSession,
                   !automaticReconnectPausedByValidationFailure {
                    startAutomaticReconnect(reason: "蓝牙已就绪")
                } else {
                    state = .idle
                }
            }
            appendLog("Mac 蓝牙已就绪。")
        case .poweredOff:
            cancelAutomaticReconnect(suppressForSession: false)
            central.stopScan()
            clearConnectionArtifacts()
            activePeripheral = nil
            connectionIntent = .none
            state = .unavailable("蓝牙已关闭")
            appendLog("蓝牙已关闭；连接和安全确认均已失效。")
        case .unauthorized:
            cancelAutomaticReconnect(suppressForSession: false)
            clearConnectionArtifacts()
            activePeripheral = nil
            connectionIntent = .none
            state = .unavailable("未获蓝牙权限")
            appendLog("请在“系统设置 → 隐私与安全性 → 蓝牙”允许 OM3 Lab。")
        case .unsupported:
            cancelAutomaticReconnect(suppressForSession: false)
            clearConnectionArtifacts()
            activePeripheral = nil
            connectionIntent = .none
            state = .unavailable("此 Mac 不支持 BLE")
        case .resetting:
            cancelAutomaticReconnect(suppressForSession: false)
            central.stopScan()
            clearConnectionArtifacts()
            activePeripheral = nil
            connectionIntent = .none
            state = .unavailable("蓝牙正在重置")
            appendLog("CoreBluetooth 正在重置；旧连接已作废，运动控制已锁定。")
        case .unknown:
            state = .unavailable("正在初始化蓝牙")
        @unknown default:
            state = .unavailable("未知蓝牙状态")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        retainedPeripherals[id] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? displayName(for: peripheral)

        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].name = name
            devices[index].rssi = RSSI.intValue
        } else {
            devices.append(
                OM3DiscoveredDevice(
                    id: id,
                    peripheral: peripheral,
                    name: name,
                    rssi: RSSI.intValue
                )
            )
        }
        sortDevices()

        if case let .automaticSearch(target, generation) = connectionIntent,
           target == id,
           generation == reconnectGeneration,
           !automaticReconnectSuppressedForSession,
           !automaticReconnectPausedByValidationFailure,
           activePeripheral == nil {
            appendLog("已扫描到记忆中的 OM3 UUID，正在自动连接。")
            beginConnection(to: peripheral, origin: .automatic)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == activePeripheral?.identifier,
              connectionIntent.target == peripheral.identifier
        else { return }
        if disconnectRequestedFor == peripheral.identifier {
            state = .disconnecting
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let name = displayName(for: peripheral)
        state = .discovering(name)
        appendLog("BLE 已连接；正在发现 FFF0 服务…")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }
        let intent = connectionIntent
        let reason = error?.localizedDescription ?? "设备拒绝连接"
        clearConnectionArtifacts()
        activePeripheral = nil
        automaticReconnectInProgress = false
        connectionIntent = .none

        if case .manualDisconnect = intent {
            state = central.state == .poweredOn ? .idle : .unavailable("蓝牙不可用")
            appendLog("OM3 连接已取消。")
            return
        }

        state = .error("连接失败")
        appendLog("无法连接 \(displayName(for: peripheral))：\(reason)")
        if intent.isAutomatic {
            scheduleAutomaticReconnect(reason: "自动连接失败")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        handlePeripheralDisconnected(
            central,
            peripheral: peripheral,
            isReconnecting: false,
            error: error
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handlePeripheralDisconnected(
            central,
            peripheral: peripheral,
            isReconnecting: isReconnecting,
            error: error
        )
    }
}

extension OM3BluetoothController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier,
              state.isDiscovering
        else { return }
        guard disconnectRequestedFor != peripheral.identifier else { return }
        if let error {
            failConnection("发现服务失败：\(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failConnection("该设备没有 OM3 FFF0 服务")
            return
        }
        appendLog("已发现 FFF0；正在查找 FFF4 / FFF5…")
        peripheral.discoverCharacteristics(
            [Self.notifyUUID, Self.writeUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier,
              state.isDiscovering,
              service.uuid == Self.serviceUUID,
              peripheral.services?.contains(where: { $0 === service }) == true
        else { return }
        guard disconnectRequestedFor != peripheral.identifier else { return }
        if let error {
            failConnection("发现特征失败：\(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.notifyUUID {
                notifyCharacteristic = characteristic
            } else if characteristic.uuid == Self.writeUUID {
                writeCharacteristic = characteristic
            }
        }

        guard let notifyCharacteristic, let writeCharacteristic else {
            failConnection("FFF4 或 FFF5 缺失")
            return
        }
        guard notifyCharacteristic.properties.contains(.notify) else {
            failConnection("FFF4 不支持通知")
            return
        }
        guard writeCharacteristic.properties.contains(.writeWithoutResponse) else {
            failConnection("FFF5 不支持无响应写入")
            return
        }
        guard peripheral.maximumWriteValueLength(for: .withoutResponse) >= 20 else {
            failConnection("FFF5 的 ATT 写入上限小于 20 字节")
            return
        }

        appendLog("FFF4 / FFF5 已验证；正在订阅通知…")
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier,
              state.isDiscovering,
              characteristic.uuid == Self.notifyUUID,
              notifyCharacteristic === characteristic,
              writeCharacteristic != nil
        else { return }
        guard disconnectRequestedFor != peripheral.identifier else { return }
        if let error {
            failConnection("订阅 FFF4 失败：\(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying else {
            failConnection("FFF4 通知未启用")
            return
        }

        let name = displayName(for: peripheral)
        let restoredAutomatically = connectionIntent.isAutomatic
        invalidatePersonTracking()
        rememberValidatedDevice(peripheral, name: name)
        state = .ready(name)
        nudgeCooldownToken = UUID()
        nudgeAvailable = false
        motionSafetyArmed = false
        enqueueStop(label: "连接初始化 STOP")
        appendLog(
            restoredAutomatically
                ? "FFF0 / FFF4 / FFF5 已重新验证；自动连接已恢复，运动安全确认仍保持关闭。"
                : "FFF0 / FFF4 / FFF5 已就绪；运动安全确认仍保持关闭。"
        )

        let stableEpoch = connectionEpoch
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  self.connectionEpoch == stableEpoch,
                  self.state.isReady,
                  self.activePeripheral?.identifier == peripheral.identifier
            else { return }
            self.reconnectAttempt = 0
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == activePeripheral?.identifier,
              state.isReady,
              characteristic.uuid == Self.notifyUUID,
              notifyCharacteristic === characteristic
        else { return }
        if let error {
            appendLog("RX 错误：\(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        if verboseLogging {
            appendLog("RX FFF4 · \(OM3Protocol.hex(value, limit: 24))")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral.identifier == activePeripheral?.identifier,
              state.isReady || state == .disconnecting
        else { return }
        pumpWrites()
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
