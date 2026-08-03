import Foundation

/// DJI's published OM3 structure ranges and the App's absolute calibration
/// ceilings. The published values describe the bare mechanism around DJI's
/// reference zero; they do not prove that a particular payload, cable routing,
/// or manually chosen origin can use the whole range safely.
enum OM3HardwareMotionLimits {
    enum Direction: CaseIterable, Hashable, Sendable {
        case left
        case right
        case up
        case down

        var isYaw: Bool {
            switch self {
            case .left, .right: return true
            case .up, .down: return false
            }
        }
    }

    struct DirectionalDegrees: Equatable, Sendable {
        let left: Double
        let right: Double
        let up: Double
        let down: Double

        func value(for direction: Direction) -> Double {
            switch direction {
            case .left: return left
            case .right: return right
            case .up: return up
            case .down: return down
            }
        }
    }

    struct DirectionalWholeDegrees: Equatable, Sendable {
        let left: Int
        let right: Int
        let up: Int
        let down: Int

        func value(for direction: Direction) -> Int {
            switch direction {
            case .left: return left
            case .right: return right
            case .up: return up
            case .down: return down
            }
        }
    }

    /// DJI OM3 published structure ranges. These are sanity ceilings only, not
    /// targets that an unattended calibration is allowed to touch.
    static let structuralCeilingDegrees = DirectionalDegrees(
        left: 162.5,
        right: 170.3,
        up: 104.5,
        down: 235.7
    )
    static let maximumControllableSpeedDegreesPerSecond = 120.0
    static let maximumControllableSpeedTenthsPerSecond = 1_200

    static let yawProbeStepDegrees = 5
    static let pitchProbeStepDegrees = 2

    /// Keep calibration itself away from the published structural endpoint.
    /// These reserves are deliberately separate from the margin later removed
    /// from a verified result: the first protects the probe, the second protects
    /// normal tracking. Using the existing 10°/6° operational margins here gives
    /// every direction several degrees of approach room before alignment.
    static let mechanicalEndpointReserveDegrees = DirectionalDegrees(
        left: 10,
        right: 10,
        up: 6,
        down: 6
    )

    static let trackingYawSafetyMarginDegrees = 10
    static let trackingPitchSafetyMarginDegrees = 6

    /// Largest whole probe step no closer to the published endpoint than the
    /// mechanical reserve. The asymmetric result is intentional:
    /// left 150°, right 160°, up 98°, down 228°.
    static let probeCapsDegrees = DirectionalWholeDegrees(
        left: alignedProbeCap(for: .left),
        right: alignedProbeCap(for: .right),
        up: alignedProbeCap(for: .up),
        down: alignedProbeCap(for: .down)
    )

    /// Maximum envelope that calibration can produce after subtracting the
    /// tracking margin: left 140°, right 150°, up 92°, down 222°.
    static let maximumCalibratedEnvelopeDegrees = DirectionalWholeDegrees(
        left: probeCapsDegrees.left - trackingYawSafetyMarginDegrees,
        right: probeCapsDegrees.right - trackingYawSafetyMarginDegrees,
        up: probeCapsDegrees.up - trackingPitchSafetyMarginDegrees,
        down: probeCapsDegrees.down - trackingPitchSafetyMarginDegrees
    )

    /// Working range used only after the operator confirms a centered origin
    /// but has not run this installation's four-direction calibration. It is
    /// intentionally symmetric and stays at least 42.5° inside the smaller
    /// published Pan side and 44.5° inside the smaller Tilt side. Calibration
    /// replaces it with the measured asymmetric envelope.
    static let centeredFallbackEnvelopeDegrees = DirectionalWholeDegrees(
        left: 120,
        right: 120,
        up: 60,
        down: 60
    )

    static let centeredFallbackTrackingEnvelope = GimbalTrackingEnvelope(
        leftYawTenths: centeredFallbackEnvelopeDegrees.left * 10,
        rightYawTenths: centeredFallbackEnvelopeDegrees.right * 10,
        upPitchTenths: centeredFallbackEnvelopeDegrees.up * 10,
        downPitchTenths: centeredFallbackEnvelopeDegrees.down * 10
    )

    static func probeCapDegrees(for direction: Direction) -> Int {
        probeCapsDegrees.value(for: direction)
    }

    /// Single validation authority for a four-direction calibrated envelope.
    /// Callers must still prove the current tracking origin; passing this check
    /// only establishes that values cannot exceed the App's OM3 sanity ceiling.
    static func isValidCalibratedTrackingEnvelope(
        _ envelope: GimbalTrackingEnvelope
    ) -> Bool {
        envelope.leftYawTenths > 0
            && envelope.rightYawTenths > 0
            && envelope.upPitchTenths > 0
            && envelope.downPitchTenths > 0
            && envelope.leftYawTenths
                <= maximumCalibratedEnvelopeDegrees.left * 10
            && envelope.rightYawTenths
                <= maximumCalibratedEnvelopeDegrees.right * 10
            && envelope.upPitchTenths
                <= maximumCalibratedEnvelopeDegrees.up * 10
            && envelope.downPitchTenths
                <= maximumCalibratedEnvelopeDegrees.down * 10
    }

    static func probeStepDegrees(for direction: Direction) -> Int {
        direction.isYaw ? yawProbeStepDegrees : pitchProbeStepDegrees
    }

    /// Final two-axis magnitude allowed for a command of the given declared
    /// duration. This is a speed cap, not a travel envelope.
    static func maximumCombinedCommandTenths(durationTenths: UInt8) -> Int {
        Int(durationTenths) * maximumControllableSpeedTenthsPerSecond / 10
    }

    /// Absolute sanity check around the explicitly confirmed origin. Normal
    /// tracking is always constrained by a smaller diamond; this rectangular
    /// check is the final defense against an invalid envelope or ledger.
    static func isWithinStructuralSanityCeiling(
        yawTenths: Int,
        pitchTenths: Int
    ) -> Bool {
        yawTenths >= -Int(structuralCeilingDegrees.left * 10)
            && yawTenths <= Int(structuralCeilingDegrees.right * 10)
            && pitchTenths >= -Int(structuralCeilingDegrees.up * 10)
            && pitchTenths <= Int(structuralCeilingDegrees.down * 10)
    }

    private static func alignedProbeCap(for direction: Direction) -> Int {
        let available = structuralCeilingDegrees.value(for: direction)
            - mechanicalEndpointReserveDegrees.value(for: direction)
        let step = probeStepDegrees(for: direction)
        return max(0, Int(floor(available / Double(step))) * step)
    }
}
