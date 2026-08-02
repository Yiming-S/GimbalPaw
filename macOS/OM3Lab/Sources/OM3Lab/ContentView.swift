import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var bluetooth: OM3BluetoothController
    @ObservedObject var camera: CameraController
    @ObservedObject var tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var safetyArmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HSplitView {
                CameraPanel(camera: camera, tracking: tracking)
                    .frame(minWidth: 610, idealWidth: 760)

                ControlPanel(
                    bluetooth: bluetooth,
                    camera: camera,
                    tracking: tracking,
                    calibration: calibration,
                    safetyArmed: $safetyArmed
                )
                    .frame(minWidth: 390, idealWidth: 440, maxWidth: 520)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: bluetooth.state) { _, newState in
            if !newState.isReady {
                safetyArmed = false
            }
        }
        .onChange(of: bluetooth.motionSafetyArmed) { _, armed in
            if !armed {
                safetyArmed = false
            }
        }
        .onChange(of: safetyArmed) { _, armed in
            bluetooth.setMotionSafetyArmed(armed)
            tracking.setSafetyArmed(armed)
            calibration.setSafetyArmed(armed)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                tracking.setAppActive(false, sendStopOnDisable: false)
                calibration.setAppActive(false, sendStopOnDisable: false)
                bluetooth.bestEffortStopWhenAppBecomesInactive()
                safetyArmed = false
            } else {
                tracking.setAppActive(true)
                calibration.setAppActive(true)
            }
        }
        .onAppear {
            bluetooth.setMotionSafetyArmed(safetyArmed)
            tracking.setSafetyArmed(safetyArmed)
            tracking.setAppActive(scenePhase == .active)
            calibration.setSafetyArmed(safetyArmed)
            calibration.setAppActive(scenePhase == .active)
        }
        .onDisappear {
            let shouldSendStop = safetyArmed
                || bluetooth.motionSafetyArmed
                || tracking.enabled
                || calibration.isRunning
            tracking.setAppActive(false, sendStopOnDisable: false)
            calibration.setAppActive(false, sendStopOnDisable: false)
            if shouldSendStop {
                bluetooth.bestEffortStopWhenAppBecomesInactive()
            }
            safetyArmed = false
            camera.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "viewfinder.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.cyan)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("OM3 Lab")
                        .font(.title2.weight(.semibold))
                    Text("实验联调版")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text("Apple Silicon 原生 · BLE 云台控制 · USB 摄像头预览")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(
                text: bluetooth.state.title,
                color: bluetooth.state.statusColor,
                symbol: bluetooth.state.isReady ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right"
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
    }
}

private struct CameraPanel: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var tracking: PersonTrackingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("USB 摄像头", systemImage: "video.fill")
                    .font(.headline)
                Spacer()
                if tracking.enabled {
                    StatusBadge(
                        text: tracking.state.title,
                        color: tracking.state.statusColor,
                        symbol: tracking.selectedPersonDetection == nil
                            ? "person.crop.circle.badge.questionmark"
                            : "person.crop.rectangle"
                    )
                }
                StatusBadge(
                    text: camera.status.title,
                    color: camera.status.statusColor,
                    symbol: camera.status.isRunning ? "record.circle.fill" : "video.slash"
                )
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black)

                CameraPreview(
                    session: camera.session,
                    personCandidates: tracking.visiblePeople,
                    selectedPersonID: tracking.selectedPersonID,
                    trackingEnabled: camera.personTrackingEnabled
                )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel(cameraPreviewAccessibilityLabel)

                if !camera.status.isRunning {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.ellipsis")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(camera.status.title)
                            .font(.headline)
                        Text(cameraOverlayHelp)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 360)
                    }
                    .padding(24)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
            .frame(minHeight: 390)

            HStack(spacing: 10) {
                if camera.devices.isEmpty {
                    Button {
                        camera.requestAccessAndRefresh()
                    } label: {
                        Label("启用并查找摄像头", systemImage: "video.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Picker(
                        "设备",
                        selection: Binding(
                            get: { camera.selectedDeviceID ?? "" },
                            set: { camera.selectAndStart($0) }
                        )
                    ) {
                        ForEach(camera.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .frame(maxWidth: 310)

                    Button(camera.status.isRunning ? "重新启动" : "开始预览") {
                        camera.startSelectedOrFirst()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    camera.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新外置摄像头列表")

                Button("停止") {
                    camera.stop()
                }
                .disabled(!camera.status.isRunning)

                Spacer()

                if camera.status == .denied {
                    Button("打开隐私设置") {
                        openCameraPrivacySettings()
                    }
                }
            }

            WiringStrip()
        }
        .padding(18)
    }

    private var cameraOverlayHelp: String {
        switch camera.status {
        case .denied:
            return "请允许 OM3 Lab 使用摄像头，然后返回应用刷新设备列表。"
        case let .error(message):
            return message
        default:
            return "摄像头 USB 线直接连接 Mac mini；OM3 不传输画面。"
        }
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var cameraPreviewAccessibilityLabel: String {
        guard tracking.enabled else { return "USB 摄像头实时预览" }
        let count = tracking.visiblePeople.count
        if let selected = tracking.selectedPersonID {
            let visibility = tracking.selectedPersonDetection == nil
                ? "未可靠关联"
                : "画面内"
            return "USB 摄像头实时预览，检测到 \(count) 人，已锁定\(selected.title)，\(visibility)"
        }
        return "USB 摄像头实时预览，检测到 \(count) 人，尚未锁定目标"
    }
}

private struct ControlPanel: View {
    @ObservedObject var bluetooth: OM3BluetoothController
    @ObservedObject var camera: CameraController
    @ObservedObject var tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator
    @Binding var safetyArmed: Bool
    @State private var showCandidateDevices = true
    @State private var showCalibrationStartConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionSection
                Divider()
                safetySection
                calibrationSection
                trackingSection
                motionSection
                Divider()
                logSection
            }
            .padding(18)
        }
        .onChange(of: bluetooth.state) { _, newState in
            if newState.isReady {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showCandidateDevices = false
                }
            }
        }
        .confirmationDialog(
            "开始全向安全行程验证？",
            isPresented: $showCalibrationStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("已置中并开始", role: .destructive) {
                calibration.start()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先把 OM3 人工置于居中起点，确认负载配平、摄像头刚性固定、软线在左右上下全程都有余量，周围无人和障碍物，并把手放在电源开关附近。左右每步 5°、最多验证 100°；上下每步 2°、最多验证 36°，每一步都会暂停等待确认。")
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("OM3 · BLE", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if bluetooth.state.isReady || bluetooth.state.isBusy {
                    Button("断开") {
                        bluetooth.disconnect()
                    }
                    .disabled(bluetooth.state == .disconnecting)
                } else if bluetooth.state == .scanning {
                    Button("停止扫描") {
                        bluetooth.stopScanning()
                    }
                } else {
                    Button("扫描") {
                        bluetooth.startScanning()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!bluetooth.state.canStartScan)
                }
            }

            Text("Mac 只通过 BLE 控制 OM3；OM3 的 USB 口仅用于可选充电。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let rememberedName = bluetooth.rememberedDeviceName {
                Label(
                    bluetooth.automaticReconnectInProgress
                        ? "正在自动找回 \(rememberedName)"
                        : "已记住 \(rememberedName) · 下次启动自动连接",
                    systemImage: bluetooth.automaticReconnectInProgress
                        ? "arrow.triangle.2.circlepath"
                        : "memorychip"
                )
                .font(.caption)
                .foregroundStyle(bluetooth.automaticReconnectInProgress ? .cyan : .secondary)
            }

            if bluetooth.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(
                            bluetooth.state == .scanning
                                || bluetooth.automaticReconnectInProgress ? 1 : 0
                        )
                    Text(connectionWaitingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .padding(.horizontal, 12)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showCandidateDevices.toggle()
                        }
                    } label: {
                        HStack {
                            Label(
                                "候选设备（\(bluetooth.devices.count)）",
                                systemImage: "dot.radiowaves.left.and.right"
                            )
                            Spacer()
                            Text(showCandidateDevices ? "收起" : "展开")
                                .foregroundStyle(.secondary)
                            Image(systemName: showCandidateDevices ? "chevron.up" : "chevron.down")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showCandidateDevices {
                        VStack(spacing: 7) {
                            ForEach(bluetooth.devices) { device in
                                DeviceRow(device: device, enabled: bluetooth.state.canConnectCandidate) {
                                    bluetooth.connect(to: device.id)
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(10)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $safetyArmed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("运动安全确认")
                        .font(.headline)
                    Text(safetyStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(
                !bluetooth.state.isReady
                    || (!safetyArmed
                        && (!bluetooth.nudgeAvailable
                            || bluetooth.personTrackingActive
                            || bluetooth.rangeCalibrationActive))
            )

            Label("云台已回到安全居中起点，负载配平，软线有余量，周围无碰撞风险", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(
                    safetyArmed && bluetooth.trackingOriginConfirmed
                        ? .green
                        : (safetyArmed ? .orange : .secondary)
                )
        }
        .padding(12)
        .background(
            safetyArmed ? Color.green.opacity(0.10) : Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(safetyArmed ? .green.opacity(0.28) : .orange.opacity(0.20))
        }
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("全向安全行程验证", systemImage: "scope")
                    .font(.headline)
                Spacer()
                if calibration.envelopeIsActive {
                    Text("已用于下次跟踪")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: Capsule())
                } else if calibration.isRunning {
                    Text("独占控制")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }

            Text(calibration.statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(calibration.isRunning ? .cyan : .primary)

            Text(calibration.detailText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if calibration.isRunning {
                ProgressView(value: calibration.progress)
                    .tint(.cyan)
                    .accessibilityLabel("全向行程验证进度")
                    .accessibilityValue("\(Int(calibration.progress * 100))%")

                if let direction = calibration.currentDirection {
                    HStack {
                        Label(direction.title, systemImage: calibrationDirectionSymbol(direction))
                        Spacer()
                        Text("已确认 \(calibration.currentVerifiedExtentDegrees)°")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }

            if let responseText = calibration.responseText {
                Label(responseText, systemImage: calibration.canContinueOutward
                    ? "camera.metering.center.weighted"
                    : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(calibration.canContinueOutward ? .cyan : .orange)
            }

            if let centerCheckText = calibration.centerCheckText {
                Label(centerCheckText, systemImage: "viewfinder")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if let result = calibration.result {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 7),
                        GridItem(.flexible(), spacing: 7),
                    ],
                    spacing: 7
                ) {
                    ForEach(result.measurements) { measurement in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(measurement.direction.shortTitle)
                                    .font(.caption.weight(.bold))
                                Spacer()
                                Text("可用 \(measurement.usableExtentDegrees)°")
                                    .font(.caption.monospacedDigit())
                            }
                            Text("验证 \(measurement.verifiedExtentDegrees)° · 余量 \(measurement.safetyMarginDegrees)°")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(measurement.note)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .padding(7)
                        .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }

            if calibration.awaitingStepDecision {
                HStack(spacing: 8) {
                    if calibration.canContinueOutward {
                        Button(confirmedDirectionButtonTitle) {
                            calibration.confirmObservedStepAndContinue()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button(
                        calibration.canContinueOutward
                            ? "这里作为安全端点"
                            : "确认疑似端点并返程"
                    ) {
                        calibration.stopAtCurrentSafeExtent()
                    }
                    .buttonStyle(.bordered)

                    Button("取消") {
                        calibration.cancel()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            } else if calibration.awaitingCenterConfirmation {
                HStack(spacing: 8) {
                    Button("已人工回正，继续") {
                        calibration.confirmReturnedToCenter()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("未回正，停止并作废") {
                        calibration.cancel()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            } else if calibration.isRunning {
                Button("STOP 并取消验证") {
                    calibration.cancel()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            } else {
                Button {
                    showCalibrationStartConfirmation = true
                } label: {
                    Label(
                        calibration.result == nil ? "开始全向验证" : "重新验证",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!calibration.canStart)

                if !calibration.canStart {
                    Text("需先启动 USB 摄像头、连接 OM3、开启运动安全确认，并关闭人物跟踪。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Label(
                "这是当前安装与线缆条件下的人工安全范围，不是机械限位；画面无响应也可能是阻塞或 BLE 未执行。",
                systemImage: "exclamationmark.shield"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
        }
        .padding(12)
        .background(
            calibration.isRunning ? Color.cyan.opacity(0.09) : Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(
                    calibration.isRunning ? .cyan.opacity(0.28) : .white.opacity(0.06)
                )
        }
    }

    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { tracking.enabled },
                    set: { tracking.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("人物跟踪")
                        .font(.headline)
                    Text(tracking.state.title)
                        .font(.caption)
                        .foregroundStyle(tracking.state.statusColor)
                }
            }
            .toggleStyle(.switch)
            .disabled(calibration.isRunning || (!tracking.enabled && !tracking.canEnable))

            if tracking.enabled {
                personSelectionSection
            }

            if let detection = tracking.selectedPersonDetection, tracking.enabled {
                HStack(spacing: 12) {
                    Label(
                        "置信度 \(Int(detection.confidence * 100))%",
                        systemImage: "person.crop.rectangle"
                    )
                    Text(
                        "X \(signedPercent(detection.centerX - 0.5)) · Y \(signedPercent(detection.centerY - 0.5))"
                    )
                    .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Text(trackingHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Label("Apple Vision 本机处理 · 画面不上传", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("跟踪速度", systemImage: "speedometer")
                    Spacer()
                    Text(tracking.speedMode.title)
                        .foregroundStyle(.cyan)
                }
                .font(.caption.weight(.medium))

                Picker(
                    "跟踪速度",
                    selection: Binding(
                        get: { tracking.speedMode },
                        set: { tracking.setSpeedMode($0) }
                    )
                ) {
                    ForEach(PersonTrackingSpeedMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(tracking.enabled)

                Text(
                    tracking.enabled
                        ? "关闭人物跟踪后可以切换档位"
                        : tracking.speedMode.detail
                )
                .font(.caption2)
                .foregroundStyle(.secondary)

                if tracking.speedMode == .fast {
                    Label(
                        "连续极速约为上一版极速档的 3 倍；动作之间无额外等待，请务必先空载测试并给软线留足余量。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }

                if tracking.enabled {
                    Label(
                        "人物出框后会先沿离场方向寻找，再在 ±20° 软件范围内自动扫描。",
                        systemImage: "arrow.left.and.right"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if tracking.canResumeSearch {
                    Button {
                        tracking.resumeSearch()
                    } label: {
                        Label("继续扫描", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(
            tracking.enabled ? Color.cyan.opacity(0.10) : Color.white.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(tracking.enabled ? .cyan.opacity(0.28) : .white.opacity(0.06))
        }
    }

    private var personSelectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(personCountText, systemImage: "person.2.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let selected = tracking.selectedPersonID {
                    Label("已锁定 \(selected.title)", systemImage: "lock.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            Text("首次识别默认锁定人物 1；点击其他人物编号可以立即切换。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !tracking.visiblePeople.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(tracking.visiblePeople) { candidate in
                            let isSelected = candidate.id == tracking.selectedPersonID
                            Button {
                                tracking.selectPerson(candidate.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: isSelected ? "lock.fill" : "person.fill")
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.id.title)
                                            .font(.caption.weight(.semibold))
                                        Text(candidateSummary(candidate))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(isSelected ? .green : .cyan)
                            .disabled(!tracking.canChangePersonSelection)
                            .accessibilityLabel(candidateAccessibilityLabel(candidate))
                        }
                    }
                }
            }

            if let selected = tracking.selectedPersonID,
               !tracking.visiblePeople.contains(where: { $0.id == selected }) {
                Label(
                    tracking.visiblePeople.isEmpty
                        ? "\(selected.title) 已出框，正在搜索；重新出现后请手动点选"
                        : "\(selected.title) 的可靠关联已中断；请从当前候选重新选择",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }

            if tracking.selectedPersonID != nil {
                Button {
                    tracking.clearPersonSelection()
                } label: {
                    Label("取消锁定并重新选择", systemImage: "lock.open")
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .disabled(!tracking.canChangePersonSelection)
            } else if tracking.hasAnalyzedPeopleFrame,
                      !tracking.visiblePeople.isEmpty {
                Text("点击一个人物编号后，云台才会开始跟随。")
                    .font(.caption2)
                    .foregroundStyle(.cyan)
            }
        }
        .padding(9)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private var motionSection: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("固定点动")
                        .font(.headline)
                    Text(
                        calibration.isRunning
                            ? "全向验证运行时手动点动停用"
                            : calibration.envelopeIsActive
                            ? "校准范围已绑定当前原点，请直接开始跟踪"
                            : tracking.enabled
                            ? "人物跟踪开启时手动点动停用"
                            : (bluetooth.nudgeAvailable
                                ? "每次 5° · 1.0 秒 · 单步互锁"
                                : "等待本次点动完成…")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("实验协议")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.12), in: Capsule())
            }

            VStack(spacing: 8) {
                NudgeButton(title: "上仰", symbol: "arrow.up", enabled: canMove) {
                    nudge(yaw: 0, pitch: -5, label: "上仰 · Pitch -5°")
                }

                HStack(spacing: 8) {
                    NudgeButton(title: "左转", symbol: "arrow.left", enabled: canMove) {
                        nudge(yaw: -5, pitch: 0, label: "左转 -5°")
                    }

                    Button {
                        emergencyStop()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("STOP").font(.caption.weight(.bold))
                        }
                        .frame(width: 88, height: 58)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!bluetooth.state.isReady)
                    .keyboardShortcut(.space, modifiers: [])

                    NudgeButton(title: "右转", symbol: "arrow.right", enabled: canMove) {
                        nudge(yaw: 5, pitch: 0, label: "右转 +5°")
                    }
                }

                NudgeButton(title: "下俯", symbol: "arrow.down", enabled: canMove) {
                    nudge(yaw: 0, pitch: 5, label: "下俯 · Pitch +5°")
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("联调日志", systemImage: "terminal")
                .font(.headline)

            ForEach(bluetooth.logs.prefix(12)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 58, alignment: .leading)
                    Text(entry.message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var canMove: Bool {
        bluetooth.state.isReady
            && safetyArmed
            && bluetooth.motionSafetyArmed
            && bluetooth.nudgeAvailable
            && !tracking.enabled
            && !calibration.isRunning
            && !calibration.envelopeIsActive
    }

    private var safetyStatusText: String {
        if !safetyArmed {
            return "默认锁定；断线后自动复位"
        }
        if !bluetooth.trackingOriginConfirmed {
            return "点动仍可用；人物跟踪前请回正并重新确认"
        }
        return "已解锁点动与全向安全行程验证"
    }

    private var connectionWaitingText: String {
        if bluetooth.state.isReady {
            return "OM3 已验证连接；运动安全确认仍需手动开启。"
        }
        if bluetooth.automaticReconnectInProgress {
            return "自动连接已启动；OM3 稍后开机也会自动接回。"
        }
        if bluetooth.state == .scanning {
            return "让 OM3 开机并靠近 Mac mini…"
        }
        return "扫描后会在这里列出 BLE 设备"
    }

    private func nudge(yaw: Int, pitch: Int, label: String) {
        guard safetyArmed else { return }
        bluetooth.sendNudge(yawDegrees: yaw, pitchDegrees: pitch, label: label)
    }

    private func emergencyStop() {
        if calibration.isRunning {
            calibration.emergencyStop()
        } else {
            tracking.emergencyStop()
        }
    }

    private func calibrationDirectionSymbol(_ direction: GimbalCalibrationDirection) -> String {
        switch direction {
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        }
    }

    private var confirmedDirectionButtonTitle: String {
        guard let direction = calibration.currentDirection else {
            return "确认实际移动，继续"
        }
        return "确认已\(direction.title)移动，继续"
    }

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private var personCountText: String {
        guard tracking.hasAnalyzedPeopleFrame else { return "正在分析人物…" }
        return "检测到 \(tracking.visiblePeople.count) 个可跟踪人物"
    }

    private func candidateSummary(_ candidate: PersonCandidate) -> String {
        "\(candidatePosition(candidate.detection.centerX)) · \(Int(candidate.detection.confidence * 100))%"
    }

    private func candidatePosition(_ centerX: Double) -> String {
        if centerX < 0.38 { return "左侧" }
        if centerX > 0.62 { return "右侧" }
        return "中央"
    }

    private func candidateAccessibilityLabel(_ candidate: PersonCandidate) -> String {
        let selection = candidate.id == tracking.selectedPersonID ? "已锁定" : "未锁定"
        return "\(candidate.id.title)，画面\(candidatePosition(candidate.detection.centerX))，置信度 \(Int(candidate.detection.confidence * 100))%，\(selection)"
    }

    private var trackingHelpText: String {
        if tracking.enabled, tracking.selectedPersonID == nil {
            if !tracking.hasAnalyzedPeopleFrame {
                return "正在分析摄像头画面；识别到人物后会默认锁定第一个候选。"
            }
            if tracking.visiblePeople.isEmpty {
                return "当前没有检测到可跟踪人物，请让目标完整进入画面。"
            }
            return "请选择一个人物编号；未锁定前云台不会自动运动。"
        }
        if tracking.canResumeSearch {
            return "人物分析仍在运行；确认线缆安全后可继续下一轮扫描。"
        }
        if case .motionPaused = tracking.state {
            return "人物分析仍在运行，但运动已因硬安全边界暂停。"
        }
        if tracking.enabled {
            return "请让目标人物进入画面；出框后会自动惯性寻找并左右扫描。"
        }
        if safetyArmed, !bluetooth.trackingOriginConfirmed {
            return "当前原点已因点动或 STOP 失效；请人工回正，关闭并重新打开运动安全确认。"
        }
        return "需先启动摄像头、连接 OM3 并打开运动安全确认。"
    }
}

private struct DeviceRow: View {
    let device: OM3DiscoveredDevice
    let enabled: Bool
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isLikelyOM3 ? "scope" : "dot.radiowaves.left.and.right")
                .foregroundStyle(device.isLikelyOM3 ? .cyan : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                    if device.isLikelyOM3 {
                        Text("候选 OM3")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                }
                Text("RSSI \(device.rssi) dBm · \(device.id.uuidString.prefix(8))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("连接", action: connect)
                .controlSize(.small)
                .disabled(!enabled)
        }
        .padding(9)
        .background(.white.opacity(device.isLikelyOM3 ? 0.065 : 0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct NudgeButton: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(width: 82, height: 38)
        }
        .buttonStyle(.bordered)
        .disabled(!enabled)
    }
}

private struct WiringStrip: View {
    var body: some View {
        HStack(spacing: 10) {
            Label("Mac mini", systemImage: "macmini")
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            Label("USB 摄像头", systemImage: "cable.connector")
            Spacer()
            Text("OM3 USB → 充电器（可选）")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }
}

private extension OM3ConnectionState {
    var statusColor: Color {
        switch self {
        case .ready: return .green
        case .scanning, .connecting, .discovering, .disconnecting: return .cyan
        case .error, .unavailable: return .orange
        case .idle: return .secondary
        }
    }

    var canStartScan: Bool {
        if case .idle = self { return true }
        if case .error = self { return true }
        return false
    }

    var canConnectCandidate: Bool {
        switch self {
        case .idle, .scanning, .error:
            return true
        default:
            return false
        }
    }
}

private extension CameraStatus {
    var statusColor: Color {
        switch self {
        case .running: return .green
        case .configuring, .requestingPermission, .stopping: return .cyan
        case .denied, .error: return .orange
        case .idle, .stopped: return .secondary
        }
    }
}

private extension PersonTrackingState {
    var statusColor: Color {
        switch self {
        case .locked, .centered:
            return .green
        case .awaitingSelection, .acquiring, .correcting, .reacquiring:
            return .cyan
        case .lossGrace, .coasting, .searching, .scanning:
            return .orange
        case .searchPaused, .motionPaused, .unavailable:
            return .orange
        case .off:
            return .secondary
        }
    }
}
