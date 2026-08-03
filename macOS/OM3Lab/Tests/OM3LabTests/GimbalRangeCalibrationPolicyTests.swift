import XCTest
@testable import OM3Lab

final class GimbalRangeCalibrationPolicyTests: XCTestCase {
    func testPublishedHardwareCeilingsRemainSanityValues() {
        XCTAssertEqual(OM3HardwareMotionLimits.structuralCeilingDegrees.left, 162.5)
        XCTAssertEqual(OM3HardwareMotionLimits.structuralCeilingDegrees.right, 170.3)
        XCTAssertEqual(OM3HardwareMotionLimits.structuralCeilingDegrees.up, 104.5)
        XCTAssertEqual(OM3HardwareMotionLimits.structuralCeilingDegrees.down, 235.7)
        XCTAssertEqual(
            OM3HardwareMotionLimits.maximumControllableSpeedDegreesPerSecond,
            120.0
        )
    }

    func testProbeParametersAlignDownAndKeepEndpointReserve() {
        XCTAssertEqual(GimbalRangeCalibrationPolicy.yawStepDegrees, 5)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.pitchStepDegrees, 2)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.yawSafetyMarginDegrees, 10)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.pitchSafetyMarginDegrees, 6)

        let expectedCaps: [OM3HardwareMotionLimits.Direction: Int] = [
            .left: 150,
            .right: 160,
            .up: 98,
            .down: 228,
        ]
        for direction in OM3HardwareMotionLimits.Direction.allCases {
            guard let expectedCap = expectedCaps[direction] else {
                XCTFail("Missing expected probe cap for \(direction)")
                continue
            }
            let cap = OM3HardwareMotionLimits.probeCapDegrees(for: direction)
            let step = OM3HardwareMotionLimits.probeStepDegrees(for: direction)
            let ceiling = OM3HardwareMotionLimits.structuralCeilingDegrees
                .value(for: direction)
            let reserve = OM3HardwareMotionLimits.mechanicalEndpointReserveDegrees
                .value(for: direction)

            XCTAssertEqual(cap, expectedCap)
            XCTAssertEqual(cap % step, 0)
            XCTAssertLessThanOrEqual(Double(cap), ceiling - reserve)
            XCTAssertGreaterThan(Double(cap + step), ceiling - reserve)
        }

        XCTAssertEqual(GimbalCalibrationDirection.left.probeLimitDegrees, 150)
        XCTAssertEqual(GimbalCalibrationDirection.right.probeLimitDegrees, 160)
        XCTAssertEqual(GimbalCalibrationDirection.up.probeLimitDegrees, 98)
        XCTAssertEqual(GimbalCalibrationDirection.down.probeLimitDegrees, 228)
    }

    func testMaximumCalibratedEnvelopeSubtractsASecondTrackingMargin() {
        XCTAssertEqual(
            OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees,
            OM3HardwareMotionLimits.DirectionalWholeDegrees(
                left: 140,
                right: 150,
                up: 92,
                down: 222
            )
        )
    }

    func testCenteredFallbackIsLargerButWellInsideStructuralCeilings() {
        let fallback = OM3HardwareMotionLimits.centeredFallbackEnvelopeDegrees
        XCTAssertEqual(
            fallback,
            OM3HardwareMotionLimits.DirectionalWholeDegrees(
                left: 120,
                right: 120,
                up: 60,
                down: 60
            )
        )
        XCTAssertEqual(
            GimbalTrackingEnvelope.conservativeDefault,
            OM3HardwareMotionLimits.centeredFallbackTrackingEnvelope
        )
        XCTAssertTrue(
            OM3HardwareMotionLimits.isWithinStructuralSanityCeiling(
                yawTenths: -fallback.left * 10,
                pitchTenths: -fallback.up * 10
            )
        )
        XCTAssertTrue(
            OM3HardwareMotionLimits.isWithinStructuralSanityCeiling(
                yawTenths: fallback.right * 10,
                pitchTenths: fallback.down * 10
            )
        )
    }

    func testOfficialSpeedCapScalesWithDeclaredCommandDuration() {
        XCTAssertEqual(
            OM3HardwareMotionLimits.maximumCombinedCommandTenths(durationTenths: 1),
            120
        )
        XCTAssertEqual(
            OM3HardwareMotionLimits.maximumCombinedCommandTenths(durationTenths: 3),
            360
        )
    }

    func testUsableExtentSubtractsAxisSpecificMargin() {
        XCTAssertEqual(
            GimbalRangeCalibrationPolicy.usableExtent(
                verifiedExtentDegrees: 85,
                direction: .left
            ),
            75
        )
        XCTAssertEqual(
            GimbalRangeCalibrationPolicy.usableExtent(
                verifiedExtentDegrees: 28,
                direction: .up
            ),
            22
        )
        XCTAssertEqual(
            GimbalRangeCalibrationPolicy.usableExtent(
                verifiedExtentDegrees: 4,
                direction: .down
            ),
            0
        )
    }

    func testResultBuildsAsymmetricTrackingEnvelope() throws {
        let result = GimbalRangeCalibrationResult(
            measurements: [
                measurement(.left, usable: 70),
                measurement(.right, usable: 85),
                measurement(.up, usable: 20),
                measurement(.down, usable: 28),
            ],
            completedAt: Date(timeIntervalSince1970: 0)
        )
        let envelope = try XCTUnwrap(result.envelope)

        XCTAssertEqual(envelope.leftYawTenths, 700)
        XCTAssertEqual(envelope.rightYawTenths, 850)
        XCTAssertEqual(envelope.upPitchTenths, 200)
        XCTAssertEqual(envelope.downPitchTenths, 280)
        XCTAssertTrue(envelope.contains(yawTenths: -350, pitchTenths: -100))
        XCTAssertFalse(envelope.contains(yawTenths: 425, pitchTenths: 141))
    }

    func testIncompleteResultDoesNotCreateEnvelope() {
        let result = GimbalRangeCalibrationResult(
            measurements: [measurement(.left, usable: 60)],
            completedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(result.envelope)
    }

    private func measurement(
        _ direction: GimbalCalibrationDirection,
        usable: Int
    ) -> GimbalRangeMeasurement {
        GimbalRangeMeasurement(
            direction: direction,
            verifiedExtentDegrees: usable + direction.safetyMarginDegrees,
            safetyMarginDegrees: direction.safetyMarginDegrees,
            usableExtentDegrees: usable,
            kind: .operatorLimit
        )
    }
}
