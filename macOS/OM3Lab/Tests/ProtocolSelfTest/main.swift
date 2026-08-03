import Darwin
import Foundation

private var assertions = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func motionSignature() -> GimbalMotionSignature {
    let width = 64
    let height = 36
    let luma = (0..<(width * height)).map { index -> UInt8 in
        let x = index % width
        let y = index / width
        return UInt8(24 + (x * 29 + y * 47 + x * y * 7) % 184)
    }
    return GimbalMotionSignature(width: width, height: height, luma: luma)
}

private func shifted(
    _ signature: GimbalMotionSignature,
    dx: Int,
    dy: Int
) -> GimbalMotionSignature {
    var output = Array(repeating: UInt8(0), count: signature.luma.count)
    for y in 0..<signature.height {
        for x in 0..<signature.width {
            let sourceX = min(signature.width - 1, max(0, x - dx))
            let sourceY = min(signature.height - 1, max(0, y - dy))
            output[y * signature.width + x]
                = signature.luma[sourceY * signature.width + sourceX]
        }
    }
    return GimbalMotionSignature(
        width: signature.width,
        height: signature.height,
        luma: output
    )
}

do {
    let goldenFrames: [(Int, Int, String)] = [
        (5, 0, "55 15 04 a9 02 04 01 00 00 04 14 32 00 00 00 00 00 04 0a 39 cd"),
        (-5, 0, "55 15 04 a9 02 04 01 00 00 04 14 ce ff 00 00 00 00 04 0a 65 3b"),
        (0, 5, "55 15 04 a9 02 04 01 00 00 04 14 00 00 00 00 32 00 04 0a 5a 5e"),
        (0, -5, "55 15 04 a9 02 04 01 00 00 04 14 00 00 00 00 ce ff 04 0a b6 78"),
    ]

    for (yaw, pitch, expected) in goldenFrames {
        let frame = try OM3Protocol.relativeNudge(yawDegrees: yaw, pitchDegrees: pitch)
        expect(frame.count == 21, "nudge frame must be 21 bytes")
        expect(OM3Protocol.hex(frame) == expected, "golden nudge frame mismatch")
    }

    let stop = try OM3Protocol.stopMessage()
    expect(stop.count == 21, "STOP frame must be 21 bytes")
    expect(
        OM3Protocol.hex(stop) == "55 15 04 a9 02 04 01 00 00 04 0c 00 00 00 00 00 00 80 00 76 ef",
        "golden STOP frame mismatch"
    )

    expect(
        OM3HardwareMotionLimits.structuralCeilingDegrees
            == OM3HardwareMotionLimits.DirectionalDegrees(
                left: 162.5,
                right: 170.3,
                up: 104.5,
                down: 235.7
            ),
        "DJI OM3 published structural ranges must remain the outer sanity authority"
    )
    expect(
        OM3HardwareMotionLimits.probeCapsDegrees
            == OM3HardwareMotionLimits.DirectionalWholeDegrees(
                left: 150,
                right: 160,
                up: 98,
                down: 228
            ),
        "four-direction calibration probe caps mismatch"
    )
    expect(
        GimbalTrackingEnvelope.conservativeDefault
            == GimbalTrackingEnvelope(
                leftYawTenths: 1_200,
                rightYawTenths: 1_200,
                upPitchTenths: 600,
                downPitchTenths: 600
            ),
        "un-calibrated centered envelope must no longer use the old 45° / 15° limits"
    )
    expect(
        OM3HardwareMotionLimits.maximumCombinedCommandTenths(durationTenths: 1) == 120,
        "a 0.1-second OM3 command must be capped at 12 degrees"
    )

    let tracking = try OM3Protocol.relativeMove(
        yawTenths: 5,
        pitchTenths: -5,
        durationTenths: PersonTrackingSpeedMode.fast.commandDurationTenths
    )
    expect(tracking.count == 21, "tracking frame must be 21 bytes")
    expect(tracking[10] == 0x14, "tracking frame must use relative command")
    expect(tracking[11] == 0x05 && tracking[12] == 0x00, "tracking yaw encoding mismatch")
    expect(tracking[15] == 0xfb && tracking[16] == 0xff, "tracking pitch encoding mismatch")
    expect(tracking[18] == 0x01, "tracking duration must be 0.1 seconds")

    for (direction, expectedPitch) in [
        (PersonSearchDirection.up, -PersonSearchPolicy.scanStepTenths),
        (PersonSearchDirection.down, PersonSearchPolicy.scanStepTenths),
    ] {
        let correction = PersonSearchPolicy.requestedStep(direction: direction, mode: .scan)
        let frame = try OM3Protocol.relativeMove(
            yawTenths: correction.yawTenths,
            pitchTenths: correction.pitchTenths,
            durationTenths: PersonSearchPolicy.scanDurationTenths
        )
        expect(correction.pitchTenths == expectedPitch, "vertical scan correction sign mismatch")
        expect(frame[11] == 0 && frame[12] == 0, "vertical scan must keep yaw at zero")
        let encodedPitch = Int16(bitPattern: UInt16(frame[15]) | UInt16(frame[16]) << 8)
        expect(Int(encodedPitch) == expectedPitch, "vertical scan BLE pitch encoding mismatch")
        expect(frame[18] == PersonSearchPolicy.scanDurationTenths, "scan duration mismatch")
    }

    let centered = PersonDetection(
        x: 0.4,
        y: 0.3,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    expect(PersonTrackingPolicy.correction(for: centered) == nil, "dead-zone must suppress motion")
    expect(
        PersonTrackingPolicy.verticalDeadZone == 0.08
            && PersonTrackingPolicy.verticalInnerDeadZone == 0.04,
        "Pitch hysteresis must remain tighter than the old hidden vertical band"
    )
    let ordinaryDown = PersonDetection(
        x: 0.4,
        y: 0.31,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    expect(
        PersonTrackingPolicy.correction(for: ordinaryDown)?.pitchTenths ?? 0 > 0,
        "an ordinary downward head-anchor error must produce positive Pitch"
    )
    let pitchReverse = PersonTrackingPolicy.predictiveCorrection(
        anchorX: 0.5,
        anchorY: 0.60,
        velocityX: 0,
        velocityY: 0,
        centering: .uncentered,
        previousCorrection: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -20),
        speedMode: .fast
    )
    expect(
        pitchReverse.requiresReversalStop && pitchReverse.correction == nil,
        "a significant Pitch reversal must require STOP"
    )

    let upperRight = PersonDetection(
        x: 0.7,
        y: 0.0,
        width: 0.2,
        height: 0.3,
        confidence: 0.9
    )
    if let upperRightCorrection = PersonTrackingPolicy.correction(for: upperRight) {
        expect(
            upperRightCorrection.yawTenths > 0 && upperRightCorrection.pitchTenths < 0,
            "upper-right mapping must be yaw positive and pitch negative"
        )
    } else {
        expect(false, "upper-right error must produce a correction")
    }

    let farLeft = PersonDetection(
        x: -0.05,
        y: 0.3,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    expect(
        PersonTrackingPolicy.correction(for: farLeft, speedMode: .smooth)?.yawTenths == -15,
        "smooth tracking profile must cap yaw at 1.5 degrees"
    )
    expect(
        PersonTrackingPolicy.correction(for: farLeft, speedMode: .standard)?.yawTenths == -20,
        "standard tracking profile must cap yaw at 2.0 degrees"
    )
    expect(
        PersonTrackingPolicy.correction(for: farLeft, speedMode: .fast)?.yawTenths == -65,
        "continuous fast tracking profile must cap yaw at 6.5 degrees"
    )
    expect(
        PersonTrackingPolicy.correction(for: farLeft, speedMode: .turbo50x)?.yawTenths == -120,
        "50x tracking profile must respect the OM3 12-degree-per-0.1-second cap"
    )
    let fastNearRight = PersonDetection(
        x: 0.55,
        y: 0.3,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    let fastMidRight = PersonDetection(
        x: 0.68,
        y: 0.3,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    expect(
        PersonTrackingPolicy.correction(for: fastNearRight, speedMode: .fast)?.yawTenths == 14,
        "continuous fast tracking must ramp gently near the dead zone"
    )
    expect(
        PersonTrackingPolicy.correction(for: fastMidRight, speedMode: .fast)?.yawTenths == 50,
        "continuous fast tracking must interpolate the medium band"
    )
    expect(
        PersonTrackingPolicy.correction(for: fastNearRight, speedMode: .turbo50x)?.yawTenths == 47,
        "50x tracking must scale the near-error proportional waypoint"
    )
    expect(
        PersonTrackingPolicy.correction(for: fastMidRight, speedMode: .turbo50x)?.yawTenths == 106,
        "50x tracking must scale the medium-error waypoint below the hardware cap"
    )
    let previousContinuousMaximumRate = 45.0 / 0.21
    let upgradedMaximumRate = Double(PersonTrackingSpeedMode.fast.yawMaximumTenths)
        / PersonTrackingSpeedMode.fast.commandCooldown
    expect(
        upgradedMaximumRate >= previousContinuousMaximumRate * 3.0,
        "continuous fast yaw rate must be at least three times the previous profile"
    )
    expect(
        PersonTrackingSpeedMode.fast.pitchMaximumTenths <= 20,
        "fast tracking pitch must stay capped at two degrees"
    )
    expect(
        PersonTrackingSpeedMode.fast.commandCooldown
            == Double(PersonTrackingSpeedMode.fast.commandDurationTenths) / 10.0,
        "continuous fast tracking must add no idle delay after each action"
    )
    expect(
        PersonTrackingSpeedMode.fast.maximumSampleAge
            <= PersonTrackingSpeedMode.fast.commandCooldown,
        "fast tracking must reject samples older than one command interval"
    )
    let smoothYawRate = Double(PersonTrackingSpeedMode.smooth.yawMaximumTenths)
        / PersonTrackingSpeedMode.smooth.commandCooldown
    let turboYawRate = Double(PersonTrackingSpeedMode.turbo50x.yawMaximumTenths)
        / PersonTrackingSpeedMode.turbo50x.commandCooldown
    let smoothPitchRate = Double(PersonTrackingSpeedMode.smooth.pitchMaximumTenths)
        / PersonTrackingSpeedMode.smooth.commandCooldown
    let turboPitchRate = Double(PersonTrackingSpeedMode.turbo50x.pitchMaximumTenths)
        / PersonTrackingSpeedMode.turbo50x.commandCooldown
    expect(
        turboYawRate
            == Double(OM3HardwareMotionLimits.maximumControllableSpeedTenthsPerSecond),
        "50x yaw must saturate exactly at DJI's published OM3 speed ceiling"
    )
    expect(
        turboYawRate / smoothYawRate > 40.0
            && turboYawRate / smoothYawRate <= 50.0,
        "the hardware-capped 50x yaw response must remain above forty times smooth mode"
    )
    expect(
        abs(turboPitchRate / smoothPitchRate - 50.0) <= 0.5,
        "50x tracking pitch rate must remain approximately fifty times smooth mode"
    )
    expect(
        abs(
            Double(PersonTrackingSpeedMode.turbo50x.minimumStepTenths)
                / PersonTrackingSpeedMode.turbo50x.commandCooldown
                / (Double(PersonTrackingSpeedMode.smooth.minimumStepTenths)
                    / PersonTrackingSpeedMode.smooth.commandCooldown)
                - 50.0
        ) <= 1.5,
        "50x tracking minimum correction rate must remain near the profile ratio"
    )
    expect(
        abs(
            Double(PersonTrackingSpeedMode.turbo50x.mediumStepTenths)
                / PersonTrackingSpeedMode.turbo50x.commandCooldown
                / (Double(PersonTrackingSpeedMode.smooth.mediumStepTenths)
                    / PersonTrackingSpeedMode.smooth.commandCooldown)
                - 50.0
        ) <= 0.5,
        "50x tracking medium correction rate must remain near the profile ratio"
    )
    expect(
        PersonTrackingSpeedMode.turbo50x.commandCooldown
            == Double(PersonTrackingSpeedMode.turbo50x.commandDurationTenths) / 10.0,
        "50x tracking must add no idle delay after each action"
    )
    expect(
        PersonTrackingSpeedMode.turbo50x.maximumSampleAge
            <= PersonTrackingSpeedMode.turbo50x.commandCooldown,
        "50x tracking must reject samples older than one command interval"
    )
    let turboGrowth = PersonTrackingPolicy.predictiveCorrection(
        anchorX: 0.95,
        anchorY: 0.32,
        velocityX: 0,
        velocityY: 0,
        centering: .uncentered,
        previousCorrection: PersonTrackingCorrection(yawTenths: 28, pitchTenths: 0),
        speedMode: .turbo50x
    )
    expect(
        turboGrowth.correction?.yawTenths == 120,
        "50x tracking must remove the legacy growth bottleneck without exceeding 120°/s"
    )
    let turboReverse = PersonTrackingPolicy.predictiveCorrection(
        anchorX: 0.05,
        anchorY: 0.32,
        velocityX: 0,
        velocityY: 0,
        centering: .uncentered,
        previousCorrection: PersonTrackingCorrection(yawTenths: 28, pitchTenths: 0),
        speedMode: .turbo50x
    )
    expect(
        turboReverse.requiresReversalStop && turboReverse.correction == nil,
        "50x tracking must retain the major-reversal STOP"
    )
    expect(
        PersonTrackingSpeedMode.smooth.yawTravelBudgetTenths
            >= OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees.right * 10,
        "every profile's cumulative yaw fuse must allow reaching a calibrated boundary"
    )
    expect(
        PersonTrackingSpeedMode.smooth.pitchTravelBudgetTenths
            >= OM3HardwareMotionLimits.maximumCalibratedEnvelopeDegrees.down * 10,
        "every profile's cumulative pitch fuse must allow reaching a calibrated boundary"
    )
    expect(
        PersonTrackingTravelBudgetPolicy.allowsCorrection(
            nextYawTravelTenths: 45_000,
            nextPitchTravelTenths: 45_000,
            speedMode: .turbo50x
        ),
        "50x correction budget must accept its exact limits"
    )
    expect(
        !PersonTrackingTravelBudgetPolicy.allowsCorrection(
            nextYawTravelTenths: 45_001,
            nextPitchTravelTenths: 45_000,
            speedMode: .turbo50x
        ),
        "50x correction budget must reject travel above its yaw limit"
    )
    expect(
        !PersonTrackingTravelBudgetPolicy.allowsSearch(
            nextYawTravelTenths: 45_001,
            nextPitchTravelTenths: 0,
            speedMode: .turbo50x
        ),
        "50x search budget must share the same yaw limit"
    )
    expect(
        PersonTrackingSpeedSelectionPolicy.selection(
            storedRawValue: PersonTrackingSpeedMode.smooth.rawValue,
            storedProfileVersion: nil
        ) == PersonTrackingSpeedSelection(mode: .turbo50x, requiresWriteback: true),
        "pre-50x installs must migrate once"
    )
    expect(
        PersonTrackingSpeedSelectionPolicy.selection(
            storedRawValue: PersonTrackingSpeedMode.smooth.rawValue,
            storedProfileVersion: 1
        ) == PersonTrackingSpeedSelection(mode: .smooth, requiresWriteback: false),
        "a post-migration manual smooth choice must persist"
    )
    expect(
        PersonTrackingPolicy.minimumStopCooldown >= 0.12,
        "STOP must retain a dedicated minimum barrier"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 60, pitchTenths: 0),
            currentYawTenths: 1_150,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: 50, pitchTenths: 0),
        "an axial continuous step must decelerate exactly into the diamond boundary"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 65, pitchTenths: 0),
            currentYawTenths: 1_200,
            currentPitchTenths: 0
        ) == nil,
        "outward motion at the hard boundary must be rejected"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
            currentYawTenths: 1_200,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
        "inward motion at the hard boundary must remain available"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: -60, pitchTenths: 0),
            currentYawTenths: -1_150,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: -50, pitchTenths: 0),
        "negative travel must decelerate into the left hard boundary"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
            currentYawTenths: 1_150,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: 30, pitchTenths: 10),
        "a diagonal step must be clipped along its line into the verified diamond"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
            currentYawTenths: 1_200,
            currentPitchTenths: 0
        ) == nil,
        "a diagonal outward step at a cardinal boundary must be rejected"
    )

    expect(PersonSearchDirection.left.opposite == .right, "left opposite must be right")
    expect(PersonSearchDirection.right.opposite == .left, "right opposite must be left")
    expect(PersonSearchDirection.up.opposite == .down, "up opposite must be down")
    expect(PersonSearchDirection.down.opposite == .up, "down opposite must be up")
    expect(
        PersonSearchDirection.right.clockwise == .down
            && PersonSearchDirection.down.clockwise == .left
            && PersonSearchDirection.left.clockwise == .up
            && PersonSearchDirection.up.clockwise == .right,
        "clockwise scan cycle must cover all four directions"
    )
    expect(
        PersonSearchPolicy.coastStepTenths == 20
            && PersonSearchPolicy.coastDurationTenths == 1
            && PersonSearchPolicy.lossGraceStopCooldown == 0.12
            && PersonSearchPolicy.maximumCoastTravelTenths == 60,
        "coast policy constants mismatch"
    )
    expect(
        PersonSearchPolicy.scanStepTenths == 50
            && PersonSearchPolicy.scanDurationTenths == 1
            && PersonSearchPolicy.maximumScanEpisodeTravelTenths == 30_000
            && PersonSearchPolicy.maximumVisionSilence == 0.50,
        "scan policy bounds mismatch"
    )
    let rightExit = [
        PersonSearchObservation(centerX: 0.78, centerY: 0.5, confidence: 0.8),
        PersonSearchObservation(centerX: 0.83, centerY: 0.5, confidence: 0.8),
        PersonSearchObservation(centerX: 0.89, centerY: 0.5, confidence: 0.8),
    ]
    expect(
        PersonSearchPolicy.coastDirection(
            recentObservations: rightExit,
            lastCorrection: PersonTrackingCorrection(yawTenths: 10, pitchTenths: 0)
        ) == .right,
        "trusted right-edge motion must enable rightward coasting"
    )
    expect(
        PersonSearchPolicy.coastDirection(
            recentObservations: rightExit,
            lastCorrection: PersonTrackingCorrection(yawTenths: -10, pitchTenths: 0)
        ) == nil,
        "coasting must reject a visual and command direction mismatch"
    )
    let upExit = [
        PersonSearchObservation(centerX: 0.5, centerY: 0.21, confidence: 0.8),
        PersonSearchObservation(centerX: 0.5, centerY: 0.16, confidence: 0.8),
        PersonSearchObservation(centerX: 0.5, centerY: 0.10, confidence: 0.8),
    ]
    expect(
        PersonSearchPolicy.coastDirection(
            recentObservations: upExit,
            lastCorrection: PersonTrackingCorrection(yawTenths: 0, pitchTenths: -10)
        ) == .up,
        "trusted top-edge motion must enable upward coasting"
    )
    expect(
        PersonSearchPolicy.requestedStep(direction: .left, mode: .scan)
            == PersonTrackingCorrection(yawTenths: -50, pitchTenths: 0),
        "left scan step mismatch"
    )
    expect(
        PersonSearchPolicy.requestedStep(direction: .up, mode: .scan)
            == PersonTrackingCorrection(yawTenths: 0, pitchTenths: -50),
        "up scan step mismatch"
    )
    expect(
        PersonSearchPolicy.requestedStep(direction: .down, mode: .coast)
            == PersonTrackingCorrection(yawTenths: 0, pitchTenths: 20),
        "down coast step mismatch"
    )
    expect(
        abs(
            PersonSearchPolicy.latestFirstWriteUptime(
                requestedAtUptime: 10.2,
                mustFinishByUptime: 10.4,
                durationTenths: 1
            ) - 10.3
        ) < 0.000_001,
        "search packet admission must reserve its full action duration"
    )
    expect(
        PersonSearchPolicy.reachesEnvelopeBoundary(
            requested: PersonTrackingCorrection(yawTenths: 0, pitchTenths: 20),
            submitted: PersonTrackingCorrection(yawTenths: 0, pitchTenths: 5)
        ),
        "a clipped pitch search command must report its envelope boundary"
    )

    let identitySessionID = UUID()
    let identityLeft = PersonDetection(
        x: 0.15,
        y: 0.30,
        width: 0.20,
        height: 0.40,
        confidence: 0.9
    )
    let identityRight = PersonDetection(
        x: 0.65,
        y: 0.30,
        width: 0.20,
        height: 0.40,
        confidence: 0.9
    )
    let multiSample = PersonVisionSample(
        sessionID: identitySessionID,
        detections: [identityLeft, identityRight],
        selectedDetection: identityRight,
        sequence: 1,
        observedAtUptime: 20
    )
    expect(multiSample.detections.count == 2, "Vision sample must retain all people")
    expect(multiSample.detection == identityRight, "Vision sample must retain selected target")

    var identityTracker = PersonIdentityTracker()
    let identityFirst = identityTracker.update(
        detections: [identityLeft, identityRight],
        sequence: 1,
        observedAtUptime: 20
    )
    expect(identityFirst.personCount == 2, "identity tracker must count visible people")
    let identityLeftID = identityFirst.candidates[0].id
    let identityRightID = identityFirst.candidates[1].id
    let identityReordered = identityTracker.update(
        detections: [
            PersonDetection(
                x: 0.63,
                y: 0.30,
                width: 0.20,
                height: 0.40,
                confidence: 0.9
            ),
            PersonDetection(
                x: 0.17,
                y: 0.30,
                width: 0.20,
                height: 0.40,
                confidence: 0.9
            ),
        ],
        sequence: 2,
        observedAtUptime: 20.08
    )
    expect(
        identityReordered.candidates.map(\.id) == [identityLeftID, identityRightID],
        "geometric association must survive Vision result reordering"
    )
    expect(
        identityTracker.lockFirstVisibleCandidate() == identityLeftID,
        "the default lock must select the first displayed candidate"
    )
    expect(
        identityTracker.lockFirstVisibleCandidate() == nil,
        "the default lock must never replace an existing selection"
    )
    expect(identityTracker.lock(on: identityLeftID), "visible candidate must be lockable")
    let identityMissing = identityTracker.update(
        detections: [identityReordered.candidates[1].detection],
        sequence: 3,
        observedAtUptime: 20.16
    )
    expect(identityMissing.lockedID == identityLeftID, "missing target must retain its lock ID")
    expect(identityMissing.lockedDetection == nil, "another person must not replace locked target")
    expect(
        identityMissing.candidates.first?.id == identityRightID,
        "unlocked bystander identity must remain stable"
    )
    let identityAfterFlicker = identityTracker.update(
        detections: [identityReordered.candidates[1].detection, identityLeft],
        sequence: 4,
        observedAtUptime: 20.24
    )
    expect(
        identityAfterFlicker.lockedCandidate?.id == identityLeftID,
        "the same geometry must resolve the lock again within the flicker tolerance"
    )
    expect(
        !identityTracker.hasUnresolvedRetiredLock,
        "a lock resolved after a flicker must not be reported as retired"
    )

    var identitySequence: UInt64 = 5
    for step in 1...5 {
        _ = identityTracker.update(
            detections: [identityReordered.candidates[1].detection],
            sequence: identitySequence,
            observedAtUptime: 20.24 + Double(step) * 0.08
        )
        identitySequence += 1
    }
    expect(
        identityTracker.hasUnresolvedRetiredLock,
        "a target missing beyond the flicker tolerance must retire its lock"
    )
    let identityNearbyAfterRetirement = identityTracker.update(
        detections: [identityReordered.candidates[1].detection, identityLeft],
        sequence: identitySequence,
        observedAtUptime: 20.72
    )
    identitySequence += 1
    expect(
        identityNearbyAfterRetirement.lockedDetection == nil,
        "a rectangle near a retired target must not inherit the lock"
    )
    expect(
        !identityNearbyAfterRetirement.candidates.map(\.id).contains(identityLeftID),
        "a retired locked ID must stay unresolved until an explicit transfer"
    )
    let replacementLeft = identityNearbyAfterRetirement.candidates.first {
        abs($0.detection.centerX - identityLeft.centerX) < 0.001
    }
    expect(replacementLeft != nil, "returned target must be exposed as a new candidate")
    if let replacementLeft {
        expect(identityTracker.lock(on: replacementLeft.id), "new candidate must be selectable")
    }
    let identityAfterReselection = identityTracker.update(
        detections: [
            identityReordered.candidates[1].detection,
            PersonDetection(
                x: identityLeft.x + 0.01,
                y: identityLeft.y,
                width: identityLeft.width,
                height: identityLeft.height,
                confidence: identityLeft.confidence
            ),
        ],
        sequence: identitySequence,
        observedAtUptime: 20.80
    )
    expect(
        identityAfterReselection.lockedID == replacementLeft?.id
            && identityAfterReselection.lockedDetection != nil,
        "explicit reselection must remain stable on the following frame"
    )

    let lowerRight = PersonDetection(
        x: 0.85,
        y: 0.56,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    if let diagonal = PersonTrackingPolicy.correction(for: lowerRight) {
        expect(
            hypot(Double(diagonal.yawTenths), Double(diagonal.pitchTenths)) <= 65.1,
            "diagonal tracking step must stay within the 6.5 degree fast limit"
        )
    } else {
        expect(false, "large diagonal error must produce a correction")
    }

    let lease = PersonVisionSessionLease()
    expect(lease.withValidity { 7 } == 7, "active Vision lease must allow work")
    lease.revoke()
    expect(lease.withValidity { 9 } == nil, "revoked Vision lease must reject work")

    let referenceMotion = motionSignature()
    let horizontalMotion = GimbalMotionAnalysis.estimate(
        reference: referenceMotion,
        current: shifted(referenceMotion, dx: 5, dy: 0),
        axis: .horizontal
    )
    expect(
        horizontalMotion.axisShift == 5 && horizontalMotion.verdict == .moved,
        "camera motion analysis must detect horizontal translation"
    )
    let verticalMotion = GimbalMotionAnalysis.estimate(
        reference: referenceMotion,
        current: shifted(referenceMotion, dx: 0, dy: -4),
        axis: .vertical
    )
    expect(
        verticalMotion.axisShift == -4 && verticalMotion.verdict == .moved,
        "camera motion analysis must detect vertical translation"
    )
    let horizontalJointMotion = GimbalMotionAnalysis.estimateTranslation(
        reference: referenceMotion,
        current: shifted(referenceMotion, dx: 12, dy: 0)
    )
    expect(
        horizontalJointMotion.horizontal.axisShift == 12
            && horizontalJointMotion.horizontal.verdict == .moved,
        "joint camera motion analysis must detect a large horizontal translation"
    )
    expect(
        horizontalJointMotion.vertical.axisShift == 0
            && horizontalJointMotion.vertical.verdict == .noResponse,
        "joint camera motion analysis must compensate horizontal motion before checking vertical response"
    )
    let diagonalJointMotion = GimbalMotionAnalysis.estimateTranslation(
        reference: referenceMotion,
        current: shifted(referenceMotion, dx: 7, dy: -5)
    )
    expect(
        diagonalJointMotion.horizontal.axisShift == 7
            && diagonalJointMotion.horizontal.verdict == .moved
            && diagonalJointMotion.vertical.axisShift == -5
            && diagonalJointMotion.vertical.verdict == .moved,
        "coarse-to-fine camera motion analysis must refine odd-pixel diagonal translation"
    )
    let boundaryJointMotion = GimbalMotionAnalysis.estimateTranslation(
        reference: referenceMotion,
        current: shifted(referenceMotion, dx: 16, dy: -9)
    )
    expect(
        boundaryJointMotion.horizontal.axisShift == 16
            && boundaryJointMotion.horizontal.verdict == .moved
            && boundaryJointMotion.vertical.axisShift == -9
            && boundaryJointMotion.vertical.verdict == .moved,
        "coarse-to-fine camera motion analysis must include both search boundaries"
    )
    expect(
        GimbalMotionAnalysis.estimate(
            reference: referenceMotion,
            current: referenceMotion,
            axis: .horizontal
        ).verdict == .noResponse,
        "an unchanged textured frame must be classified as no response"
    )
    let stationaryJointMotion = GimbalMotionAnalysis.estimateTranslation(
        reference: referenceMotion,
        current: referenceMotion
    )
    expect(
        stationaryJointMotion.horizontal.verdict == .noResponse
            && stationaryJointMotion.vertical.verdict == .noResponse,
        "a joint unchanged textured frame must be no response on both axes"
    )
    let flatMotion = GimbalMotionSignature(
        width: 64,
        height: 36,
        luma: Array(repeating: 128, count: 64 * 36)
    )
    if case .inconclusive = GimbalMotionAnalysis.estimate(
        reference: flatMotion,
        current: flatMotion,
        axis: .horizontal
    ).verdict {
        expect(true, "low-texture frame rejected")
    } else {
        expect(false, "low-texture frame must not be accepted as a boundary response")
    }
    let occlusionWidth = 128
    let occlusionHeight = 72
    let periodicReferenceLuma = (0..<(occlusionWidth * occlusionHeight)).map {
        index -> UInt8 in
        let x = index % occlusionWidth
        let y = index / occlusionWidth
        let value = ((x % 20) * 9 + y * 17 + (y / 3) * 29) % 208
        return UInt8(24 + value)
    }
    let periodicReference = GimbalMotionSignature(
        width: occlusionWidth,
        height: occlusionHeight,
        luma: periodicReferenceLuma
    )
    var edgeOccludedLuma = periodicReferenceLuma
    for y in 0..<occlusionHeight {
        for x in 0..<20 {
            let index = y * occlusionWidth + x
            edgeOccludedLuma[index] = UInt8(255 - Int(edgeOccludedLuma[index]))
        }
    }
    let edgeOccluded = GimbalMotionSignature(
        width: occlusionWidth,
        height: occlusionHeight,
        luma: edgeOccludedLuma
    )
    let edgeOcclusionEstimate = GimbalMotionAnalysis.estimateTranslation(
        reference: periodicReference,
        current: edgeOccluded
    )
    expect(
        edgeOcclusionEstimate.horizontal.verdict != .moved,
        "a stable edge occlusion must not manufacture joint horizontal motion"
    )
    var centerOccludedLuma = periodicReferenceLuma
    for y in 0..<occlusionHeight {
        for x in 32..<52 {
            let index = y * occlusionWidth + x
            centerOccludedLuma[index] = UInt8(255 - Int(centerOccludedLuma[index]))
        }
    }
    let centerOccluded = GimbalMotionSignature(
        width: occlusionWidth,
        height: occlusionHeight,
        luma: centerOccludedLuma
    )
    let centerOcclusionEstimate = GimbalMotionAnalysis.estimateTranslation(
        reference: periodicReference,
        current: centerOccluded
    )
    expect(
        centerOcclusionEstimate.horizontal.verdict != .moved,
        "a stable central occlusion must fail reverse registration instead of faking motion"
    )
    if case let .inconclusive(reason) = centerOcclusionEstimate.horizontal.verdict {
        expect(
            reason.contains("双向"),
            "the central-occlusion regression must exercise bidirectional validation"
        )
    } else {
        expect(false, "central occlusion must remain explicitly inconclusive")
    }
    expect(
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: false,
            primaryVerdict: .inconclusive("scene changed"),
            orthogonalVerdict: .noResponse
        ) == .retryBeforeCommand,
        "only a pre-command disturbance may offer retry"
    )
    expect(
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: true,
            primaryVerdict: .noResponse,
            orthogonalVerdict: .noResponse
        ) == .awaitPhysicalNoMovementConfirmation,
        "post-command no-response must require physical no-movement confirmation"
    )
    expect(
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: true,
            primaryVerdict: .inconclusive("unknown"),
            orthogonalVerdict: .noResponse
        ) == .abortForUnknownPose,
        "post-command inconclusive motion must fail closed"
    )
    expect(
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: true,
            primaryVerdict: .moved,
            orthogonalVerdict: .moved
        ) == .abortForUnknownPose,
        "orthogonal post-command motion must fail closed"
    )
    expect(
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: true,
            primaryVerdict: .moved,
            orthogonalVerdict: .noResponse,
            reversesAcceptedDirection: true
        ) == .abortForUnknownPose,
        "reverse post-command motion must fail closed"
    )
    expect(
        GimbalRangeCalibrationSafetyPolicy.disposition(
            commandWasSent: true,
            primaryVerdict: .moved,
            orthogonalVerdict: .noResponse,
            shiftBelowExpected: true
        ) == .abortForUnknownPose,
        "partial post-command motion must fail closed"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: .awaitMovedStepConfirmation,
            transientVisualUncertainty: false,
            observationAttempt: 1
        ) == .acceptMovedStep,
        "clean camera-verified motion may advance without another click"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: .awaitPhysicalNoMovementConfirmation,
            transientVisualUncertainty: false,
            observationAttempt: 1
        ) == .requestNoMovementConfirmation,
        "a clean no-response must still ask for physical boundary confirmation"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: .abortForUnknownPose,
            transientVisualUncertainty: true,
            observationAttempt: 1
        ) == .resampleObservation,
        "transient post-command vision uncertainty may only resample"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: .abortForUnknownPose,
            transientVisualUncertainty: true,
            observationAttempt: 3
        ) == .pauseForManualRecovery,
        "post-command resampling must stop at its fixed budget"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: .abortForUnknownPose,
            transientVisualUncertainty: false,
            observationAttempt: 1
        ) == .pauseForManualRecovery,
        "geometric conflicts must never trigger automatic motion recovery"
    )
    expect(
        GimbalRangeCalibrationRecoveryPolicy.action(
            stopAccepted: true,
            sessionsAreValid: true
        ) == .pauseForManualRecovery,
        "accepted STOP with live leases must preserve manual recovery"
    )
    expect(
        GimbalRangeCalibrationRecoveryPolicy.action(
            stopAccepted: false,
            sessionsAreValid: true
        ) == .terminate,
        "rejected STOP must terminate calibration"
    )
    expect(
        GimbalRangeCalibrationRecoveryPolicy.action(
            stopAccepted: true,
            sessionsAreValid: false
        ) == .terminate,
        "invalid leases must terminate calibration even after STOP submission"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
            primaryVerdict: .inconclusive("exposure"),
            orthogonalVerdict: .noResponse,
            reversesAcceptedDirection: false,
            shiftBelowExpected: false
        ),
        "visual-only inconclusive evidence may consume a resample"
    )
    expect(
        !GimbalRangeCalibrationAutomationPolicy.isTransientVisualUncertainty(
            primaryVerdict: .inconclusive("unknown"),
            orthogonalVerdict: .moved,
            reversesAcceptedDirection: false,
            shiftBelowExpected: false
        ),
        "orthogonal motion must never be classified as transient"
    )
    let automaticMovedEstimate = GimbalMotionEstimate(
        axisShift: 12,
        zeroError: 0.20,
        bestError: 0.03,
        confidence: 0.80,
        verdict: .moved
    )
    let automaticStationaryEstimate = GimbalMotionEstimate(
        axisShift: 0,
        zeroError: 0.01,
        bestError: 0.01,
        confidence: 0.85,
        verdict: .noResponse
    )
    expect(
        GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
            primary: automaticMovedEstimate,
            orthogonal: automaticStationaryEstimate,
            axis: .horizontal
        ),
        "automatic moved evidence must pass the strict quality gate"
    )
    expect(
        !GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
            primary: GimbalMotionEstimate(
                axisShift: 31,
                zeroError: 0.20,
                bestError: 0.03,
                confidence: 0.80,
                verdict: .moved
            ),
            orthogonal: automaticStationaryEstimate,
            axis: .horizontal
        ),
        "a shift near the search boundary must not authorize automatic motion"
    )
    expect(
        !GimbalRangeCalibrationAutomaticEvidencePolicy.isReliableMoved(
            primary: GimbalMotionEstimate(
                axisShift: 17,
                zeroError: 0.20,
                bestError: 0.03,
                confidence: 0.80,
                verdict: .moved
            ),
            orthogonal: automaticStationaryEstimate,
            axis: .vertical
        ),
        "a vertical fit within two pixels of the search edge must be rejected"
    )
    expect(
        GimbalRangeCalibrationAutomaticEvidencePolicy
            .movedObservationsAreConsistent(
                automaticMovedEstimate,
                GimbalMotionEstimate(
                    axisShift: 13,
                    zeroError: 0.19,
                    bestError: 0.03,
                    confidence: 0.82,
                    verdict: .moved
                )
            ),
        "two same-direction moved observations within one pixel are consistent"
    )
    expect(
        !GimbalRangeCalibrationAutomaticEvidencePolicy
            .movedObservationsAreConsistent(
                automaticMovedEstimate,
                GimbalMotionEstimate(
                    axisShift: -12,
                    zeroError: 0.19,
                    bestError: 0.03,
                    confidence: 0.82,
                    verdict: .moved
                )
            ),
        "opposite moved observations must never authorize automatic bookkeeping"
    )
    expect(
        GimbalRangeCalibrationAutomationPolicy.postCommandAction(
            disposition: .abortForUnknownPose,
            transientVisualUncertainty: true,
            observationAttempt: 0
        ) == .pauseForManualRecovery,
        "invalid observation attempt zero must fail closed"
    )
    expect(
        GimbalRangeCalibrationRecoveryPolicy.action(
            stopAccepted: false,
            sessionsAreValid: false
        ) == .terminate,
        "rejected STOP with invalid leases must terminate"
    )
    do {
        _ = try OM3Protocol.rotationMessage(yawTenths: 40_000, pitchTenths: 0)
        expect(false, "out-of-range yaw must fail")
    } catch OM3ProtocolError.valueOutOfRange("yaw") {
        expect(true, "out-of-range yaw rejected")
    }
} catch {
    fputs("FAIL: unexpected protocol error: \(error)\n", stderr)
    exit(1)
}

print("OM3 protocol self-test passed (\(assertions) assertions).")
