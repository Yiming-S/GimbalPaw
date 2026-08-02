import XCTest
@testable import OM3Lab

final class PersonTrackingPolicyTests: XCTestCase {
    func testSearchDirectionRawValuesOppositesAndTitles() {
        XCTAssertEqual(PersonSearchDirection.left.rawValue, -1)
        XCTAssertEqual(PersonSearchDirection.right.rawValue, 1)
        XCTAssertEqual(PersonSearchDirection.left.opposite, .right)
        XCTAssertEqual(PersonSearchDirection.right.opposite, .left)
        XCTAssertEqual(PersonSearchDirection.left.title, "向左")
        XCTAssertEqual(PersonSearchDirection.right.title, "向右")
        XCTAssertEqual(PersonSearchMotionMode.allCases, [.coast, .scan])
    }

    func testSearchPolicyUsesBoundedCoastAndScanParameters() {
        XCTAssertEqual(PersonSearchPolicy.coastStepTenths, 10)
        XCTAssertEqual(PersonSearchPolicy.coastDurationTenths, 1)
        XCTAssertEqual(PersonSearchPolicy.coastCooldown, 0.23, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.lossGraceStopCooldown, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumCoastTravelTenths, 20)

        XCTAssertEqual(PersonSearchPolicy.scanSoftYawLimitTenths, 200)
        XCTAssertEqual(PersonSearchPolicy.scanStepTenths, 20)
        XCTAssertEqual(PersonSearchPolicy.scanDurationTenths, 3)
        XCTAssertEqual(PersonSearchPolicy.scanCooldown, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.scanSettleDuration, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumScanEpisodeDuration, 12.0, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumScanEpisodeTravelTenths, 600)
        XCTAssertEqual(PersonSearchPolicy.maximumScanBoundaryTouches, 2)
        XCTAssertEqual(PersonSearchPolicy.commandMaximumAge, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.commandRetryInterval, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumVisionSilence, 0.50, accuracy: 0.000_001)
    }

    func testCoastRequiresTrustedOutwardEdgeTrajectory() {
        XCTAssertEqual(
            PersonSearchPolicy.coastDirection(
                recentCenterXs: [0.78, 0.83, 0.89],
                lastConfidence: 0.8,
                lastYawTenths: 10
            ),
            .right
        )
        XCTAssertNil(
            PersonSearchPolicy.coastDirection(
                recentCenterXs: [0.78, 0.83, 0.89],
                lastConfidence: 0.8,
                lastYawTenths: -10
            )
        )
        XCTAssertNil(
            PersonSearchPolicy.coastDirection(
                recentCenterXs: [0.80, 0.86, 0.84, 0.89],
                lastConfidence: 0.8,
                lastYawTenths: 10
            )
        )
    }

    func testScanStepMovesTowardSelectedBoundary() {
        XCTAssertEqual(
            PersonSearchPolicy.scanStep(currentYawTenths: 0, direction: .left),
            PersonSearchStep(yawTenths: -20, reachesSoftBoundary: false)
        )
        XCTAssertEqual(
            PersonSearchPolicy.scanStep(currentYawTenths: 0, direction: .right),
            PersonSearchStep(yawTenths: 20, reachesSoftBoundary: false)
        )
    }

    func testScanStepClampsFinalCommandAndReportsBoundary() {
        XCTAssertEqual(
            PersonSearchPolicy.scanStep(currentYawTenths: -190, direction: .left),
            PersonSearchStep(yawTenths: -10, reachesSoftBoundary: true)
        )
        XCTAssertEqual(
            PersonSearchPolicy.scanStep(currentYawTenths: 195, direction: .right),
            PersonSearchStep(yawTenths: 5, reachesSoftBoundary: true)
        )
        XCTAssertNil(PersonSearchPolicy.scanStep(currentYawTenths: -200, direction: .left))
        XCTAssertNil(PersonSearchPolicy.scanStep(currentYawTenths: 200, direction: .right))
    }

    func testCoastStepAlsoStopsAtSoftBoundary() {
        XCTAssertEqual(
            PersonSearchPolicy.coastStep(currentYawTenths: 195, direction: .right),
            PersonSearchStep(yawTenths: 5, reachesSoftBoundary: true)
        )
        XCTAssertNil(PersonSearchPolicy.coastStep(currentYawTenths: 200, direction: .right))
    }

    func testSearchPacketDeadlineLeavesTimeForWholeMotion() {
        XCTAssertEqual(
            PersonSearchPolicy.latestFirstWriteUptime(
                requestedAtUptime: 10.0,
                mustFinishByUptime: 10.4,
                durationTenths: 1
            ),
            10.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PersonSearchPolicy.latestFirstWriteUptime(
                requestedAtUptime: 10.2,
                mustFinishByUptime: 10.4,
                durationTenths: 1
            ),
            10.3,
            accuracy: 0.000_001
        )
    }

    func testScanStepOutsideSoftRangeOnlyAllowsMotionTowardOrigin() {
        XCTAssertEqual(
            PersonSearchPolicy.scanStep(currentYawTenths: 250, direction: .left),
            PersonSearchStep(yawTenths: -20, reachesSoftBoundary: false)
        )
        XCTAssertNil(PersonSearchPolicy.scanStep(currentYawTenths: 250, direction: .right))
        XCTAssertEqual(
            PersonSearchPolicy.scanStep(currentYawTenths: -250, direction: .right),
            PersonSearchStep(yawTenths: 20, reachesSoftBoundary: false)
        )
        XCTAssertNil(PersonSearchPolicy.scanStep(currentYawTenths: -250, direction: .left))
    }

    func testCenteredPersonNeedsNoCorrection() {
        XCTAssertNil(PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.5)))
    }

    func testHorizontalDirectionAndClamp() {
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.80, centerY: 0.5)),
            PersonTrackingCorrection(yawTenths: 35, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.05, centerY: 0.5)),
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0)
        )
    }

    func testVerticalDirectionMatchesCalibratedOM3Mapping() {
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.20)),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.90)),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: 20)
        )
    }

    func testDiagonalCorrectionKeepsCombinedStepWithinFastProfileLimit() throws {
        let correction = try XCTUnwrap(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.95, centerY: 0.76))
        )
        let magnitude = hypot(
            Double(correction.yawTenths),
            Double(correction.pitchTenths)
        )
        XCTAssertLessThanOrEqual(magnitude, 65.1)
        XCTAssertNotEqual(correction.pitchTenths, 0)
    }

    func testRevokedVisionLeaseRejectsOperation() {
        let lease = PersonVisionSessionLease()
        XCTAssertEqual(lease.withValidity { 7 }, 7)
        lease.revoke()
        XCTAssertNil(lease.withValidity { 9 })
    }

    func testTrackingFrameUsesShortRelativeMove() throws {
        let frame = try OM3Protocol.relativeMove(
            yawTenths: 5,
            pitchTenths: -5,
            durationTenths: PersonTrackingSpeedMode.fast.commandDurationTenths
        )

        XCTAssertEqual(frame.count, 21)
        XCTAssertEqual(frame[10], 0x14)
        XCTAssertEqual(frame[11], 0x05)
        XCTAssertEqual(frame[12], 0x00)
        XCTAssertEqual(frame[15], 0xfb)
        XCTAssertEqual(frame[16], 0xff)
        XCTAssertEqual(frame[17], 0x04)
        XCTAssertEqual(frame[18], 0x01)
    }

    func testSpeedModesUseIncreasingBoundedProfiles() {
        let farLeft = detection(centerX: 0.05, centerY: 0.5)
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: farLeft, speedMode: .smooth),
            PersonTrackingCorrection(yawTenths: -15, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: farLeft, speedMode: .standard),
            PersonTrackingCorrection(yawTenths: -20, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: farLeft, speedMode: .fast),
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(
                for: detection(centerX: 0.65, centerY: 0.5),
                speedMode: .fast
            ),
            PersonTrackingCorrection(yawTenths: 15, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(
                for: detection(centerX: 0.78, centerY: 0.5),
                speedMode: .fast
            ),
            PersonTrackingCorrection(yawTenths: 35, pitchTenths: 0)
        )

        for mode in PersonTrackingSpeedMode.allCases {
            let duration = Double(mode.commandDurationTenths) / 10.0
            if mode == .fast {
                XCTAssertEqual(mode.commandCooldown, duration, accuracy: 0.000_001)
            } else {
                XCTAssertGreaterThanOrEqual(mode.commandCooldown, duration + 0.10)
            }
            XCTAssertLessThanOrEqual(mode.pitchMaximumTenths, 20)
            XCTAssertLessThanOrEqual(mode.combinedMaximumTenths, 65)
        }

        let previousContinuousMaximumRate = 45.0 / 0.21
        let upgradedMaximumRate = Double(PersonTrackingSpeedMode.fast.yawMaximumTenths)
            / PersonTrackingSpeedMode.fast.commandCooldown
        XCTAssertGreaterThanOrEqual(
            upgradedMaximumRate,
            previousContinuousMaximumRate * 3.0
        )
        XCTAssertLessThanOrEqual(
            PersonTrackingSpeedMode.fast.maximumSampleAge,
            PersonTrackingSpeedMode.fast.commandCooldown
        )
        XCTAssertGreaterThanOrEqual(PersonTrackingPolicy.minimumStopCooldown, 0.12)
    }

    func testTrackingEnvelopeUsesAsymmetricDirectionalLimitsAndDiamond() {
        let envelope = GimbalTrackingEnvelope(
            leftYawTenths: 300,
            rightYawTenths: 600,
            upPitchTenths: 100,
            downPitchTenths: 200
        )

        XCTAssertEqual(envelope.limitTenths(for: .left), 300)
        XCTAssertEqual(envelope.limitTenths(for: .right), 600)
        XCTAssertEqual(envelope.limitTenths(for: .up), 100)
        XCTAssertEqual(envelope.limitTenths(for: .down), 200)
        XCTAssertEqual(envelope.yawLimitTenths(for: -1), 300)
        XCTAssertEqual(envelope.yawLimitTenths(for: 1), 600)
        XCTAssertEqual(envelope.pitchLimitTenths(for: -1), 100)
        XCTAssertEqual(envelope.pitchLimitTenths(for: 1), 200)

        XCTAssertEqual(
            envelope.normalizedUsage(yawTenths: -150, pitchTenths: -50),
            1.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            envelope.normalizedUsage(yawTenths: 300, pitchTenths: 100),
            1.0,
            accuracy: 0.000_001
        )
        XCTAssertTrue(envelope.contains(yawTenths: -150, pitchTenths: -50))
        XCTAssertTrue(envelope.contains(yawTenths: 300, pitchTenths: 100))
        XCTAssertFalse(envelope.contains(yawTenths: -151, pitchTenths: -50))
        XCTAssertFalse(envelope.contains(yawTenths: 301, pitchTenths: 100))
    }

    func testAsymmetricCardinalStepsClampAtTheirOwnBoundaries() {
        let envelope = GimbalTrackingEnvelope(
            leftYawTenths: 300,
            rightYawTenths: 600,
            upPitchTenths: 100,
            downPitchTenths: 200
        )

        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -30, pitchTenths: 0),
                currentYawTenths: -290,
                currentPitchTenths: 0,
                envelope: envelope
            ),
            PersonTrackingCorrection(yawTenths: -10, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 30, pitchTenths: 0),
                currentYawTenths: 590,
                currentPitchTenths: 0,
                envelope: envelope
            ),
            PersonTrackingCorrection(yawTenths: 10, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 0, pitchTenths: -30),
                currentYawTenths: 0,
                currentPitchTenths: -90,
                envelope: envelope
            ),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: -10)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 0, pitchTenths: 30),
                currentYawTenths: 0,
                currentPitchTenths: 190,
                envelope: envelope
            ),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: 10)
        )
    }

    func testDiagonalStepClampsAlongLineToConservativeDiamond() {
        let envelope = GimbalTrackingEnvelope(
            leftYawTenths: 300,
            rightYawTenths: 600,
            upPitchTenths: 100,
            downPitchTenths: 200
        )
        let bounded = PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 600, pitchTenths: 200),
            currentYawTenths: 0,
            currentPitchTenths: 0,
            envelope: envelope
        )

        XCTAssertEqual(
            bounded,
            PersonTrackingCorrection(yawTenths: 300, pitchTenths: 100)
        )
        XCTAssertTrue(envelope.contains(yawTenths: 300, pitchTenths: 100))
        XCTAssertFalse(envelope.contains(yawTenths: 600, pitchTenths: 200))
    }

    func testStepWhollyInsideEnvelopeIsUnchanged() {
        let correction = PersonTrackingCorrection(yawTenths: 20, pitchTenths: 10)
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                correction,
                currentYawTenths: 100,
                currentPitchTenths: 20
            ),
            correction
        )
    }

    func testPoseOutsideEnvelopeOnlyAllowsProgressBackInward() {
        XCTAssertNil(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 65, pitchTenths: 0),
                currentYawTenths: 500,
                currentPitchTenths: 0
            )
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
                currentYawTenths: 500,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 10, pitchTenths: -20),
                currentYawTenths: 400,
                currentPitchTenths: 100
            ),
            PersonTrackingCorrection(yawTenths: 10, pitchTenths: -20)
        )
    }

    func testContinuousFastStepClampsIntoNetSafetyBoundaryWithoutReversal() {
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 60, pitchTenths: 0),
                currentYawTenths: 400,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: 50, pitchTenths: 0)
        )
        XCTAssertNil(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 65, pitchTenths: 0),
                currentYawTenths: 450,
                currentPitchTenths: 0
            )
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
                currentYawTenths: 450,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -60, pitchTenths: 0),
                currentYawTenths: -400,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: -50, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
                currentYawTenths: 400,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: 25, pitchTenths: 8)
        )
        XCTAssertNil(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
                currentYawTenths: 450,
                currentPitchTenths: 0
            )
        )
    }

    func testVisionSampleKeepsLegacyTargetAndRawMultiPersonDetections() throws {
        let sessionID = UUID()
        let left = detection(centerX: 0.25, centerY: 0.5)
        let right = detection(centerX: 0.75, centerY: 0.5)
        let legacy = PersonVisionSample(
            sessionID: sessionID,
            detection: left,
            sequence: 1,
            observedAtUptime: 10
        )
        XCTAssertEqual(legacy.detection, left)
        XCTAssertEqual(legacy.detections, [left])

        let multi = PersonVisionSample(
            sessionID: sessionID,
            detections: [left, right],
            selectedDetection: right,
            sequence: 2,
            observedAtUptime: 10.1
        )
        XCTAssertEqual(multi.detections, [left, right])
        XCTAssertEqual(multi.detection, right)
    }

    func testIdentityTrackerKeepsIDsStableWhenVisionReordersPeople() throws {
        var tracker = PersonIdentityTracker()
        let first = tracker.update(
            detections: [
                detection(centerX: 0.25, centerY: 0.5),
                detection(centerX: 0.75, centerY: 0.5),
            ],
            sequence: 1,
            observedAtUptime: 20
        )
        XCTAssertEqual(first.personCount, 2)
        let leftID = try XCTUnwrap(first.candidates.first?.id)
        let rightID = try XCTUnwrap(first.candidates.last?.id)
        XCTAssertNotEqual(leftID, rightID)

        let reordered = tracker.update(
            detections: [
                detection(centerX: 0.72, centerY: 0.5),
                detection(centerX: 0.28, centerY: 0.5),
            ],
            sequence: 2,
            observedAtUptime: 20.08
        )
        XCTAssertEqual(reordered.candidates.map(\.id), [leftID, rightID])
        XCTAssertEqual(reordered.candidates.map(\.observationCount), [2, 2])
    }

    func testIdentityAssociationCanUseCenterDistanceWithoutOverlap() throws {
        var tracker = PersonIdentityTracker()
        let narrow = PersonDetection(
            x: 0.10,
            y: 0.30,
            width: 0.08,
            height: 0.35,
            confidence: 0.9
        )
        let first = tracker.update(
            detections: [narrow],
            sequence: 1,
            observedAtUptime: 30
        )
        let firstID = try XCTUnwrap(first.candidates.first?.id)
        let movedWithoutOverlap = PersonDetection(
            x: 0.22,
            y: 0.30,
            width: 0.08,
            height: 0.35,
            confidence: 0.9
        )
        XCTAssertEqual(
            PersonIdentityAssociationPolicy.intersectionOverUnion(
                narrow,
                movedWithoutOverlap
            ),
            0,
            accuracy: 0.000_001
        )

        let second = tracker.update(
            detections: [movedWithoutOverlap],
            sequence: 2,
            observedAtUptime: 30.08
        )
        XCTAssertEqual(second.candidates.first?.id, firstID)
    }

    func testMissingLockedTargetRequiresExplicitReselection() throws {
        var tracker = PersonIdentityTracker()
        let first = tracker.update(
            detections: [
                detection(centerX: 0.30, centerY: 0.5),
                detection(centerX: 0.75, centerY: 0.5),
            ],
            sequence: 1,
            observedAtUptime: 40
        )
        let lockedID = try XCTUnwrap(first.candidates.first?.id)
        let otherID = try XCTUnwrap(first.candidates.last?.id)
        XCTAssertTrue(tracker.lock(on: lockedID))

        let missing = tracker.update(
            detections: [detection(centerX: 0.73, centerY: 0.5)],
            sequence: 2,
            observedAtUptime: 40.08
        )
        XCTAssertEqual(missing.personCount, 1)
        XCTAssertEqual(missing.candidates.first?.id, otherID)
        XCTAssertEqual(missing.lockedID, lockedID)
        XCTAssertFalse(missing.isLockedTargetVisible)
        XCTAssertNil(missing.lockedDetection)

        let returned = tracker.update(
            detections: [
                detection(centerX: 0.72, centerY: 0.5),
                detection(centerX: 0.32, centerY: 0.5),
            ],
            sequence: 3,
            observedAtUptime: 40.16
        )
        XCTAssertEqual(returned.lockedID, lockedID)
        XCTAssertNil(returned.lockedCandidate)
        XCTAssertNil(returned.lockedDetection)
        XCTAssertFalse(returned.candidates.map(\.id).contains(lockedID))

        let returnedTarget = try XCTUnwrap(
            returned.candidates.first { abs($0.detection.centerX - 0.32) < 0.001 }
        )
        XCTAssertTrue(tracker.lock(on: returnedTarget.id))
        XCTAssertEqual(tracker.currentSnapshot.lockedID, returnedTarget.id)

        let afterReselection = tracker.update(
            detections: [
                detection(centerX: 0.71, centerY: 0.5),
                detection(centerX: 0.33, centerY: 0.5),
            ],
            sequence: 4,
            observedAtUptime: 40.24
        )
        XCTAssertEqual(afterReselection.lockedCandidate?.id, returnedTarget.id)
        XCTAssertEqual(
            try XCTUnwrap(afterReselection.lockedDetection).centerX,
            0.33,
            accuracy: 0.000_001
        )
    }

    func testExpiredLockedGeometryDoesNotTransferLockToReplacement() throws {
        var tracker = PersonIdentityTracker()
        let first = tracker.update(
            detections: [
                detection(centerX: 0.20, centerY: 0.5),
                detection(centerX: 0.80, centerY: 0.5),
            ],
            sequence: 1,
            observedAtUptime: 50
        )
        let lockedID = try XCTUnwrap(first.candidates.first?.id)
        XCTAssertTrue(tracker.lock(on: lockedID))

        _ = tracker.update(
            detections: [detection(centerX: 0.79, centerY: 0.5)],
            sequence: 2,
            observedAtUptime: 50.40
        )
        let replacement = tracker.update(
            detections: [
                detection(centerX: 0.21, centerY: 0.5),
                detection(centerX: 0.78, centerY: 0.5),
            ],
            sequence: 3,
            observedAtUptime: 50.90
        )
        XCTAssertEqual(replacement.lockedID, lockedID)
        XCTAssertFalse(replacement.isLockedTargetVisible)
        XCTAssertFalse(replacement.candidates.map(\.id).contains(lockedID))

        let replacementID = try XCTUnwrap(replacement.candidates.first?.id)
        XCTAssertFalse(tracker.lock(on: PersonCandidateID(rawValue: 99_999)))
        XCTAssertEqual(tracker.lockedID, lockedID)
        XCTAssertTrue(tracker.lock(on: replacementID))
        XCTAssertEqual(tracker.currentSnapshot.lockedID, replacementID)
        tracker.clearLock()
        XCTAssertNil(tracker.currentSnapshot.lockedID)
    }

    func testDefaultLockChoosesFirstDisplayedCandidateWithoutReplacingALock() throws {
        var tracker = PersonIdentityTracker()
        let snapshot = tracker.update(
            detections: [
                detection(centerX: 0.78, centerY: 0.5),
                detection(centerX: 0.22, centerY: 0.5),
            ],
            sequence: 1,
            observedAtUptime: 60
        )
        let firstDisplayed = try XCTUnwrap(snapshot.candidates.first)
        XCTAssertEqual(firstDisplayed.id.rawValue, 1)
        XCTAssertEqual(firstDisplayed.detection.centerX, 0.22, accuracy: 0.000_001)

        XCTAssertEqual(tracker.lockFirstVisibleCandidate(), firstDisplayed.id)
        XCTAssertEqual(tracker.currentSnapshot.lockedID, firstDisplayed.id)

        _ = tracker.update(
            detections: [
                detection(centerX: 0.21, centerY: 0.5),
                detection(centerX: 0.79, centerY: 0.5),
            ],
            sequence: 2,
            observedAtUptime: 60.08
        )
        XCTAssertNil(tracker.lockFirstVisibleCandidate())
        XCTAssertEqual(tracker.currentSnapshot.lockedID, firstDisplayed.id)
    }

    private func detection(centerX: Double, centerY: Double) -> PersonDetection {
        PersonDetection(
            x: centerX - 0.1,
            y: centerY - 0.2,
            width: 0.2,
            height: 0.4,
            confidence: 0.9
        )
    }
}
