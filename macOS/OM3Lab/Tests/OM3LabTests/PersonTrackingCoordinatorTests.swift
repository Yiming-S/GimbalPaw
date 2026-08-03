import Combine
import XCTest
@testable import OM3Lab

@MainActor
private final class MockTrackingBluetooth: PersonTrackingBluetoothControlling {
    var state: OM3ConnectionState = .ready("Mock OM3") {
        didSet { stateSubject.send(state) }
    }
    var nudgeAvailable = true {
        didSet { nudgeSubject.send(nudgeAvailable) }
    }
    var motionSafetyArmed = true
    var trackingOriginConfirmed = true {
        didSet { originSubject.send(trackingOriginConfirmed) }
    }
    var personTrackingActive = false {
        didSet { activeSubject.send(personTrackingActive) }
    }

    private let stateSubject = CurrentValueSubject<OM3ConnectionState, Never>(
        .ready("Mock OM3")
    )
    private let nudgeSubject = CurrentValueSubject<Bool, Never>(true)
    private let originSubject = CurrentValueSubject<Bool, Never>(true)
    // The coordinator reads the current value directly for initial availability;
    // publisher events model subsequent session transitions only. A current-
    // value subject would enqueue a stale initial `false` through receive(on:)
    // and could tear down a just-started async test session.
    private let activeSubject = PassthroughSubject<Bool, Never>()

    var statePublisher: AnyPublisher<OM3ConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    var nudgeAvailablePublisher: AnyPublisher<Bool, Never> {
        nudgeSubject.eraseToAnyPublisher()
    }
    var trackingOriginConfirmedPublisher: AnyPublisher<Bool, Never> {
        originSubject.eraseToAnyPublisher()
    }
    var personTrackingActivePublisher: AnyPublisher<Bool, Never> {
        activeSubject.eraseToAnyPublisher()
    }

    private(set) var submittedCorrections: [PersonTrackingCorrection] = []
    private(set) var correctionAttempts: [PersonTrackingCorrection] = []
    var scriptedCorrectionResults: [PersonTrackingCommandResult] = []
    private(set) var searchStepModes: [PersonSearchMotionMode] = []
    private(set) var searchDirections: [PersonSearchDirection] = []
    private(set) var searchCorrections: [PersonTrackingCorrection] = []
    var scriptedSearchResults: [PersonSearchCommandResult] = []
    private(set) var stopReasons: [String] = []
    private(set) var stopAttempts: [String] = []
    var scriptedStopResults: [Bool] = []
    private(set) var activeSession: UUID?

    func beginPersonTracking(speedMode: PersonTrackingSpeedMode) -> UUID? {
        let session = UUID()
        activeSession = session
        personTrackingActive = true
        return session
    }

    func sendPersonTrackingCorrection(
        _ correction: PersonTrackingCorrection,
        observedAtUptime: TimeInterval,
        session: UUID
    ) -> PersonTrackingCommandResult {
        guard session == activeSession else { return .inactive }
        correctionAttempts.append(correction)
        let result = scriptedCorrectionResults.isEmpty
            ? .submitted(correction)
            : scriptedCorrectionResults.removeFirst()
        if case let .submitted(submittedCorrection) = result {
            submittedCorrections.append(submittedCorrection)
        }
        return result
    }

    func sendPersonSearchStep(
        direction: PersonSearchDirection,
        mode: PersonSearchMotionMode,
        requestedAtUptime: TimeInterval,
        mustFinishByUptime: TimeInterval,
        session: UUID
    ) -> PersonSearchCommandResult {
        guard session == activeSession else { return .inactive }
        searchStepModes.append(mode)
        searchDirections.append(direction)
        if !scriptedSearchResults.isEmpty {
            return scriptedSearchResults.removeFirst()
        }
        let correction = PersonSearchPolicy.requestedStep(direction: direction, mode: mode)
        searchCorrections.append(correction)
        return .submitted(
            correction: correction,
            reachesSoftBoundary: false
        )
    }

    func pausePersonTrackingWithStop(
        session: UUID,
        reason: String,
        cooldownOverride: TimeInterval?
    ) -> Bool {
        guard session == activeSession else { return false }
        stopAttempts.append(reason)
        let accepted = scriptedStopResults.isEmpty
            ? true
            : scriptedStopResults.removeFirst()
        guard accepted else { return false }
        stopReasons.append(reason)
        return true
    }

    func endPersonTracking(session: UUID, reason: String, sendStop: Bool) {
        guard session == activeSession else { return }
        activeSession = nil
        personTrackingActive = false
    }

    func stopMotion(reason: String) {
        stopReasons.append(reason)
    }
}

@MainActor
private final class MockTrackingCamera: PersonTrackingCameraControlling {
    var status: CameraStatus = .running("Mock UVC") {
        didSet { statusSubject.send(status) }
    }
    private let statusSubject = CurrentValueSubject<CameraStatus, Never>(
        .running("Mock UVC")
    )
    var statusPublisher: AnyPublisher<CameraStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }
    var personTrackingEnabled = false
    var motionCalibrationEnabled = false
    var onPersonSample: ((PersonVisionSample) -> Void)?
    let visionSessionID = UUID()
    private(set) var seedHistory: [PersonDetection?] = []

    func setPersonTrackingEnabled(_ enabled: Bool) {
        personTrackingEnabled = enabled
    }

    func setPersonTrackingSeed(_ detection: PersonDetection?) {
        seedHistory.append(detection)
    }

    func isPersonTrackingSessionValid(_ sessionID: UUID) -> Bool {
        personTrackingEnabled && sessionID == visionSessionID
    }

    func withValidPersonTrackingSession<Result>(
        _ sessionID: UUID,
        operation: () -> Result
    ) -> Result? {
        guard isPersonTrackingSessionValid(sessionID) else { return nil }
        return operation()
    }
}

/// End-to-end phase-machine tests for the reacquisition flow introduced in
/// 0.9. The 0.6 regression that turned scan reacquisition into dead code was
/// invisible to the pure-policy tests; these exercise the coordinator wiring
/// itself with scripted BLE results and controlled sample timestamps.
@MainActor
final class PersonTrackingCoordinatorTests: XCTestCase {
    private var bluetooth: MockTrackingBluetooth!
    private var camera: MockTrackingCamera!
    private var coordinator: PersonTrackingCoordinator!
    private var sequence: UInt64 = 0

    override func setUp() async throws {
        bluetooth = MockTrackingBluetooth()
        camera = MockTrackingCamera()
        coordinator = PersonTrackingCoordinator(bluetooth: bluetooth, camera: camera)
        coordinator.setSpeedMode(.fast)
        coordinator.setAppActive(true)
        coordinator.setSafetyArmed(true)
        sequence = 0
    }

    override func tearDown() async throws {
        coordinator.setEnabled(false)
        coordinator = nil
        camera = nil
        bluetooth = nil
    }

    private func person(centerX: Double, centerY: Double = 0.42) -> PersonDetection {
        PersonDetection(
            x: centerX - 0.10,
            y: centerY - 0.20,
            width: 0.20,
            height: 0.40,
            confidence: 0.9
        )
    }

    private func send(_ detections: [PersonDetection], at uptime: TimeInterval) {
        sequence += 1
        camera.onPersonSample?(
            PersonVisionSample(
                sessionID: camera.visionSessionID,
                detections: detections,
                sequence: sequence,
                observedAtUptime: uptime
            )
        )
    }

    private func sendTracker(_ detection: PersonDetection, at uptime: TimeInterval) {
        sequence += 1
        camera.onPersonSample?(
            PersonVisionSample(
                sessionID: camera.visionSessionID,
                detections: [detection],
                selectedDetection: detection,
                sequence: sequence,
                observedAtUptime: uptime,
                origin: .tracker
            )
        )
    }

    /// Enables tracking and stabilizes the automatic first lock on a person at
    /// `centerX`. Returns the timestamp of the last valid detector frame.
    @discardableResult
    private func acquireLock(
        centerX: Double,
        centerY: Double = 0.42,
        base: TimeInterval
    ) -> TimeInterval {
        coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.enabled, "tracking must enable with ready mocks")
        send([person(centerX: centerX, centerY: centerY)], at: base)
        send([person(centerX: centerX, centerY: centerY)], at: base + 0.12)
        let lastValid = base + 0.26
        send([person(centerX: centerX, centerY: centerY)], at: lastValid)
        XCTAssertNotNil(coordinator.selectedPersonID, "first candidate must auto-lock")
        return lastValid
    }

    func testAcquisitionDrivesCorrectionTowardPerson() {
        let base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.30, base: base)
        XCTAssertEqual(bluetooth.submittedCorrections.count, 1)
        XCTAssertLessThan(bluetooth.submittedCorrections[0].yawTenths, 0)
        XCTAssertFalse(camera.seedHistory.compactMap { $0 }.isEmpty,
                       "detector frames must seed the correlation tracker")
    }

    func testAcquisitionSubmitsUpwardAndDownwardPitchCorrections() {
        var base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.50, centerY: 0.30, base: base)
        XCTAssertEqual(bluetooth.submittedCorrections.count, 1)
        XCTAssertEqual(bluetooth.submittedCorrections[0].yawTenths, 0)
        XCTAssertLessThan(bluetooth.submittedCorrections[0].pitchTenths, 0)

        coordinator.setEnabled(false)
        bluetooth = MockTrackingBluetooth()
        camera = MockTrackingCamera()
        coordinator = PersonTrackingCoordinator(bluetooth: bluetooth, camera: camera)
        coordinator.setSpeedMode(.fast)
        coordinator.setAppActive(true)
        coordinator.setSafetyArmed(true)
        sequence = 0
        base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.50, centerY: 0.56, base: base)
        XCTAssertEqual(bluetooth.submittedCorrections.count, 1)
        XCTAssertEqual(bluetooth.submittedCorrections[0].yawTenths, 0)
        XCTAssertGreaterThan(bluetooth.submittedCorrections[0].pitchTenths, 0)
    }

    func testMajorPitchReversalUsesCriticalStopPath() {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.50, centerY: 0.25, base: base)
        XCTAssertLessThan(bluetooth.submittedCorrections.last?.pitchTenths ?? 0, 0)

        sendTracker(person(centerX: 0.50, centerY: 0.90), at: lastValid + 0.10)
        XCTAssertTrue(
            bluetooth.stopReasons.contains { $0.contains("方向反转") },
            "a significant up-to-down Pitch reversal must issue STOP"
        )
    }

    func testInitialLockUsesOuterDeadZoneBeforeMoving() {
        let base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.60, base: base)

        XCTAssertTrue(
            bluetooth.submittedCorrections.isEmpty,
            "a new lock inside the outer dead zone must not receive a minimum nudge"
        )
        XCTAssertEqual(coordinator.state, .centered)
    }

    func testCenterStopClearsOldDirectionBeforeOppositeDeparture() {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.30, base: base)
        XCTAssertEqual(bluetooth.submittedCorrections.count, 1)
        XCTAssertLessThan(bluetooth.submittedCorrections[0].yawTenths, 0)

        send([person(centerX: 0.50)], at: lastValid + 0.10)
        XCTAssertEqual(coordinator.state, .centered)
        XCTAssertTrue(
            bluetooth.stopReasons.contains { $0.contains("进入中心死区") },
            "entering the center after a burst must issue STOP"
        )
        let reversalStopsBeforeDeparture = bluetooth.stopReasons.filter {
            $0.contains("方向反转")
        }.count

        send([person(centerX: 0.70)], at: lastValid + 0.20)
        XCTAssertEqual(
            bluetooth.stopReasons.filter { $0.contains("方向反转") }.count,
            reversalStopsBeforeDeparture,
            "a burst that already ended with STOP is not active reversal history"
        )
        XCTAssertGreaterThan(
            bluetooth.submittedCorrections.last?.yawTenths ?? 0,
            0,
            "the opposite-side departure should move immediately"
        )
    }

    func testNewVisionFrameCancelsBusyRetryFromSupersededFrame() async throws {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.70, base: base)
        XCTAssertEqual(bluetooth.correctionAttempts.count, 1)

        bluetooth.scriptedCorrectionResults = [.busy]
        sendTracker(person(centerX: 0.70), at: lastValid + 0.02)
        XCTAssertEqual(bluetooth.correctionAttempts.count, 2)

        // This newer observation supersedes the busy command. Regardless of
        // whether filtering classifies the change as a minor or major reversal,
        // the old rightward attempt may never be retried afterward.
        sendTracker(person(centerX: 0.40), at: lastValid + 0.04)
        let attemptsAfterNewFrame = bluetooth.correctionAttempts.count
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(
            bluetooth.correctionAttempts.count,
            attemptsAfterNewFrame,
            "a pending retry from the older frame must be cancelled"
        )
    }

    func testMinorReversalStillStopsPossiblyActiveBurstWhenTargetDisappears() {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.70, base: base)
        XCTAssertEqual(bluetooth.submittedCorrections.count, 1)
        XCTAssertGreaterThan(bluetooth.submittedCorrections[0].yawTenths, 0)

        // With a 0.10 s filter interval this lands just outside the inner dead
        // zone in the opposite direction, producing the one-frame minor hold.
        sendTracker(person(centerX: 0.40), at: lastValid + 0.10)
        XCTAssertEqual(bluetooth.correctionAttempts.count, 1)
        XCTAssertEqual(coordinator.state, .locked)
        XCTAssertFalse(bluetooth.stopReasons.contains { $0.contains("方向反转") })

        send([], at: lastValid + 0.12)
        XCTAssertEqual(coordinator.state, .lossGrace)
        XCTAssertTrue(
            bluetooth.stopReasons.contains { $0.contains("人物首次出框") },
            "consuming reversal history must not hide a possibly active burst"
        )
    }

    func testRejectedFirstLossStopFailsClosedWithoutCoastOrSearch() {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.30, base: base)
        let correctionAttempts = bluetooth.correctionAttempts.count
        bluetooth.scriptedStopResults = [false]

        send([], at: lastValid + 0.08)
        guard case let .motionPaused(reason) = coordinator.state else {
            XCTFail("rejected loss STOP must fail closed, got \(coordinator.state)")
            return
        }
        XCTAssertTrue(reason.contains("未被云台接受"))
        XCTAssertTrue(bluetooth.stopAttempts.contains { $0.contains("人物首次出框") })

        send([], at: lastValid + 0.50)
        XCTAssertEqual(bluetooth.correctionAttempts.count, correctionAttempts)
        XCTAssertTrue(bluetooth.searchStepModes.isEmpty)
        XCTAssertFalse(coordinator.canResumeSearch)
    }

    func testRejectedMajorReversalStopFailsClosedWithoutNewCorrection() {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.70, base: base)
        let correctionAttempts = bluetooth.correctionAttempts.count
        bluetooth.scriptedStopResults = [false]

        sendTracker(person(centerX: 0.05), at: lastValid + 0.10)
        guard case let .motionPaused(reason) = coordinator.state else {
            XCTFail("rejected reversal STOP must fail closed, got \(coordinator.state)")
            return
        }
        XCTAssertTrue(reason.contains("方向反转 STOP"))
        XCTAssertTrue(bluetooth.stopAttempts.contains { $0.contains("方向反转") })

        sendTracker(person(centerX: 0.05), at: lastValid + 0.12)
        XCTAssertEqual(bluetooth.correctionAttempts.count, correctionAttempts)
        XCTAssertTrue(bluetooth.searchStepModes.isEmpty)
    }

    func testRejectedPersonSwitchStopKeepsOldSelectionAndFailsClosed() throws {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.30, base: base)
        let originalID = try XCTUnwrap(coordinator.selectedPersonID)
        send(
            [person(centerX: 0.30), person(centerX: 0.70)],
            at: lastValid + 0.08
        )
        let otherID = try XCTUnwrap(
            coordinator.visiblePeople.first { $0.id != originalID }?.id
        )
        let correctionAttempts = bluetooth.correctionAttempts.count
        bluetooth.scriptedStopResults = [false]

        coordinator.selectPerson(otherID)
        guard case let .motionPaused(reason) = coordinator.state else {
            XCTFail("rejected switch STOP must fail closed, got \(coordinator.state)")
            return
        }
        XCTAssertTrue(reason.contains("切换人物"))
        XCTAssertEqual(coordinator.selectedPersonID, originalID)
        XCTAssertTrue(bluetooth.stopAttempts.contains { $0.contains("切换锁定人物") })

        send([person(centerX: 0.70)], at: lastValid + 0.16)
        XCTAssertEqual(bluetooth.correctionAttempts.count, correctionAttempts)
        XCTAssertTrue(bluetooth.searchStepModes.isEmpty)
    }

    func testFlickerKeepsLockAndFollowing() {
        let base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.30, base: base)
        let originalID = coordinator.selectedPersonID

        send([], at: base + 0.34)
        XCTAssertEqual(coordinator.state, .lossGrace)

        send([person(centerX: 0.31)], at: base + 0.42)
        XCTAssertEqual(coordinator.selectedPersonID, originalID,
                       "a brief detector flicker must not unresolve the lock")
        XCTAssertEqual(bluetooth.submittedCorrections.count, 2)
    }

    func testExitThenSingleCandidateAutoRelocksAfterStabilization() {
        let base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.30, base: base)
        let originalID = coordinator.selectedPersonID

        send([], at: base + 0.34)
        send([], at: base + 0.42)
        send([], at: base + 0.70)
        XCTAssertTrue(
            bluetooth.stopReasons.contains { $0.contains("自动搜索前") },
            "losing the person past the timeout must start a search episode"
        )

        send([person(centerX: 0.70)], at: base + 0.80)
        XCTAssertEqual(coordinator.state, .reacquiring,
                       "a single candidate during search must stop and stabilize")

        let settleBase = ProcessInfo.processInfo.systemUptime + 0.35
        for index in 0..<6 {
            send([person(centerX: 0.70)], at: settleBase + Double(index) * 0.09)
        }
        XCTAssertNotNil(coordinator.selectedPersonID)
        XCTAssertNotEqual(coordinator.selectedPersonID, originalID,
                          "the lock must transfer to the stabilized candidate")
        XCTAssertGreaterThan(
            bluetooth.submittedCorrections.count, 1,
            "following must resume automatically after the transfer"
        )
    }

    func testMultipleCandidatesDuringSearchWaitForManualPick() {
        let base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.30, base: base)

        send([], at: base + 0.34)
        send([], at: base + 0.42)
        send([], at: base + 0.70)

        send([person(centerX: 0.30), person(centerX: 0.70)], at: base + 0.80)
        guard case let .searchPaused(reason) = coordinator.state else {
            XCTFail("multiple candidates must pause for a manual pick, got \(coordinator.state)")
            return
        }
        XCTAssertTrue(reason.contains("点选"))
        XCTAssertNil(coordinator.selectedPersonDetection,
                     "no candidate may inherit the lock automatically")
        XCTAssertEqual(coordinator.visiblePeople.count, 2)
    }

    func testTrackerSamplesSteerOnlyWithinBridgeWindow() {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.30, base: base)
        XCTAssertEqual(bluetooth.submittedCorrections.count, 1)

        sendTracker(person(centerX: 0.25), at: lastValid + 0.05)
        XCTAssertEqual(
            bluetooth.submittedCorrections.count, 2,
            "a tracker sample inside the bridge window must drive a correction"
        )

        sendTracker(person(centerX: 0.25), at: lastValid + 0.30)
        XCTAssertEqual(
            bluetooth.submittedCorrections.count, 2,
            "a tracker sample past the detector bridge window must be ignored"
        )
    }

    func testContinuouslyDelayedFramesPauseAutomaticScan() async throws {
        let base = ProcessInfo.processInfo.systemUptime
        acquireLock(centerX: 0.30, base: base)

        send([], at: base + 0.34)
        send([], at: base + 0.42)
        send([], at: base + 0.70)

        // Keep the detector callback alive, but feed frames older than the fast
        // profile's steering budget. They must not renew scan authorization.
        for _ in 0..<9 {
            try await Task.sleep(nanoseconds: 100_000_000)
            send(
                [],
                at: ProcessInfo.processInfo.systemUptime
                    - PersonTrackingSpeedMode.fast.maximumSampleAge
                    - 0.05
            )
        }

        guard case let .searchPaused(reason) = coordinator.state else {
            XCTFail("delayed vision must safely pause scanning, got \(coordinator.state)")
            return
        }
        XCTAssertTrue(
            reason.contains("延迟过高") || reason.contains("授权不足"),
            "the scan must pause before a motion could outlive fresh vision"
        )
        XCTAssertTrue(
            bluetooth.searchStepModes.isEmpty,
            "no scan step may start if its full duration exceeds vision authorization"
        )
        XCTAssertTrue(coordinator.canResumeSearch)
    }

    func testTopExitStartsUpwardPitchCoast() async throws {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.50, centerY: 0.22, base: base)
        send([person(centerX: 0.50, centerY: 0.16)], at: lastValid + 0.06)
        send([person(centerX: 0.50, centerY: 0.10)], at: lastValid + 0.12)
        send([], at: lastValid + 0.18)
        send([], at: lastValid + 0.24)
        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(bluetooth.searchStepModes.first, .coast)
        XCTAssertEqual(bluetooth.searchDirections.first, .up)
        XCTAssertEqual(bluetooth.searchCorrections.first?.yawTenths, 0)
        XCTAssertLessThan(bluetooth.searchCorrections.first?.pitchTenths ?? 0, 0)
    }

    func testAutomaticScanCyclesAcrossYawAndPitchAxes() async throws {
        let base = ProcessInfo.processInfo.systemUptime
        let lastValid = acquireLock(centerX: 0.50, centerY: 0.42, base: base)
        bluetooth.scriptedSearchResults = Array(
            repeating: PersonSearchCommandResult.softBoundaryReached,
            count: 4
        )
        send([], at: lastValid + 0.10)
        send([], at: lastValid + 0.50)

        for _ in 0..<18 {
            try await Task.sleep(nanoseconds: 100_000_000)
            send([], at: ProcessInfo.processInfo.systemUptime)
        }

        XCTAssertGreaterThanOrEqual(bluetooth.searchDirections.count, 4)
        XCTAssertEqual(
            Array(bluetooth.searchDirections.prefix(4)),
            [.right, .down, .left, .up],
            "an unattended scan must not remain on the Yaw axis"
        )
    }
}
