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
    private let activeSubject = CurrentValueSubject<Bool, Never>(false)

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
    private(set) var searchStepModes: [PersonSearchMotionMode] = []
    private(set) var stopReasons: [String] = []
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
        submittedCorrections.append(correction)
        return .submitted(correction)
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
        return .submitted(
            yawTenths: direction.rawValue * PersonSearchPolicy.scanStepTenths,
            reachesSoftBoundary: false
        )
    }

    func pausePersonTrackingWithStop(
        session: UUID,
        reason: String,
        cooldownOverride: TimeInterval?
    ) -> Bool {
        guard session == activeSession else { return false }
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
        base: TimeInterval
    ) -> TimeInterval {
        coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.enabled, "tracking must enable with ready mocks")
        send([person(centerX: centerX)], at: base)
        send([person(centerX: centerX)], at: base + 0.12)
        let lastValid = base + 0.26
        send([person(centerX: centerX)], at: lastValid)
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
}
