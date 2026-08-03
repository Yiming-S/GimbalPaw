import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    // Only `bluetooth` is observed at the window level (low-frequency state).
    // The vision-rate objects are passed through as plain references so their
    // ~12.5 Hz updates re-render only the leaf views that read them.
    @ObservedObject var bluetooth: OM3BluetoothController
    let camera: CameraController
    let tracking: PersonTrackingCoordinator
    let calibration: GimbalRangeCalibrationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var autoStopNotice: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let autoStopNotice {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(autoStopNotice)
                        .font(.caption)
                    Spacer()
                    Button("知道了") {
                        self.autoStopNotice = nil
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.12))
            }
            Divider()

            HSplitView {
                CameraPanel(
                    camera: camera,
                    tracking: tracking,
                    calibration: calibration
                )
                    .frame(minWidth: 610, idealWidth: 760)

                ControlPanel(
                    bluetooth: bluetooth,
                    camera: camera,
                    tracking: tracking,
                    calibration: calibration
                )
                    .frame(minWidth: 390, idealWidth: 440, maxWidth: 520)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        // The bluetooth controller owns the armed state; the UI only mirrors it.
        // A rejected arm request therefore never leaves a latched-on switch.
        .onChange(of: bluetooth.motionSafetyArmed) { _, armed in
            tracking.setSafetyArmed(armed)
            calibration.setSafetyArmed(armed)
            if armed {
                autoStopNotice = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                let calibrationWasRunning = calibration.isRunning
                let hadActiveMotion = tracking.enabled
                    || calibrationWasRunning
                    || bluetooth.motionSafetyArmed
                tracking.setAppActive(false, sendStopOnDisable: false)
                calibration.setAppActive(false, sendStopOnDisable: false)
                bluetooth.bestEffortStopWhenAppBecomesInactive()
                if hadActiveMotion {
                    autoStopNotice = calibrationWasRunning
                        ? "应用失去焦点时已 STOP 并锁定安全确认；已完成方向仍保留。返回后请人工回正、重新打开安全确认，再继续当前方向。"
                        : "应用失去焦点时已自动停止运动并锁定安全确认；返回后请检查云台姿态，再重新打开安全确认。"
                }
            } else {
                tracking.setAppActive(true)
                calibration.setAppActive(true)
            }
        }
        .onAppear {
            tracking.setSafetyArmed(bluetooth.motionSafetyArmed)
            tracking.setAppActive(scenePhase == .active)
            calibration.setSafetyArmed(bluetooth.motionSafetyArmed)
            calibration.setAppActive(scenePhase == .active)
        }
        .onDisappear {
            let shouldSendStop = bluetooth.motionSafetyArmed
                || tracking.enabled
                || calibration.isRunning
            tracking.setAppActive(false, sendStopOnDisable: false)
            calibration.setAppActive(false, sendStopOnDisable: false)
            if shouldSendStop {
                bluetooth.bestEffortStopWhenAppBecomesInactive()
            }
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
                Text("Apple Silicon 原生 · BLE 云台控制 · iPhone / 外置摄像头预览")
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
    let tracking: PersonTrackingCoordinator
    let calibration: GimbalRangeCalibrationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("摄像头", systemImage: "video.fill")
                    .font(.headline)
                Spacer()
                TrackingStateBadge(tracking: tracking)
                StatusBadge(
                    text: camera.status.title,
                    color: camera.status.statusColor,
                    symbol: camera.status.isRunning ? "record.circle.fill" : "video.slash"
                )
                .help(camera.status.title)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.black)

                TrackingCameraPreview(session: camera.session, tracking: tracking)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

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

            CameraControlsRow(
                camera: camera,
                tracking: tracking,
                calibration: calibration
            )
        }
        .padding(18)
    }

    private var cameraOverlayHelp: String {
        switch camera.status {
        case .denied:
            return "请允许 OM3 Lab 使用摄像头，然后返回应用刷新设备列表。"
        case .error:
            return "请确认 iPhone 连续互通相机可用，或检查外置摄像头连接与占用它的其他应用，然后重新启动预览。"
        default:
            return "画面来自所选 iPhone Camera 或外置摄像头；OM3 本身不向 Mac 传输画面。"
        }
    }
}

/// Leaf view: the only camera-panel element that re-renders on tracking-state
/// changes.
private struct TrackingStateBadge: View {
    @ObservedObject var tracking: PersonTrackingCoordinator

    var body: some View {
        if tracking.enabled {
            StatusBadge(
                text: tracking.state.title,
                color: tracking.state.statusColor,
                symbol: tracking.selectedPersonDetection == nil
                    ? "person.crop.circle.badge.questionmark"
                    : "person.crop.rectangle"
            )
            .help(tracking.state.title)
        }
    }
}

/// Leaf view around the AppKit preview: candidate boxes update at the vision
/// cadence without touching the rest of the camera panel. Clicking a drawn box
/// selects that person; pause states surface as an overlay banner with their
/// resume/exit action, instead of a truncated caption further down the page.
private struct TrackingCameraPreview: View {
    let session: AVCaptureSession
    @ObservedObject var tracking: PersonTrackingCoordinator

    var body: some View {
        CameraPreview(
            session: session,
            personCandidates: tracking.visiblePeople,
            selectedPersonID: tracking.selectedPersonID,
            trackingEnabled: tracking.enabled,
            onSelectCandidate: { candidateID in
                guard tracking.canChangePersonSelection else { return }
                tracking.selectPerson(candidateID)
            }
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
        .overlay(alignment: .top) {
            TrackingPauseBanner(tracking: tracking)
        }
    }

    private var accessibilityLabel: String {
        guard tracking.enabled else { return "所选摄像头实时预览" }
        let count = tracking.visiblePeople.count
        if let selected = tracking.selectedPersonID {
            let visibility = tracking.selectedPersonDetection == nil
                ? "未可靠关联"
                : "画面内"
            return "所选摄像头实时预览，检测到 \(count) 人，已锁定\(selected.title)，\(visibility)"
        }
        return "所选摄像头实时预览，检测到 \(count) 人，尚未锁定目标"
    }
}

private struct TrackingPauseBanner: View {
    @ObservedObject var tracking: PersonTrackingCoordinator

    var body: some View {
        switch tracking.state {
        case let .searchPaused(reason):
            banner(
                icon: "pause.circle.fill",
                title: "扫描已暂停",
                message: reason,
                tint: .orange
            ) {
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
        case let .motionPaused(reason):
            banner(
                icon: "exclamationmark.octagon.fill",
                title: "运动已暂停",
                message: "\(reason)。结束本次跟踪后，请人工回正并重新打开运动安全确认。",
                tint: .red
            ) {
                Button("结束本次跟踪") {
                    tracking.setEnabled(false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    private func banner(
        icon: String,
        title: String,
        message: String,
        tint: Color,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.5))
        }
        .padding(10)
    }
}

private struct CameraControlsRow: View {
    @ObservedObject var camera: CameraController
    @ObservedObject var tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator

    /// Device switching stays locked for the entire tracking/calibration
    /// lease. During an explicit calibration recovery pause, restarting or
    /// refreshing the same remembered camera is safe and must remain possible.
    private var selectionLocked: Bool {
        tracking.enabled || calibration.isRunning
    }

    private var previewActionsLocked: Bool {
        tracking.enabled || (calibration.isRunning && !calibration.manualRecoveryPaused)
    }

    var body: some View {
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
                        set: { deviceID in
                            guard deviceID != camera.selectedDeviceID else { return }
                            camera.selectAndStart(deviceID)
                        }
                    )
                ) {
                    if camera.selectedDeviceID == nil {
                        Text("未选择").tag("")
                    }
                    ForEach(camera.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .frame(maxWidth: 310)
                .disabled(selectionLocked)

                Button(camera.status.isRunning ? "重新启动" : "开始预览") {
                    camera.startSelectedOrFirst()
                }
                .buttonStyle(.borderedProminent)
                .disabled(previewActionsLocked)
            }

            Button {
                camera.refreshDevices()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新摄像头列表")
            .accessibilityLabel("刷新摄像头列表")
            .disabled(previewActionsLocked)

            Button("停止预览") {
                camera.stop()
            }
            .disabled(!camera.status.isRunning || previewActionsLocked)

            if selectionLocked {
                Text(
                    calibration.manualRecoveryPaused
                        ? "验证已暂停：可重启/刷新当前摄像头，设备切换仍锁定"
                        : "跟踪/验证运行中，摄像头切换已锁定"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if camera.status == .denied {
                Button("打开隐私设置") {
                    openCameraPrivacySettings()
                }
            }
        }
    }

    private func openCameraPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum AdvancedHelpPage: String, CaseIterable, Identifiable {
    case guide
    case manualControl
    case calibration
    case diagnostics

    var id: Self { self }

    var title: String {
        switch self {
        case .guide: return "使用说明"
        case .manualControl: return "手动控制"
        case .calibration: return "全向安全"
        case .diagnostics: return "诊断日志"
        }
    }

    var symbol: String {
        switch self {
        case .guide: return "book.closed"
        case .manualControl: return "dpad"
        case .calibration: return "scope"
        case .diagnostics: return "terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .guide: return "连接、跟踪与紧急停止"
        case .manualControl: return "固定角度点动调试"
        case .calibration: return "按当前安装验证四向安全范围"
        case .diagnostics: return "BLE 状态与逐包记录"
        }
    }
}

private struct ControlPanel: View {
    @ObservedObject var bluetooth: OM3BluetoothController
    @ObservedObject var camera: CameraController
    let tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator
    @State private var showCandidateDevices = true
    @State private var showCalibrationStartConfirmation = false
    @State private var showAdvancedHelp = false
    @State private var advancedHelpPage: AdvancedHelpPage = .guide

    private var safetyArmed: Bool { bluetooth.motionSafetyArmed }
    private var safetyReady: Bool {
        safetyArmed && bluetooth.trackingOriginConfirmed
    }

    var body: some View {
        VStack(spacing: 0) {
            if showAdvancedHelp {
                advancedControlPanel
            } else {
                if calibration.isRunning {
                    calibrationActivityBanner
                    Divider()
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        controlPanelHeader
                        connectionSection
                        safetySection
                        TrackingSection(
                            bluetooth: bluetooth,
                            tracking: tracking,
                            calibration: calibration
                        )
                    }
                    .padding(18)
                }
            }

            Divider()
            PersistentStopBar(
                tracking: tracking,
                calibration: calibration
            )
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
            Text("请先把 OM3 人工置于居中起点，确认负载配平、摄像头刚性固定、软线在左右上下全程都有余量，周围无人和障碍物，并把手放在电源开关附近。DJI 手册中的 Pan -162.5°～170.3°、Tilt -104.5°～235.7°是结构范围，不是本次安装可直接使用的对称控制范围；App 会分别验证左、右、上、下并保留端点余量。运行中可随时按 STOP。")
        }
    }

    private var controlPanelHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("控制中心")
                    .font(.title3.weight(.semibold))
                Text("连接 → 安全确认 → 选择速度 → 开始跟踪")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                openAdvancedHelp(.guide)
            } label: {
                Label("高级与帮助", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)
            .help("打开使用说明、全向安全验证和诊断日志")
            .accessibilityIdentifier("advancedHelpButton")
        }
    }

    private var advancedControlPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    showAdvancedHelp = false
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
                .accessibilityLabel("返回控制中心")

                VStack(alignment: .leading, spacing: 2) {
                    Text("高级控制与帮助")
                        .font(.headline)
                    Text(advancedHelpPage.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if calibration.isRunning {
                    Button {
                        advancedHelpPage = .calibration
                    } label: {
                        Label(
                            calibrationNeedsAttention
                                ? "需处理 \(Int(calibration.progress * 100))%"
                                : "验证 \(Int(calibration.progress * 100))%",
                            systemImage: "scope"
                        )
                        .monospacedDigit()
                    }
                    .controlSize(.small)
                    .tint(calibrationNeedsAttention ? .orange : .cyan)
                    .help("返回正在进行的全向安全验证")
                    .accessibilityIdentifier("activeCalibrationShortcut")
                    .accessibilityValue(
                        calibrationNeedsAttention ? "等待人工处理" : "自动进行中"
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Picker("高级与帮助页面", selection: $advancedHelpPage) {
                ForEach(AdvancedHelpPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .accessibilityIdentifier("advancedPagePicker")

            Divider()
            advancedHelpDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var advancedHelpDetail: some View {
        switch advancedHelpPage {
        case .guide:
            ScrollView {
                usageGuideSection
                    .padding(22)
            }
        case .manualControl:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    advancedPageHeader(
                        title: "手动控制",
                        subtitle: "固定点动只用于安装与方向调试；人物跟踪时不需要操作。",
                        symbol: "dpad"
                    )
                    MotionSection(
                        bluetooth: bluetooth,
                        tracking: tracking,
                        calibration: calibration
                    )
                    .padding(14)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(.white.opacity(0.06))
                    }
                }
                .padding(22)
            }
        case .calibration:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    advancedPageHeader(
                        title: "全向安全",
                        subtitle: "建立当前载荷、姿态和线缆条件下的四向跟踪硬边界。它不是每次启动都要执行的日常步骤。",
                        symbol: "scope"
                    )
                    calibrationSection
                }
                .padding(22)
            }
        case .diagnostics:
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    advancedPageHeader(
                        title: "诊断日志",
                        subtitle: "仅在排查连接或跟踪问题时使用；逐包日志默认保持关闭。",
                        symbol: "terminal"
                    )
                    TrackingDiagnosticsSection(tracking: tracking)
                    Divider()
                    logSection
                }
                .padding(22)
            }
        }
    }

    private var usageGuideSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            advancedPageHeader(
                title: "使用说明",
                subtitle: "主界面只保留日常使用所需的连接、安全确认、人物选择和跟踪控制。",
                symbol: "book.closed"
            )

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    guideStep(1, "选择摄像头", "在预览下方选择 iPhone Camera 或任意可用外置摄像头，并启动预览。")
                    guideStep(2, "连接 OM3", "OM3 开机后会优先自动连接记忆设备；需要更换时再展开候选列表。")
                    guideStep(3, "确认运动安全", "人工回中、检查配平和软线余量，再打开主界面的运动安全确认。")
                    guideStep(4, "选择并跟踪人物", "首次识别默认锁定人物 1；也可点击预览框或人物编号切换目标。")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("日常流程", systemImage: "checklist")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Mac mini ── BLE 无线 ── OM3")
                    Text("Mac mini ── 摄像头连接 ── iPhone Camera / USB 摄像头")
                    Text("OM3 ── USB 线 ── 充电器（可选，仅供电）")
                }
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("连接关系", systemImage: "cable.connector")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    Label("OM3 不向 Mac 传输画面；画面始终来自当前选择的摄像头。", systemImage: "video")
                    Label("摄像头线必须柔软并留足左右上下活动余量，避免拖拽云台。", systemImage: "cable.connector.horizontal")
                    Label("任何时候都可按主界面固定的 STOP 或空格键紧急停止云台。", systemImage: "stop.circle.fill")
                    Label("目标出框后会沿离场方向寻找，并在安全范围内上下左右扫描。", systemImage: "arrow.up.left.and.arrow.down.right")
                    Label("Apple Vision 在本机识别人像，视频画面不会上传。", systemImage: "lock.shield")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("关键说明", systemImage: "exclamationmark.shield")
            }
        }
    }

    private func advancedPageHeader(
        title: String,
        subtitle: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guideStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.cyan, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var calibrationActivityBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(
                    systemName: calibrationNeedsAttention
                        ? "exclamationmark.triangle.fill"
                        : "scope"
                )
                .foregroundStyle(calibrationNeedsAttention ? .orange : .cyan)

                VStack(alignment: .leading, spacing: 2) {
                    Text(calibrationNeedsAttention ? "全向验证等待处理" : "全向验证进行中")
                        .font(.caption.weight(.bold))
                    Text(calibrationSummaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button("打开详情") {
                    openAdvancedHelp(.calibration)
                }
                .controlSize(.small)
                .accessibilityIdentifier("calibrationActivityDetailsButton")
            }

            ProgressView(value: calibration.progress)
                .tint(calibrationNeedsAttention ? .orange : .cyan)
                .accessibilityLabel("全向安全验证进度")
                .accessibilityValue("\(Int(calibration.progress * 100))%")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            calibrationNeedsAttention
                ? Color.orange.opacity(0.10)
                : Color.cyan.opacity(0.08)
        )
        .accessibilityIdentifier("calibrationActivityBanner")
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
                    .accessibilityIdentifier("candidateDevicesDisclosure")

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
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.white.opacity(0.06))
        }
    }

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { bluetooth.motionSafetyArmed },
                    set: { bluetooth.setMotionSafetyArmed($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("运动安全确认")
                        .font(.headline)
                    Text(safetyStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("motionSafetyToggle")
            .accessibilityValue(motionSafetyAccessibilityValue)
            .disabled(
                !bluetooth.state.isReady
                    || (!safetyArmed
                        && (!bluetooth.nudgeAvailable
                            || bluetooth.personTrackingActive
                            || bluetooth.rangeCalibrationActive))
            )

            Label(
                safetyChecklistText,
                systemImage: safetyArmed && bluetooth.trackingOriginConfirmed
                    ? "checkmark.shield.fill"
                    : (safetyArmed ? "exclamationmark.shield" : "shield.slash")
            )
                .font(.caption)
                .foregroundStyle(
                    safetyArmed && bluetooth.trackingOriginConfirmed
                        ? .green
                        : (safetyArmed ? .orange : .secondary)
                )

            Divider()
                .opacity(0.55)

            HStack(alignment: .center, spacing: 9) {
                Image(
                    systemName: calibration.isRunning
                        ? "scope"
                        : (calibration.envelopeIsActive
                            ? "checkmark.circle.fill"
                            : "circle.dashed")
                )
                .foregroundStyle(
                    calibration.isRunning
                        ? .cyan
                        : (calibration.envelopeIsActive ? .green : .secondary)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(calibration.isRunning ? "全向验证进行中" : "跟踪硬边界")
                        .font(.caption.weight(.semibold))
                    Text(calibrationSummaryText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 6)

                Button(calibration.isRunning ? "打开" : "设置…") {
                    openAdvancedHelp(.calibration)
                }
                .controlSize(.small)
                .accessibilityLabel("安全范围与全向验证")
                .accessibilityIdentifier("calibrationEntryButton")
            }

        }
        .padding(12)
        .background(
            safetyReady ? Color.green.opacity(0.10) : Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(safetyReady ? .green.opacity(0.28) : .orange.opacity(0.20))
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
                    Text(
                        calibration.manualRecoveryPaused
                            ? "安全暂停 · 已保留进度"
                            : "自动连续 · 独占控制"
                    )
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

            Label(activeRangeText, systemImage: "move.3d")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(calibration.envelopeIsActive ? .green : .cyan)

            Text(calibrationCeilingText)
                .font(.caption2.monospacedDigit())
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

            if calibration.manualRecoveryPaused {
                HStack(spacing: 8) {
                    Button("我已人工回正，重试当前方向") {
                        calibration.confirmManualRecoveryAndRetryCurrentDirection()
                    }
                    .buttonStyle(.borderedProminent)
                    .help("清空当前方向的未知位移账本，重新取静止基线；已完成方向会保留")

                    Button("结束验证") {
                        calibration.cancel()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            } else if calibration.awaitingStepDecision {
                HStack(spacing: 8) {
                    if calibration.canContinueOutward {
                        Button(confirmedDirectionButtonTitle) {
                            calibration.confirmObservedStepAndContinue()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if calibration.canRetryCurrentStep {
                        Button("重试本步") {
                            calibration.retryCurrentStep()
                        }
                        .buttonStyle(.borderedProminent)
                        .help("场景恢复静止或干扰排除后，重新探测同一步")
                    }

                    Button(
                        calibration.canContinueOutward
                            ? "这里作为安全端点"
                            : calibration.requiresNoMovementConfirmation
                                ? "确认实体未移动，按原路返程"
                                : "按已确认路径返程"
                    ) {
                        calibration.stopAtCurrentSafeExtent()
                    }
                    .buttonStyle(.bordered)
                    .help(
                        calibration.requiresNoMovementConfirmation
                            ? "只有现场确认刚才的探测动作完全没有造成实体位移，才可使用此前已验证的步数自动返程"
                            : "结束当前方向，并按此前已确认的动作路径返程"
                    )

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
                .accessibilityIdentifier("startCalibrationButton")
                .disabled(!calibration.canStart)

                if !calibration.canStart {
                    Text("需先启动所选摄像头、连接 OM3、开启运动安全确认，并关闭人物跟踪。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Label(
                "官方结构范围只用于异常上限；当前安装的实测四向范围才是跟踪硬边界。换载荷、理线、横竖屏或握持姿态后请重新验证。",
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


    private var logSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("联调日志", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Toggle(
                    "逐包日志",
                    isOn: Binding(
                        get: { bluetooth.verboseLogging },
                        set: { bluetooth.setVerboseLogging($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("记录每个 BLE 分片的 TX/RX 十六进制内容；极速跟踪时会明显增加主线程负载")
            }

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

    private var activeRangeText: String {
        if let envelope = bluetooth.calibratedTrackingEnvelope {
            return "已绑定实测硬边界：左 \(degreeText(envelope.leftYawTenths))° · 右 \(degreeText(envelope.rightYawTenths))° · 上 \(degreeText(envelope.upPitchTenths))° · 下 \(degreeText(envelope.downPitchTenths))°"
        }
        let fallback = OM3HardwareMotionLimits.centeredFallbackEnvelopeDegrees
        return "未标定回中硬边界：左/右各 \(fallback.left)° · 上/下各 \(fallback.up)°；全向验证后按四个方向分别扩大"
    }

    private var calibrationCeilingText: String {
        let probe = OM3HardwareMotionLimits.probeCapsDegrees
        let tracking = OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees
        return "App 探测上限 左/右/上/下 \(probe.left)°/\(probe.right)°/\(probe.up)°/\(probe.down)°；扣除余量后的跟踪最大值 \(tracking.left)°/\(tracking.right)°/\(tracking.up)°/\(tracking.down)°"
    }

    private func degreeText(_ tenths: Int) -> String {
        String(format: "%.1f", Double(tenths) / 10.0)
    }

    private var calibrationSummaryText: String {
        if calibration.isRunning {
            if calibration.manualRecoveryPaused {
                return "安全暂停 · 已保留进度 · 打开后按提示人工处理"
            }
            if let direction = calibration.currentDirection {
                return "正在验证\(direction.title)方向 · \(Int(calibration.progress * 100))%"
            }
            return "正在准备验证 · \(Int(calibration.progress * 100))%"
        }
        if calibration.envelopeIsActive {
            return "当前安装的四向实测范围已启用"
        }
        if calibration.result != nil {
            return "上次测量仅供查看；扩展范围已失效，需回中后重新验证"
        }
        return "使用保守默认范围；需要时可进行全向验证"
    }

    private var calibrationNeedsAttention: Bool {
        calibration.manualRecoveryPaused
            || calibration.awaitingStepDecision
            || calibration.awaitingCenterConfirmation
    }

    private var motionSafetyAccessibilityValue: String {
        if !safetyArmed { return "运动已锁定" }
        if !bluetooth.trackingOriginConfirmed { return "已允许点动，跟踪原点失效" }
        return "已允许运动，原点已确认"
    }

    private var safetyStatusText: String {
        if !safetyArmed {
            return "默认锁定；断线后自动复位"
        }
        if !bluetooth.trackingOriginConfirmed {
            return "点动仍可用；人物跟踪前请回正并重新确认"
        }
        return "原点已确认，可以开始人物跟踪"
    }

    private var safetyChecklistText: String {
        if safetyArmed, bluetooth.trackingOriginConfirmed {
            return "已确认：云台位于安全居中起点，负载配平，软线有余量，周围无碰撞风险"
        }
        if safetyArmed {
            return "原点未确认：请人工回正后关闭并重新打开安全确认，再开始跟踪"
        }
        return "开启前请确认：云台回到居中起点，负载配平，软线有余量，周围无碰撞风险"
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

    private func openAdvancedHelp(_ page: AdvancedHelpPage) {
        advancedHelpPage = page
        showAdvancedHelp = true
    }

    private func emergencyStop() {
        if calibration.isRunning {
            calibration.emergencyStop()
        } else {
            tracking.emergencyStop()
        }
    }

}

/// A non-scrolling emergency control. Keeping the high-frequency tracking
/// observation in this leaf prevents the rest of the control column from being
/// rebuilt on every Vision update while still keeping the status current.
private struct PersistentStopBar: View {
    @ObservedObject var tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("全局运动保护")
                    .font(.caption.weight(.semibold))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                emergencyStop()
            } label: {
                Label("STOP", systemImage: "stop.fill")
                    .font(.callout.weight(.bold))
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .keyboardShortcut(.space, modifiers: [])
            .help("紧急停止云台（空格键）；始终可用，未连接时按下无副作用")
            .accessibilityLabel("紧急停止云台")
            .accessibilityHint("始终可用，按空格键也可以触发")
            .accessibilityIdentifier("globalEmergencyStop")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.bar)
    }

    private var statusText: String {
        if calibration.isRunning {
            if calibration.manualRecoveryPaused
                || calibration.awaitingStepDecision
                || calibration.awaitingCenterConfirmation {
                return "全向验证等待处理 · 空格键立即停止"
            }
            return "全向验证自动进行中 · 空格键立即停止"
        }
        if tracking.enabled {
            switch tracking.state {
            case .motionPaused, .searchPaused:
                return "人物跟踪已暂停 · 空格键仍可停止"
            default:
                return "人物跟踪已开启 · 空格键立即停止"
            }
        }
        return "STOP 始终可用 · 空格键立即停止"
    }

    private func emergencyStop() {
        if calibration.isRunning {
            calibration.emergencyStop()
        } else {
            tracking.emergencyStop()
        }
    }
}

/// The whole person-tracking control block. This is the main consumer of the
/// vision-rate coordinator state, isolated so its updates stay off the rest of
/// the control column.
private struct TrackingSection: View {
    @ObservedObject var bluetooth: OM3BluetoothController
    @ObservedObject var tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator

    var body: some View {
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
            .accessibilityIdentifier("personTrackingToggle")
            .disabled(calibration.isRunning || (!tracking.enabled && !tracking.canEnable))

            if tracking.enabled {
                personSelectionSection
            }

            if let detection = tracking.selectedPersonDetection, tracking.enabled {
                Label(
                    "目标保持中 · 置信度 \(Int(detection.confidence * 100))%",
                    systemImage: "person.crop.rectangle"
                )
                .font(.caption)
                .foregroundStyle(.green)
            } else {
                Text(trackingHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                .accessibilityIdentifier("trackingSpeedPicker")
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
                        "连续极速会增加制动距离；请确认全行程净空和线缆余量。",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
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

            Text("首次识别默认锁定人物 1；点击预览中的人物框或下方编号可以立即切换。")
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
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                            .accessibilityHint(
                                tracking.canChangePersonSelection
                                    ? "点击后云台改为跟随该人物"
                                    : "运动已暂停，当前不能切换人物"
                            )
                        }
                    }
                }
            }

            if let selected = tracking.selectedPersonID,
               !tracking.visiblePeople.contains(where: { $0.id == selected }) {
                Label(
                    tracking.visiblePeople.isEmpty
                        ? "\(selected.title) 已出框，正在搜索；画面中只有一人时会自动重锁"
                        : "\(selected.title) 的可靠关联已中断；可点选候选或等待单人自动重锁",
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
        if tracking.enabled {
            return "请让目标人物进入画面；可见时同时修正左右与上下，出框后会按离场方向惯性寻找并做二维扫描。"
        }
        if bluetooth.motionSafetyArmed, !bluetooth.trackingOriginConfirmed {
            return "当前原点已因点动或 STOP 失效；请人工回正，关闭并重新打开运动安全确认。"
        }
        return "需先启动摄像头、连接 OM3 并打开运动安全确认。"
    }
}

private struct TrackingDiagnosticsSection: View {
    @ObservedObject var tracking: PersonTrackingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("人物跟踪诊断", systemImage: "viewfinder")
                    .font(.headline)
                Spacer()
                Text(tracking.enabled ? "运行中" : "未运行")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tracking.enabled ? .green : .secondary)
            }

            diagnosticRow("状态", tracking.state.title)
            diagnosticRow("速度", tracking.speedMode.title)
            diagnosticRow(
                "候选人物",
                tracking.hasAnalyzedPeopleFrame
                    ? "\(tracking.visiblePeople.count) 人"
                    : "尚未分析"
            )
            diagnosticRow("锁定目标", tracking.selectedPersonID?.title ?? "无")

            if let detection = tracking.selectedPersonDetection {
                let headAnchorY = PersonTrackingPolicy.headAnchorY(for: detection)
                Divider()
                diagnosticRow("置信度", "\(Int(detection.confidence * 100))%")
                diagnosticRow("水平误差", signedPercent(detection.centerX - 0.5))
                diagnosticRow("头部锚点 Y", normalizedPercent(headAnchorY))
                diagnosticRow(
                    "Pitch 误差",
                    signedPercent(headAnchorY - PersonTrackingPolicy.verticalHeadAnchorTarget)
                )
            }
        }
        .padding(12)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.white.opacity(0.06))
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func signedPercent(_ value: Double) -> String {
        String(format: "%+.0f%%", value * 100)
    }

    private func normalizedPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

private struct MotionSection: View {
    @ObservedObject var bluetooth: OM3BluetoothController
    @ObservedObject var tracking: PersonTrackingCoordinator
    @ObservedObject var calibration: GimbalRangeCalibrationCoordinator

    private var canMove: Bool {
        bluetooth.state.isReady
            && bluetooth.motionSafetyArmed
            && bluetooth.nudgeAvailable
            && !tracking.enabled
            && !calibration.isRunning
            && !calibration.envelopeIsActive
    }

    var body: some View {
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

                    VStack(spacing: 3) {
                        Image(systemName: "dot.circle")
                        Text("每步 5°")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 88, height: 58)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)

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

    private func nudge(yaw: Int, pitch: Int, label: String) {
        guard bluetooth.motionSafetyArmed else { return }
        bluetooth.sendNudge(yawDegrees: yaw, pitchDegrees: pitch, label: label)
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
