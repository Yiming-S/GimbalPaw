import XCTest
@testable import OM3Lab

final class GimbalRangeCalibrationPolicyTests: XCTestCase {
    func testProbeParametersRetainExplicitMargins() {
        XCTAssertEqual(GimbalRangeCalibrationPolicy.yawStepDegrees, 5)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.pitchStepDegrees, 2)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.yawProbeLimitDegrees, 100)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.pitchProbeLimitDegrees, 36)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.yawSafetyMarginDegrees, 10)
        XCTAssertEqual(GimbalRangeCalibrationPolicy.pitchSafetyMarginDegrees, 6)
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
