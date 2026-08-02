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

    let centered = PersonDetection(
        x: 0.4,
        y: 0.3,
        width: 0.2,
        height: 0.4,
        confidence: 0.9
    )
    expect(PersonTrackingPolicy.correction(for: centered) == nil, "dead-zone must suppress motion")

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
    expect(
        PersonTrackingPolicy.minimumStopCooldown >= 0.12,
        "STOP must retain a dedicated minimum barrier"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 60, pitchTenths: 0),
            currentYawTenths: 400,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: 50, pitchTenths: 0),
        "an axial continuous step must decelerate exactly into the diamond boundary"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 65, pitchTenths: 0),
            currentYawTenths: 450,
            currentPitchTenths: 0
        ) == nil,
        "outward motion at the hard boundary must be rejected"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
            currentYawTenths: 450,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: -65, pitchTenths: 0),
        "inward motion at the hard boundary must remain available"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: -60, pitchTenths: 0),
            currentYawTenths: -400,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: -50, pitchTenths: 0),
        "negative travel must decelerate into the left hard boundary"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
            currentYawTenths: 400,
            currentPitchTenths: 0
        ) == PersonTrackingCorrection(yawTenths: 25, pitchTenths: 8),
        "a diagonal step must be clipped along its line into the verified diamond"
    )
    expect(
        PersonTrackingPolicy.correctionClampedToNetSafetyBoundary(
            PersonTrackingCorrection(yawTenths: 60, pitchTenths: 20),
            currentYawTenths: 450,
            currentPitchTenths: 0
        ) == nil,
        "a diagonal outward step at a cardinal boundary must be rejected"
    )

    expect(PersonSearchDirection.left.rawValue == -1, "left search direction must be -1")
    expect(PersonSearchDirection.right.rawValue == 1, "right search direction must be 1")
    expect(PersonSearchDirection.left.opposite == .right, "left opposite must be right")
    expect(PersonSearchDirection.right.opposite == .left, "right opposite must be left")
    expect(
        PersonSearchPolicy.coastStepTenths == 10
            && PersonSearchPolicy.coastDurationTenths == 1
            && PersonSearchPolicy.lossGraceStopCooldown == 0.12
            && PersonSearchPolicy.maximumCoastTravelTenths == 20,
        "coast policy constants mismatch"
    )
    expect(
        PersonSearchPolicy.scanSoftYawLimitTenths == 200
            && PersonSearchPolicy.scanStepTenths == 20
            && PersonSearchPolicy.maximumScanEpisodeTravelTenths == 600
            && PersonSearchPolicy.maximumVisionSilence == 0.50,
        "scan policy bounds mismatch"
    )
    expect(
        PersonSearchPolicy.coastDirection(
            recentCenterXs: [0.78, 0.83, 0.89],
            lastConfidence: 0.8,
            lastYawTenths: 10
        ) == .right,
        "trusted right-edge motion must enable rightward coasting"
    )
    expect(
        PersonSearchPolicy.coastDirection(
            recentCenterXs: [0.78, 0.83, 0.89],
            lastConfidence: 0.8,
            lastYawTenths: -10
        ) == nil,
        "coasting must reject a visual and command direction mismatch"
    )
    expect(
        PersonSearchPolicy.coastDirection(
            recentCenterXs: [0.80, 0.86, 0.84, 0.89],
            lastConfidence: 0.8,
            lastYawTenths: 10
        ) == nil,
        "coasting must reject a non-monotonic exit trajectory"
    )
    expect(
        PersonSearchPolicy.scanStep(currentYawTenths: 0, direction: .left)
            == PersonSearchStep(yawTenths: -20, reachesSoftBoundary: false),
        "left scan step mismatch"
    )
    expect(
        PersonSearchPolicy.scanStep(currentYawTenths: -190, direction: .left)
            == PersonSearchStep(yawTenths: -10, reachesSoftBoundary: true),
        "left scan must clamp at its soft boundary"
    )
    expect(
        PersonSearchPolicy.coastStep(currentYawTenths: 195, direction: .right)
            == PersonSearchStep(yawTenths: 5, reachesSoftBoundary: true),
        "coasting must clamp at the scan soft boundary"
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
        PersonSearchPolicy.scanStep(currentYawTenths: -200, direction: .left) == nil,
        "scan must stop at its selected soft boundary"
    )
    expect(
        PersonSearchPolicy.scanStep(currentYawTenths: 250, direction: .left)
            == PersonSearchStep(yawTenths: -20, reachesSoftBoundary: false),
        "out-of-range scan must permit a step toward zero"
    )
    expect(
        PersonSearchPolicy.scanStep(currentYawTenths: 250, direction: .right) == nil,
        "out-of-range scan must reject motion farther from zero"
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
    expect(
        GimbalMotionAnalysis.estimate(
            reference: referenceMotion,
            current: referenceMotion,
            axis: .horizontal
        ).verdict == .noResponse,
        "an unchanged textured frame must be classified as no response"
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
