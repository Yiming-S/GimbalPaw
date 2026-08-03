import XCTest
@testable import OM3Lab

final class PersonTrackingPolicyTests: XCTestCase {
    func testSearchDirectionOppositesClockwiseCycleAndTitles() {
        XCTAssertEqual(PersonSearchDirection.allCases, [.left, .right, .up, .down])
        XCTAssertEqual(PersonSearchDirection.left.opposite, .right)
        XCTAssertEqual(PersonSearchDirection.right.opposite, .left)
        XCTAssertEqual(PersonSearchDirection.up.opposite, .down)
        XCTAssertEqual(PersonSearchDirection.down.opposite, .up)
        XCTAssertEqual(PersonSearchDirection.right.clockwise, .down)
        XCTAssertEqual(PersonSearchDirection.down.clockwise, .left)
        XCTAssertEqual(PersonSearchDirection.left.clockwise, .up)
        XCTAssertEqual(PersonSearchDirection.up.clockwise, .right)
        XCTAssertEqual(PersonSearchDirection.left.title, "向左")
        XCTAssertEqual(PersonSearchDirection.right.title, "向右")
        XCTAssertEqual(PersonSearchDirection.up.title, "向上")
        XCTAssertEqual(PersonSearchDirection.down.title, "向下")
        XCTAssertEqual(PersonSearchMotionMode.allCases, [.coast, .scan])
    }

    func testSearchPolicyUsesBoundedCoastAndScanParameters() {
        XCTAssertEqual(PersonSearchPolicy.coastStepTenths, 20)
        XCTAssertEqual(PersonSearchPolicy.coastDurationTenths, 1)
        XCTAssertEqual(PersonSearchPolicy.coastCooldown, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.lossGraceStopCooldown, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumCoastTravelTenths, 60)

        XCTAssertEqual(PersonSearchPolicy.scanStepTenths, 50)
        XCTAssertEqual(PersonSearchPolicy.scanDurationTenths, 1)
        XCTAssertEqual(PersonSearchPolicy.scanCooldown, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.scanSettleDuration, 0.12, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumScanEpisodeDuration, 180.0, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumScanEpisodeTravelTenths, 30_000)
        XCTAssertEqual(PersonSearchPolicy.commandMaximumAge, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.commandRetryInterval, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(PersonSearchPolicy.maximumVisionSilence, 0.50, accuracy: 0.000_001)
    }

    func testCoastRequiresTrustedOutwardEdgeTrajectory() {
        let rightExit = [
            PersonSearchObservation(centerX: 0.78, centerY: 0.50, confidence: 0.8),
            PersonSearchObservation(centerX: 0.83, centerY: 0.50, confidence: 0.8),
            PersonSearchObservation(centerX: 0.89, centerY: 0.50, confidence: 0.8),
        ]
        XCTAssertEqual(
            PersonSearchPolicy.coastDirection(
                recentObservations: rightExit,
                lastCorrection: PersonTrackingCorrection(yawTenths: 10, pitchTenths: 0)
            ),
            .right
        )
        XCTAssertNil(
            PersonSearchPolicy.coastDirection(
                recentObservations: rightExit,
                lastCorrection: PersonTrackingCorrection(yawTenths: -10, pitchTenths: 0)
            )
        )
        let upExit = [
            PersonSearchObservation(centerX: 0.50, centerY: 0.21, confidence: 0.8),
            PersonSearchObservation(centerX: 0.50, centerY: 0.16, confidence: 0.8),
            PersonSearchObservation(centerX: 0.50, centerY: 0.10, confidence: 0.8),
        ]
        XCTAssertEqual(
            PersonSearchPolicy.coastDirection(
                recentObservations: upExit,
                lastCorrection: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -10)
            ),
            .up
        )
        XCTAssertNil(
            PersonSearchPolicy.coastDirection(
                recentObservations: [
                    PersonSearchObservation(centerX: 0.80, centerY: 0.5, confidence: 0.8),
                    PersonSearchObservation(centerX: 0.86, centerY: 0.5, confidence: 0.8),
                    PersonSearchObservation(centerX: 0.84, centerY: 0.5, confidence: 0.8),
                    PersonSearchObservation(centerX: 0.89, centerY: 0.5, confidence: 0.8),
                ],
                lastCorrection: PersonTrackingCorrection(yawTenths: 10, pitchTenths: 0)
            )
        )
    }

    func testRequestedSearchStepsCoverBothAxes() {
        XCTAssertEqual(
            PersonSearchPolicy.requestedStep(direction: .left, mode: .scan),
            PersonTrackingCorrection(yawTenths: -50, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonSearchPolicy.requestedStep(direction: .right, mode: .scan),
            PersonTrackingCorrection(yawTenths: 50, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonSearchPolicy.requestedStep(direction: .up, mode: .scan),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: -50)
        )
        XCTAssertEqual(
            PersonSearchPolicy.requestedStep(direction: .down, mode: .coast),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: 20)
        )
    }

    func testSearchBoundaryDetectionComparesCompleteCorrection() {
        XCTAssertFalse(
            PersonSearchPolicy.reachesEnvelopeBoundary(
                requested: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20),
                submitted: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20)
            )
        )
        XCTAssertTrue(
            PersonSearchPolicy.reachesEnvelopeBoundary(
                requested: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20),
                submitted: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -5)
            )
        )
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

    func testCenteredPersonNeedsNoCorrection() {
        XCTAssertNil(PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.5)))
    }

    func testHorizontalDirectionAndClamp() {
        // Piecewise-linear profile: error 0.30 interpolates the medium→max
        // band (0.22...0.34) as 35 + (0.08 / 0.12) * 30 ≈ 55.
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.80, centerY: 0.5)),
            PersonTrackingCorrection(yawTenths: 55, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.05, centerY: 0.5)),
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0)
        )
    }

    func testVerticalDirectionMatchesCalibratedOM3Mapping() {
        // The filtered head anchor (box top + 0.25 × height) targets Y=0.32.
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.20)),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.90)),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: 20)
        )
    }

    func testTighterVerticalHysteresisRespondsToOrdinaryPitchError() {
        XCTAssertEqual(PersonTrackingPolicy.verticalDeadZone, 0.08, accuracy: 0.000_001)
        XCTAssertEqual(PersonTrackingPolicy.verticalInnerDeadZone, 0.04, accuracy: 0.000_001)
        XCTAssertEqual(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.51)),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: 7)
        )
        XCTAssertNil(
            PersonTrackingPolicy.correction(for: detection(centerX: 0.5, centerY: 0.50))
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

    func testPredictiveAimLeadsMovingTarget() throws {
        let still = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.66,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: nil,
            speedMode: .fast
        )
        let moving = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.66,
            anchorY: 0.32,
            velocityX: 0.5,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: nil,
            speedMode: .fast
        )
        let stillYaw = try XCTUnwrap(still.correction).yawTenths
        let movingYaw = try XCTUnwrap(moving.correction).yawTenths
        XCTAssertGreaterThan(movingYaw, stillYaw,
                             "a rightward-moving target must get a larger lead correction")

        let runaway = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.66,
            anchorY: 0.32,
            velocityX: 50,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: nil,
            speedMode: .fast
        )
        let cappedError = 0.66 + PersonTrackingPolicy.maximumPredictionLead - 0.5
        XCTAssertLessThan(cappedError, 0.34, "capped lead must stay below the max band here")
        XCTAssertEqual(
            try XCTUnwrap(runaway.correction).yawTenths,
            try XCTUnwrap(
                PersonTrackingPolicy.predictiveCorrection(
                    anchorX: 0.66 + PersonTrackingPolicy.maximumPredictionLead,
                    anchorY: 0.32,
                    velocityX: 0,
                    velocityY: 0,
                    centering: .uncentered,
                    previousCorrection: nil,
                    speedMode: .fast
                ).correction
            ).yawTenths,
            "the prediction lead must clamp at maximumPredictionLead"
        )
    }

    func testDeadZoneHysteresisKeepsCorrectingUntilInnerZone() {
        // Centered regime: an error inside the outer dead zone stays centered.
        let centered = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.60,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .centered,
            previousCorrection: nil,
            speedMode: .fast
        )
        XCTAssertNil(centered.correction)
        XCTAssertTrue(centered.centering.yawCentered)

        // Correcting regime: the same error keeps a minimum nudge going.
        let correcting = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.60,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: nil,
            speedMode: .fast
        )
        XCTAssertEqual(correcting.correction?.yawTenths,
                       PersonTrackingSpeedMode.fast.minimumStepTenths)
        XCTAssertFalse(correcting.centering.yawCentered)

        // Only inside the inner zone does the axis re-center.
        let recentered = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.56,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: nil,
            speedMode: .fast
        )
        XCTAssertNil(recentered.correction)
        XCTAssertTrue(recentered.centering.yawCentered)
    }

    func testMinorReversalAbsorbsAxisWithoutStop() {
        let decision = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.40,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 30, pitchTenths: 0),
            speedMode: .fast
        )
        XCTAssertFalse(decision.requiresReversalStop,
                       "a sub-threshold reversal must not trigger the STOP path")
        XCTAssertNil(decision.correction,
                     "the reversing axis is held for one cycle instead")
        XCTAssertFalse(decision.centering.yawCentered)
        XCTAssertEqual(decision.minorReversalAxes, [.yaw])
    }

    func testSignificantPitchReversalRequiresStop() {
        let decision = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.50,
            anchorY: 0.60,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20),
            speedMode: .fast
        )
        XCTAssertTrue(decision.requiresReversalStop)
        XCTAssertNil(decision.correction)
        XCTAssertTrue(decision.minorReversalAxes.isEmpty)
    }

    func testMinorReversalIsConsumedSoSecondFrameCanReverse() throws {
        let previous = PersonTrackingCorrection(yawTenths: 30, pitchTenths: 0)
        let first = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.40,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: previous,
            speedMode: .fast
        )
        XCTAssertNil(first.correction, "the first reverse frame is the one-cycle hold")

        let consumedHistory = first.minorReversalAxes.consuming(previous)
        XCTAssertNil(consumedHistory, "the held yaw direction must be consumed")
        let second = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.40,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: first.centering,
            previousCorrection: consumedHistory,
            speedMode: .fast
        )
        XCTAssertLessThan(
            try XCTUnwrap(second.correction).yawTenths,
            0,
            "the same small reverse error must move on the following frame"
        )
        XCTAssertTrue(second.minorReversalAxes.isEmpty)
    }

    func testMinorReversalConsumptionOnlyClearsAffectedAxis() {
        let previous = PersonTrackingCorrection(yawTenths: 30, pitchTenths: -12)
        XCTAssertEqual(
            PersonTrackingReversalAxes.yaw.consuming(previous),
            PersonTrackingCorrection(yawTenths: 0, pitchTenths: -12)
        )
        XCTAssertEqual(
            PersonTrackingReversalAxes.pitch.consuming(previous),
            PersonTrackingCorrection(yawTenths: 30, pitchTenths: 0)
        )
    }

    func testDelayedPipelineDoesNotRenewMotionSafeVision() {
        var health = PersonTrackingVisionHealth()
        XCTAssertTrue(
            health.record(
                sampleObservedAtUptime: 99.95,
                receivedAtUptime: 100.0,
                maximumSampleAge: 0.10
            )
        )
        XCTAssertEqual(
            health.motionSafety(at: 100.40, maximumSilence: 0.50),
            .safe
        )

        for receivedAt in stride(from: 100.20, through: 100.80, by: 0.20) {
            XCTAssertFalse(
                health.record(
                    sampleObservedAtUptime: receivedAt - 0.20,
                    receivedAtUptime: receivedAt,
                    maximumSampleAge: 0.10
                )
            )
        }
        XCTAssertEqual(
            health.motionSafety(at: 100.80, maximumSilence: 0.50),
            .samplesTooOld,
            "active but delayed delivery must not authorize an automatic scan"
        )
        XCTAssertEqual(
            health.motionSafety(at: 101.40, maximumSilence: 0.50),
            .pipelineStalled
        )
    }

    func testVisionAuthorizationDeadlineMustCoverWholeScanMotion() throws {
        var health = PersonTrackingVisionHealth()
        XCTAssertTrue(
            health.record(
                sampleObservedAtUptime: 99.95,
                receivedAtUptime: 100.0,
                maximumSampleAge: 0.10
            )
        )
        let deadline = try XCTUnwrap(
            health.motionAuthorizationDeadline(maximumSilence: 0.50)
        )
        XCTAssertEqual(deadline, 100.50, accuracy: 0.000_001)
        let scanDuration = Double(PersonSearchPolicy.scanDurationTenths) / 10.0
        XCTAssertGreaterThan(
            100.21 + scanDuration,
            deadline,
            "a scan that starts while currently safe can still finish too late"
        )
        XCTAssertLessThanOrEqual(
            100.20 + scanDuration,
            deadline,
            "a scan finishing exactly at the authorization deadline is allowed"
        )
    }

    func testMajorReversalRequestsStop() {
        let decision = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.20,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 30, pitchTenths: 0),
            speedMode: .fast
        )
        XCTAssertTrue(decision.requiresReversalStop)
        XCTAssertNil(decision.correction)
    }

    func testSlewLimitBoundsMagnitudeGrowthButNotDecay() throws {
        let growth = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.95,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 5, pitchTenths: 0),
            speedMode: .fast
        )
        XCTAssertEqual(
            try XCTUnwrap(growth.correction).yawTenths,
            5 + PersonTrackingPolicy.slewLimitTenths,
            "magnitude growth must be slew-limited per command"
        )

        let decay = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.66,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 65, pitchTenths: 0),
            speedMode: .fast
        )
        XCTAssertEqual(
            try XCTUnwrap(decay.correction).yawTenths, 17,
            "decaying toward zero must not be slew-limited"
        )
    }

    func testHeadAnchorIsStableAgainstBoxHeightChanges() {
        let armsDown = PersonDetection(
            x: 0.4, y: 0.30, width: 0.2, height: 0.40, confidence: 0.9
        )
        let armsRaised = PersonDetection(
            x: 0.4, y: 0.30, width: 0.2, height: 0.55, confidence: 0.9
        )
        let anchorShift = abs(
            PersonTrackingPolicy.headAnchorY(for: armsRaised)
                - PersonTrackingPolicy.headAnchorY(for: armsDown)
        )
        let centerShift = abs(armsRaised.centerY - armsDown.centerY)
        XCTAssertLessThan(anchorShift, centerShift,
                          "the head anchor must move less than the box center when the box grows")
    }

    func testOneEuroFilterSmoothsJitterAndTracksMotion() {
        var filter = OneEuroFilter(minimumCutoff: 1.2, beta: 0.4, derivativeCutoff: 1.0)
        var time = 100.0
        filter.filter(0.50, at: time)
        // Small alternating jitter around a static position is attenuated.
        var lastOutput = 0.50
        for index in 0..<20 {
            time += 0.033
            let jitter = index.isMultiple(of: 2) ? 0.02 : -0.02
            lastOutput = filter.filter(0.50 + jitter, at: time)
        }
        XCTAssertLessThan(abs(lastOutput - 0.50), 0.01,
                          "static jitter must be attenuated below half its amplitude")

        // A steady walk is tracked with bounded lag and a sane velocity.
        var position = 0.50
        for _ in 0..<30 {
            time += 0.033
            position += 0.30 * 0.033
            lastOutput = filter.filter(position, at: time)
        }
        XCTAssertLessThan(abs(lastOutput - position), 0.05,
                          "filter lag on a moving target must stay small")
        XCTAssertEqual(filter.velocity, 0.30, accuracy: 0.12,
                       "the filtered derivative must approximate the true velocity")
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
            PersonTrackingPolicy.correction(for: farLeft, speedMode: .turbo50x),
            PersonTrackingCorrection(yawTenths: -120, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(
                for: detection(centerX: 0.65, centerY: 0.5),
                speedMode: .fast
            ),
            PersonTrackingCorrection(yawTenths: 14, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(
                for: detection(centerX: 0.78, centerY: 0.5),
                speedMode: .fast
            ),
            PersonTrackingCorrection(yawTenths: 50, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(
                for: detection(centerX: 0.65, centerY: 0.5),
                speedMode: .turbo50x
            ),
            PersonTrackingCorrection(yawTenths: 47, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correction(
                for: detection(centerX: 0.78, centerY: 0.5),
                speedMode: .turbo50x
            ),
            PersonTrackingCorrection(yawTenths: 106, pitchTenths: 0)
        )

        for mode in PersonTrackingSpeedMode.allCases {
            let duration = Double(mode.commandDurationTenths) / 10.0
            if mode == .fast || mode == .turbo50x {
                XCTAssertEqual(mode.commandCooldown, duration, accuracy: 0.000_001)
            } else {
                XCTAssertGreaterThanOrEqual(mode.commandCooldown, duration + 0.10)
            }
            XCTAssertLessThanOrEqual(mode.pitchMaximumTenths, 91)
            XCTAssertLessThanOrEqual(
                mode.combinedMaximumTenths,
                OM3HardwareMotionLimits.maximumCombinedCommandTenths(
                    durationTenths: mode.commandDurationTenths
                )
            )
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
        let smoothYawRate = Double(PersonTrackingSpeedMode.smooth.yawMaximumTenths)
            / PersonTrackingSpeedMode.smooth.commandCooldown
        let turboYawRate = Double(PersonTrackingSpeedMode.turbo50x.yawMaximumTenths)
            / PersonTrackingSpeedMode.turbo50x.commandCooldown
        let smoothPitchRate = Double(PersonTrackingSpeedMode.smooth.pitchMaximumTenths)
            / PersonTrackingSpeedMode.smooth.commandCooldown
        let turboPitchRate = Double(PersonTrackingSpeedMode.turbo50x.pitchMaximumTenths)
            / PersonTrackingSpeedMode.turbo50x.commandCooldown
        XCTAssertEqual(
            turboYawRate,
            Double(OM3HardwareMotionLimits.maximumControllableSpeedTenthsPerSecond),
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(turboYawRate / smoothYawRate, 40.0)
        XCTAssertLessThanOrEqual(turboYawRate / smoothYawRate, 50.0)
        XCTAssertEqual(turboPitchRate / smoothPitchRate, 50.0, accuracy: 0.5)
        XCTAssertEqual(
            Double(PersonTrackingSpeedMode.turbo50x.minimumStepTenths)
                / PersonTrackingSpeedMode.turbo50x.commandCooldown
                / (Double(PersonTrackingSpeedMode.smooth.minimumStepTenths)
                    / PersonTrackingSpeedMode.smooth.commandCooldown),
            50.0,
            accuracy: 1.5
        )
        XCTAssertEqual(
            Double(PersonTrackingSpeedMode.turbo50x.mediumStepTenths)
                / PersonTrackingSpeedMode.turbo50x.commandCooldown
                / (Double(PersonTrackingSpeedMode.smooth.mediumStepTenths)
                    / PersonTrackingSpeedMode.smooth.commandCooldown),
            50.0,
            accuracy: 0.5
        )
        XCTAssertEqual(PersonTrackingSpeedMode.turbo50x.commandDurationTenths, 1)
        XCTAssertLessThanOrEqual(
            PersonTrackingSpeedMode.turbo50x.maximumSampleAge,
            PersonTrackingSpeedMode.turbo50x.commandCooldown
        )
        XCTAssertGreaterThanOrEqual(PersonTrackingPolicy.minimumStopCooldown, 0.12)
    }

    func testTurboProfileRemovesLegacyGrowthBottleneckButStillStopsOnReverse() throws {
        let growth = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.95,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 28, pitchTenths: 0),
            speedMode: .turbo50x
        )
        XCTAssertEqual(try XCTUnwrap(growth.correction).yawTenths, 120)

        let reverse = PersonTrackingPolicy.predictiveCorrection(
            anchorX: 0.05,
            anchorY: 0.32,
            velocityX: 0,
            velocityY: 0,
            centering: .uncentered,
            previousCorrection: PersonTrackingCorrection(yawTenths: 28, pitchTenths: 0),
            speedMode: .turbo50x
        )
        XCTAssertTrue(reverse.requiresReversalStop)
        XCTAssertNil(reverse.correction)
    }

    func testTravelBudgetsDoNotUndercutExpandedHardwareEnvelope() {
        for mode in PersonTrackingSpeedMode.allCases {
            XCTAssertGreaterThanOrEqual(
                mode.yawTravelBudgetTenths,
                OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees.right * 10
            )
            XCTAssertGreaterThanOrEqual(
                mode.pitchTravelBudgetTenths,
                OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees.down * 10
            )
        }
        XCTAssertTrue(
            PersonTrackingTravelBudgetPolicy.allowsCorrection(
                nextYawTravelTenths: 45_000,
                nextPitchTravelTenths: 45_000,
                speedMode: .turbo50x
            )
        )
        XCTAssertFalse(
            PersonTrackingTravelBudgetPolicy.allowsCorrection(
                nextYawTravelTenths: 45_001,
                nextPitchTravelTenths: 45_000,
                speedMode: .turbo50x
            )
        )
        XCTAssertFalse(
            PersonTrackingTravelBudgetPolicy.allowsSearch(
                nextYawTravelTenths: 45_001,
                nextPitchTravelTenths: 0,
                speedMode: .turbo50x
            )
        )
        XCTAssertFalse(
            PersonTrackingTravelBudgetPolicy.allowsSearch(
                nextYawTravelTenths: 0,
                nextPitchTravelTenths: 45_001,
                speedMode: .turbo50x
            )
        )
    }

    func testSpeedProfileMigrationRunsOnceThenPreservesManualChoice() {
        XCTAssertEqual(
            PersonTrackingSpeedSelectionPolicy.selection(
                storedRawValue: PersonTrackingSpeedMode.smooth.rawValue,
                storedProfileVersion: nil
            ),
            PersonTrackingSpeedSelection(mode: .turbo50x, requiresWriteback: true)
        )
        XCTAssertEqual(
            PersonTrackingSpeedSelectionPolicy.selection(
                storedRawValue: PersonTrackingSpeedMode.smooth.rawValue,
                storedProfileVersion: 1
            ),
            PersonTrackingSpeedSelection(mode: .smooth, requiresWriteback: false)
        )
        XCTAssertEqual(
            PersonTrackingSpeedSelectionPolicy.selection(
                storedRawValue: nil,
                storedProfileVersion: 1
            ),
            PersonTrackingSpeedSelection(mode: .turbo50x, requiresWriteback: true)
        )
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
                currentYawTenths: 1_300,
                currentPitchTenths: 0
            )
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
                currentYawTenths: 1_300,
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
                currentYawTenths: 1_150,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: 50, pitchTenths: 0)
        )
        XCTAssertNil(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 65, pitchTenths: 0),
                currentYawTenths: 1_200,
                currentPitchTenths: 0
            )
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
                currentYawTenths: 1_200,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: -60, pitchTenths: 0),
                currentYawTenths: -1_150,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: -50, pitchTenths: 0)
        )
        XCTAssertEqual(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
                currentYawTenths: 1_150,
                currentPitchTenths: 0
            ),
            PersonTrackingCorrection(yawTenths: 30, pitchTenths: 10)
        )
        XCTAssertNil(
            PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
                PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
                currentYawTenths: 1_200,
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

    func testLockedTargetSurvivesBriefDetectionFlicker() throws {
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

        for (index, uptime) in [40.08, 40.16, 40.24].enumerated() {
            let missing = tracker.update(
                detections: [detection(centerX: 0.74, centerY: 0.5)],
                sequence: UInt64(index + 2),
                observedAtUptime: uptime
            )
            XCTAssertNil(missing.lockedDetection)
            XCTAssertEqual(missing.candidates.first?.id, otherID)
            XCTAssertFalse(tracker.hasUnresolvedRetiredLock)
        }

        let returned = tracker.update(
            detections: [
                detection(centerX: 0.73, centerY: 0.5),
                detection(centerX: 0.33, centerY: 0.5),
            ],
            sequence: 5,
            observedAtUptime: 40.32
        )
        XCTAssertEqual(returned.lockedCandidate?.id, lockedID)
        XCTAssertEqual(
            try XCTUnwrap(returned.lockedDetection).centerX,
            0.33,
            accuracy: 0.000_001
        )
    }

    func testLockedTargetRetiresAfterFlickerToleranceAndRequiresExplicitTransfer() throws {
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
        XCTAssertTrue(tracker.lock(on: lockedID))

        var sequence: UInt64 = 2
        for uptime in [40.08, 40.16, 40.24, 40.32, 40.40] {
            _ = tracker.update(
                detections: [detection(centerX: 0.74, centerY: 0.5)],
                sequence: sequence,
                observedAtUptime: uptime
            )
            sequence += 1
        }
        XCTAssertTrue(tracker.hasUnresolvedRetiredLock)

        let returned = tracker.update(
            detections: [
                detection(centerX: 0.73, centerY: 0.5),
                detection(centerX: 0.32, centerY: 0.5),
            ],
            sequence: sequence,
            observedAtUptime: 40.48
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
        XCTAssertFalse(tracker.hasUnresolvedRetiredLock)

        let afterReselection = tracker.update(
            detections: [
                detection(centerX: 0.71, centerY: 0.5),
                detection(centerX: 0.33, centerY: 0.5),
            ],
            sequence: sequence + 1,
            observedAtUptime: 40.56
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
