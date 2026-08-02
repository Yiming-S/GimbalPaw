import Combine
import Foundation

/// The exact bluetooth surface the person-tracking coordinator depends on.
/// The seam exists so the coordinator's phase machine can be exercised in
/// tests with scripted command results; `OM3BluetoothController` is the only
/// production conformance.
@MainActor
protocol PersonTrackingBluetoothControlling: AnyObject {
    var state: OM3ConnectionState { get }
    var nudgeAvailable: Bool { get }
    var motionSafetyArmed: Bool { get }
    var trackingOriginConfirmed: Bool { get }
    var personTrackingActive: Bool { get }

    var statePublisher: AnyPublisher<OM3ConnectionState, Never> { get }
    var nudgeAvailablePublisher: AnyPublisher<Bool, Never> { get }
    var trackingOriginConfirmedPublisher: AnyPublisher<Bool, Never> { get }
    var personTrackingActivePublisher: AnyPublisher<Bool, Never> { get }

    func beginPersonTracking(speedMode: PersonTrackingSpeedMode) -> UUID?
    func sendPersonTrackingCorrection(
        _ correction: PersonTrackingCorrection,
        observedAtUptime: TimeInterval,
        session: UUID
    ) -> PersonTrackingCommandResult
    func sendPersonSearchStep(
        direction: PersonSearchDirection,
        mode: PersonSearchMotionMode,
        requestedAtUptime: TimeInterval,
        mustFinishByUptime: TimeInterval,
        session: UUID
    ) -> PersonSearchCommandResult
    @discardableResult
    func pausePersonTrackingWithStop(
        session: UUID,
        reason: String,
        cooldownOverride: TimeInterval?
    ) -> Bool
    func endPersonTracking(session: UUID, reason: String, sendStop: Bool)
    func stopMotion(reason: String)
}

/// The camera surface the person-tracking coordinator depends on.
@MainActor
protocol PersonTrackingCameraControlling: AnyObject {
    var status: CameraStatus { get }
    var personTrackingEnabled: Bool { get }
    var motionCalibrationEnabled: Bool { get }
    var statusPublisher: AnyPublisher<CameraStatus, Never> { get }
    var onPersonSample: ((PersonVisionSample) -> Void)? { get set }

    func setPersonTrackingEnabled(_ enabled: Bool)
    func setPersonTrackingSeed(_ detection: PersonDetection?)
    func isPersonTrackingSessionValid(_ sessionID: UUID) -> Bool
    func withValidPersonTrackingSession<Result>(
        _ sessionID: UUID,
        operation: () -> Result
    ) -> Result?
}

extension PersonTrackingBluetoothControlling {
    @discardableResult
    func pausePersonTrackingWithStop(session: UUID, reason: String) -> Bool {
        pausePersonTrackingWithStop(
            session: session,
            reason: reason,
            cooldownOverride: nil
        )
    }
}

extension OM3BluetoothController: PersonTrackingBluetoothControlling {
    var statePublisher: AnyPublisher<OM3ConnectionState, Never> {
        $state.eraseToAnyPublisher()
    }

    var nudgeAvailablePublisher: AnyPublisher<Bool, Never> {
        $nudgeAvailable.eraseToAnyPublisher()
    }

    var trackingOriginConfirmedPublisher: AnyPublisher<Bool, Never> {
        $trackingOriginConfirmed.eraseToAnyPublisher()
    }

    var personTrackingActivePublisher: AnyPublisher<Bool, Never> {
        $personTrackingActive.eraseToAnyPublisher()
    }
}

extension CameraController: PersonTrackingCameraControlling {
    var statusPublisher: AnyPublisher<CameraStatus, Never> {
        $status.eraseToAnyPublisher()
    }
}
