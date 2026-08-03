import XCTest
@testable import OM3Lab

final class GimbalRangeCalibrationSafetyPolicyTests: XCTestCase {
    func testCalibratedEnvelopeCeilingFailsClosedForEveryDirection() {
        let maximum = OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees
        let accepted = GimbalTrackingEnvelope(
            leftYawTenths: maximum.left * 10,
            rightYawTenths: maximum.right * 10,
            upPitchTenths: maximum.up * 10,
            downPitchTenths: maximum.down * 10
        )
        XCTAssertTrue(
            OM3HardwareMotionLimits.isValidCalibratedTrackingEnvelope(accepted)
        )

        let directionalOverruns = [
            GimbalTrackingEnvelope(
                leftYawTenths: maximum.left * 10 + 1,
                rightYawTenths: maximum.right * 10,
                upPitchTenths: maximum.up * 10,
                downPitchTenths: maximum.down * 10
            ),
            GimbalTrackingEnvelope(
                leftYawTenths: maximum.left * 10,
                rightYawTenths: maximum.right * 10 + 1,
                upPitchTenths: maximum.up * 10,
                downPitchTenths: maximum.down * 10
            ),
            GimbalTrackingEnvelope(
                leftYawTenths: maximum.left * 10,
                rightYawTenths: maximum.right * 10,
                upPitchTenths: maximum.up * 10 + 1,
                downPitchTenths: maximum.down * 10
            ),
            GimbalTrackingEnvelope(
                leftYawTenths: maximum.left * 10,
                rightYawTenths: maximum.right * 10,
                upPitchTenths: maximum.up * 10,
                downPitchTenths: maximum.down * 10 + 1
            ),
        ]
        for overrun in directionalOverruns {
            XCTAssertFalse(
                OM3HardwareMotionLimits.isValidCalibratedTrackingEnvelope(overrun)
            )
        }
    }

    func testOnlyPreCommandDisturbanceCanRetry() {
        XCTAssertEqual(
            disposition(
                commandWasSent: false,
                primary: .moved,
                orthogonal: .noResponse
            ),
            .retryBeforeCommand
        )
        XCTAssertEqual(
            disposition(
                commandWasSent: false,
                primary: .inconclusive("lighting changed"),
                orthogonal: .noResponse
            ),
            .retryBeforeCommand
        )
        XCTAssertEqual(
            disposition(
                commandWasSent: false,
                primary: .noResponse,
                orthogonal: .noResponse
            ),
            .proceedToCommand
        )
    }

    func testCleanPostCommandMoveAwaitsNormalOperatorConfirmation() {
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .moved,
                orthogonal: .noResponse
            ),
            .awaitMovedStepConfirmation
        )
    }

    func testPostCommandNoResponseRequiresPhysicalNoMovementConfirmation() {
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .noResponse,
                orthogonal: .noResponse
            ),
            .awaitPhysicalNoMovementConfirmation
        )

        XCTAssertNotEqual(
            disposition(
                commandWasSent: true,
                primary: .noResponse,
                orthogonal: .noResponse
            ),
            .retryBeforeCommand
        )
    }

    func testNoResponseWithOrthogonalUncertaintyFailsClosed() {
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .noResponse,
                orthogonal: .moved
            ),
            .abortForUnknownPose
        )
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .noResponse,
                orthogonal: .inconclusive("low texture")
            ),
            .abortForUnknownPose
        )
    }

    func testPostCommandInconclusiveFailsClosed() {
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .inconclusive("exposure changed"),
                orthogonal: .noResponse
            ),
            .abortForUnknownPose
        )
    }

    func testOrthogonalMovementFailsClosed() {
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .moved,
                orthogonal: .moved
            ),
            .abortForUnknownPose
        )
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .moved,
                orthogonal: .inconclusive("camera shake")
            ),
            .abortForUnknownPose
        )
    }

    func testReverseAndPartialMovesFailClosed() {
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .moved,
                orthogonal: .noResponse,
                reversesAcceptedDirection: true
            ),
            .abortForUnknownPose
        )
        XCTAssertEqual(
            disposition(
                commandWasSent: true,
                primary: .moved,
                orthogonal: .noResponse,
                shiftBelowExpected: true
            ),
            .abortForUnknownPose
        )
    }

    func testNoPostCommandUncertaintyCanRetry() {
        let unsafeVerdicts: [(GimbalMotionVerdict, GimbalMotionVerdict)] = [
            (.inconclusive("unknown"), .noResponse),
            (.noResponse, .moved),
            (.noResponse, .inconclusive("unknown")),
            (.moved, .moved),
            (.moved, .inconclusive("unknown")),
        ]

        for (primary, orthogonal) in unsafeVerdicts {
            XCTAssertNotEqual(
                disposition(
                    commandWasSent: true,
                    primary: primary,
                    orthogonal: orthogonal
                ),
                .retryBeforeCommand
            )
        }
    }

    func testUnknownPosePausesForManualRecoveryWhenStopAndSessionsAreValid() {
        XCTAssertEqual(
            GimbalRangeCalibrationRecoveryPolicy.action(
                stopAccepted: true,
                sessionsAreValid: true
            ),
            .pauseForManualRecovery
        )
    }

    func testUnknownPoseTerminatesWhenStopIsRejectedOrSessionIsInvalid() {
        XCTAssertEqual(
            GimbalRangeCalibrationRecoveryPolicy.action(
                stopAccepted: false,
                sessionsAreValid: true
            ),
            .terminate
        )
        XCTAssertEqual(
            GimbalRangeCalibrationRecoveryPolicy.action(
                stopAccepted: true,
                sessionsAreValid: false
            ),
            .terminate
        )
    }

    func testAutomationAcceptsOnlyCleanMovedStepWithoutAnotherClick() {
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .awaitMovedStepConfirmation,
                transientVisualUncertainty: false,
                observationAttempt: 1
            ),
            .acceptMovedStep
        )
    }

    func testAutomationKeepsPhysicalNoMovementConfirmation() {
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .awaitPhysicalNoMovementConfirmation,
                transientVisualUncertainty: false,
                observationAttempt: 1
            ),
            .requestNoMovementConfirmation
        )
    }

    func testTransientPostCommandUncertaintyOnlyResamplesWithinBudget() {
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .abortForUnknownPose,
                transientVisualUncertainty: true,
                observationAttempt: 1
            ),
            .resampleObservation
        )
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .abortForUnknownPose,
                transientVisualUncertainty: true,
                observationAttempt: 3
            ),
            .pauseForManualRecovery
        )
    }

    func testGeometricConflictNeverGetsAutomaticMotionRetry() {
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .abortForUnknownPose,
                transientVisualUncertainty: false,
                observationAttempt: 1
            ),
            .pauseForManualRecovery
        )
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .retryBeforeCommand,
                transientVisualUncertainty: true,
                observationAttempt: 1
            ),
            .pauseForManualRecovery
        )
    }

    func testTransientClassifierRejectsGeometricConflicts() {
        XCTAssertTrue(
            GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
                primaryVerdict: .inconclusive("exposure"),
                orthogonalVerdict: .noResponse,
                reversesAcceptedDirection: false,
                shiftBelowExpected: false
            )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
                primaryVerdict: .inconclusive("unknown"),
                orthogonalVerdict: .moved,
                reversesAcceptedDirection: false,
                shiftBelowExpected: false
            )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
                primaryVerdict: .moved,
                orthogonalVerdict: .noResponse,
                reversesAcceptedDirection: true,
                shiftBelowExpected: false
            )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
                primaryVerdict: .moved,
                orthogonalVerdict: .noResponse,
                reversesAcceptedDirection: false,
                shiftBelowExpected: true
            )
        )
    }

    func testAutomaticEvidenceRequiresQualityAndConsistentSecondObservation() {
        let moved = estimate(
            shift: 12,
            zeroError: 0.20,
            bestError: 0.03,
            confidence: 0.80,
            verdict: .moved
        )
        let stationary = estimate(
            shift: 0,
            zeroError: 0.01,
            bestError: 0.01,
            confidence: 0.85,
            verdict: .noResponse
        )
        XCTAssertTrue(
            GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
                primary: moved,
                orthogonal: stationary,
                axis: .horizontal
            )
        )
        XCTAssertTrue(
            GimbalRangeCalibrationAutomaticEvidencePolicy
                .movedObservationsAreConsistent(
                    moved,
                    estimate(
                        shift: 13,
                        zeroError: 0.19,
                        bestError: 0.03,
                        confidence: 0.82,
                        verdict: .moved
                    )
                )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomaticEvidencePolicy
                .movedObservationsAreConsistent(
                    moved,
                    estimate(
                        shift: -12,
                        zeroError: 0.19,
                        bestError: 0.03,
                        confidence: 0.82,
                        verdict: .moved
                    )
                )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
                primary: estimate(
                    shift: 31,
                    zeroError: 0.20,
                    bestError: 0.03,
                    confidence: 0.80,
                    verdict: .moved
                ),
                orthogonal: stationary,
                axis: .horizontal
            )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
                primary: estimate(
                    shift: 17,
                    zeroError: 0.20,
                    bestError: 0.03,
                    confidence: 0.80,
                    verdict: .moved
                ),
                orthogonal: stationary,
                axis: .vertical
            )
        )
        XCTAssertFalse(
            GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableStationary(
                estimate(
                    shift: 0,
                    zeroError: 0.01,
                    bestError: 0.01,
                    confidence: 0.40,
                    verdict: .noResponse
                )
            )
        )
    }

    func testObservationAttemptMustBeInsideBudget() {
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .abortForUnknownPose,
                transientVisualUncertainty: true,
                observationAttempt: 0
            ),
            .pauseForManualRecovery
        )
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .abortForUnknownPose,
                transientVisualUncertainty: true,
                observationAttempt: 2
            ),
            .resampleObservation
        )
        XCTAssertEqual(
            GimbalRangeCalibrationAutomationPolicy.postCommandAction(
                disposition: .abortForUnknownPose,
                transientVisualUncertainty: true,
                observationAttempt: 4
            ),
            .pauseForManualRecovery
        )
    }

    private func estimate(
        shift: Int,
        zeroError: Double,
        bestError: Double,
        confidence: Double,
        verdict: GimbalMotionVerdict
    ) -> GimbalMotionEstimate {
        GimbalMotionEstimate(
            axisShift: shift,
            zeroError: zeroError,
            bestError: bestError,
            confidence: confidence,
            verdict: verdict
        )
    }

    private func disposition(
        commandWasSent: Bool,
        primary: GimbalMotionVerdict,
        orthogonal: GimbalMotionVerdict,
        reversesAcceptedDirection: Bool = false,
        shiftBelowExpected: Bool = false
    ) -> GimbalCalibrationProbeDisposition {
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: commandWasSent,
            primaryVerdict: primary,
            orthogonalVerdict: orthogonal,
            reversesAcceptedDirection: reversesAcceptedDirection,
            shiftBelowExpected: shiftBelowExpected
        )
    }
}
