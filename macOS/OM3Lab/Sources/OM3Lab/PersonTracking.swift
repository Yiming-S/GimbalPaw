import Foundation

/// A shared, atomically revocable lease for one Vision tracking generation.
/// Holding the lease while submitting a BLE correction gives camera revocation
/// and motion submission an explicit order across their different queues.
final class PersonVisionSessionLease: @unchecked Sendable {
    let id = UUID()

    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func revoke() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    func withValidity<Result>(_ operation: () -> Result) -> Result? {
        lock.lock()
        guard valid else {
            lock.unlock()
            return nil
        }
        defer { lock.unlock() }
        return operation()
    }
}

/// A normalized person rectangle using a top-left coordinate origin.
struct PersonDetection: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Float

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }
}

/// Which stage produced a vision sample. Detector samples carry the full
/// candidate set and drive identity, acquisition, and loss handling; tracker
/// samples are full-frame-rate position updates for the already locked target
/// and never make identity decisions.
enum PersonVisionSampleOrigin: Equatable, Sendable {
    case detector
    case tracker
}

struct PersonVisionSample: Equatable, Sendable {
    let sessionID: UUID
    let detection: PersonDetection?
    /// All raw person detections observed in this frame. `detection` remains the
    /// currently selected target for compatibility with the single-person
    /// tracking pipeline.
    let detections: [PersonDetection]
    let sequence: UInt64
    let observedAtUptime: TimeInterval
    let origin: PersonVisionSampleOrigin

    init(
        sessionID: UUID,
        detection: PersonDetection?,
        sequence: UInt64,
        observedAtUptime: TimeInterval,
        origin: PersonVisionSampleOrigin = .detector
    ) {
        self.sessionID = sessionID
        self.detection = detection
        detections = detection.map { [$0] } ?? []
        self.sequence = sequence
        self.observedAtUptime = observedAtUptime
        self.origin = origin
    }

    init(
        sessionID: UUID,
        detections: [PersonDetection],
        selectedDetection: PersonDetection? = nil,
        sequence: UInt64,
        observedAtUptime: TimeInterval,
        origin: PersonVisionSampleOrigin = .detector
    ) {
        self.sessionID = sessionID
        detection = selectedDetection
        self.detections = detections
        self.sequence = sequence
        self.observedAtUptime = observedAtUptime
        self.origin = origin
    }
}

struct PersonCandidateID:
    Hashable,
    Comparable,
    Identifiable,
    Sendable,
    CustomStringConvertible
{
    let rawValue: UInt64

    var id: PersonCandidateID { self }
    var title: String { "人物 \(rawValue)" }
    var description: String { title }

    static func < (lhs: PersonCandidateID, rhs: PersonCandidateID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One visible person with an ID that remains stable while detections can be
/// geometrically associated across frames.
struct PersonCandidate: Identifiable, Equatable, Sendable {
    let id: PersonCandidateID
    let detection: PersonDetection
    let firstSeenSequence: UInt64
    let lastSeenSequence: UInt64
    let observationCount: Int
}

struct PersonIdentitySnapshot: Equatable, Sendable {
    let candidates: [PersonCandidate]
    let lockedID: PersonCandidateID?

    var visibleCandidates: [PersonCandidate] { candidates }
    var personCount: Int { candidates.count }
    var lockedCandidate: PersonCandidate? {
        guard let lockedID else { return nil }
        return candidates.first { $0.id == lockedID }
    }
    var lockedDetection: PersonDetection? { lockedCandidate?.detection }
    var isLockedTargetVisible: Bool { lockedCandidate != nil }
}

/// Pure geometry policy used by `PersonIdentityTracker`. The tracker deliberately
/// does not use clothing or face recognition, so a long-disappeared target must
/// be selected again instead of silently assigning the lock to a different person.
enum PersonIdentityAssociationPolicy {
    static let minimumIntersectionOverUnion = 0.08
    static let maximumCenterDistance = 0.24
    static let maximumMissingDuration: TimeInterval = 0.80
    static let maximumConsecutiveMisses = 10
    /// The locked track tolerates only a short detector flicker before its
    /// geometry retires. Both bounds stay below the coordinator's lost timeout
    /// so a search episode always starts against a fully retired lock, and a
    /// long-disappeared target still cannot be inherited near its old position.
    static let lockedMaximumMissingDuration: TimeInterval = 0.35
    static let lockedMaximumConsecutiveMisses = 3

    static func intersectionOverUnion(
        _ lhs: PersonDetection,
        _ rhs: PersonDetection
    ) -> Double {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
        return union > 0 ? intersection / union : 0
    }

    static func centerDistance(_ lhs: PersonDetection, _ rhs: PersonDetection) -> Double {
        hypot(lhs.centerX - rhs.centerX, lhs.centerY - rhs.centerY)
    }

    static func associationScore(
        candidate: PersonDetection,
        previous: PersonDetection
    ) -> Double? {
        let overlap = intersectionOverUnion(candidate, previous)
        let distance = centerDistance(candidate, previous)
        guard overlap >= minimumIntersectionOverUnion
                || distance <= maximumCenterDistance
        else { return nil }

        let proximity = max(0, 1 - distance / maximumCenterDistance)
        return overlap * 0.70 + proximity * 0.30
    }
}

/// Associates multiple person rectangles across frames and owns the explicit
/// target lock. It never falls back to another visible candidate while a lock
/// exists. After one explicit miss, the old geometry is retired and the lock
/// remains unresolved until the caller explicitly selects another candidate.
struct PersonIdentityTracker: Sendable {
    private struct Track: Sendable {
        var detection: PersonDetection
        let firstSeenSequence: UInt64
        var lastSeenSequence: UInt64
        var observationCount: Int
        var consecutiveMisses: Int
        var lastSeenAtUptime: TimeInterval
    }

    private struct Match: Sendable {
        let trackID: PersonCandidateID
        let detectionIndex: Int
        let score: Double
        let distance: Double
    }

    private var tracks: [PersonCandidateID: Track] = [:]
    private var visibleCandidates: [PersonCandidate] = []
    private var nextRawID: UInt64 = 1

    private(set) var lockedID: PersonCandidateID?

    var currentSnapshot: PersonIdentitySnapshot {
        PersonIdentitySnapshot(candidates: visibleCandidates, lockedID: lockedID)
    }

    /// True when an explicit lock exists but its track has retired, so no
    /// visible candidate can resolve it anymore. Resuming motion then requires
    /// an explicit lock transfer: a user tap, or the coordinator's
    /// single-candidate reacquisition.
    var hasUnresolvedRetiredLock: Bool {
        guard let lockedID else { return false }
        return tracks[lockedID] == nil
    }

    @discardableResult
    mutating func update(
        detections: [PersonDetection],
        sequence: UInt64,
        observedAtUptime: TimeInterval
    ) -> PersonIdentitySnapshot {
        expireStaleTracks(at: observedAtUptime)
        // Enforced before matching as well, so a locked track that is already
        // beyond the flicker tolerance cannot be claimed across a frame gap.
        retireLockedTrackIfBeyondFlickerTolerance(at: observedAtUptime)

        let validDetections = detections.enumerated().filter {
            Self.isValid($0.element)
        }
        let matches = rankedMatches(for: validDetections)
        var matchedTrackIDs = Set<PersonCandidateID>()
        var matchedDetectionIndices = Set<Int>()
        var detectionIDs: [Int: PersonCandidateID] = [:]

        for match in matches {
            guard !matchedTrackIDs.contains(match.trackID),
                  !matchedDetectionIndices.contains(match.detectionIndex),
                  let detection = validDetections.first(where: {
                      $0.offset == match.detectionIndex
                  })?.element,
                  var track = tracks[match.trackID]
            else { continue }

            track.detection = detection
            track.lastSeenSequence = sequence
            track.observationCount += 1
            track.consecutiveMisses = 0
            track.lastSeenAtUptime = observedAtUptime
            tracks[match.trackID] = track
            matchedTrackIDs.insert(match.trackID)
            matchedDetectionIndices.insert(match.detectionIndex)
            detectionIDs[match.detectionIndex] = match.trackID
        }

        for trackID in Array(tracks.keys) where !matchedTrackIDs.contains(trackID) {
            tracks[trackID]?.consecutiveMisses += 1
        }
        // The lock itself remains as an unresolved user choice once its track
        // retires: the old geometry must never compete with a newly selected
        // replacement track, and a bystander must not inherit the locked ID on
        // a later frame. Within the short flicker tolerance, however, the same
        // geometry may re-associate so single-frame Vision misses do not drop
        // the lock.
        retireLockedTrackIfBeyondFlickerTolerance(at: observedAtUptime)

        let unmatchedDetections = validDetections
            .filter { !matchedDetectionIndices.contains($0.offset) }
            .sorted(by: Self.detectionOrder)
        for item in unmatchedDetections {
            let id = allocateID()
            tracks[id] = Track(
                detection: item.element,
                firstSeenSequence: sequence,
                lastSeenSequence: sequence,
                observationCount: 1,
                consecutiveMisses: 0,
                lastSeenAtUptime: observedAtUptime
            )
            detectionIDs[item.offset] = id
        }

        visibleCandidates = validDetections.compactMap { item in
            guard let id = detectionIDs[item.offset], let track = tracks[id] else { return nil }
            return PersonCandidate(
                id: id,
                detection: item.element,
                firstSeenSequence: track.firstSeenSequence,
                lastSeenSequence: track.lastSeenSequence,
                observationCount: track.observationCount
            )
        }
        .sorted(by: Self.candidateOrder)

        expireStaleTracks(at: observedAtUptime)
        return currentSnapshot
    }

    /// Locks only a currently visible candidate. A failed request leaves an
    /// existing lock unchanged.
    @discardableResult
    mutating func lock(on candidateID: PersonCandidateID) -> Bool {
        guard visibleCandidates.contains(where: { $0.id == candidateID }) else {
            return false
        }
        lockedID = candidateID
        return true
    }

    /// Locks the first candidate in the same deterministic order presented by
    /// the UI (left-to-right, then top-to-bottom). Existing locks are never
    /// replaced, so this is safe to use only for the initial default choice.
    @discardableResult
    mutating func lockFirstVisibleCandidate() -> PersonCandidateID? {
        guard lockedID == nil, let first = visibleCandidates.first else { return nil }
        lockedID = first.id
        return first.id
    }

    mutating func clearLock() {
        lockedID = nil
    }

    mutating func reset() {
        tracks.removeAll(keepingCapacity: true)
        visibleCandidates.removeAll(keepingCapacity: true)
        lockedID = nil
        nextRawID = 1
    }

    private mutating func allocateID() -> PersonCandidateID {
        let id = PersonCandidateID(rawValue: nextRawID)
        nextRawID &+= 1
        if nextRawID == 0 {
            nextRawID = 1
        }
        return id
    }

    private mutating func retireLockedTrackIfBeyondFlickerTolerance(
        at observedAtUptime: TimeInterval
    ) {
        guard let lockedID,
              let track = tracks[lockedID],
              track.consecutiveMisses > 0
        else { return }
        let missingDuration = max(0, observedAtUptime - track.lastSeenAtUptime)
        if track.consecutiveMisses
            > PersonIdentityAssociationPolicy.lockedMaximumConsecutiveMisses
            || missingDuration
            > PersonIdentityAssociationPolicy.lockedMaximumMissingDuration {
            tracks.removeValue(forKey: lockedID)
        }
    }

    private mutating func expireStaleTracks(at observedAtUptime: TimeInterval) {
        let expired = tracks.compactMap { id, track -> PersonCandidateID? in
            let missingDuration = max(0, observedAtUptime - track.lastSeenAtUptime)
            guard missingDuration > PersonIdentityAssociationPolicy.maximumMissingDuration
                    || track.consecutiveMisses
                        > PersonIdentityAssociationPolicy.maximumConsecutiveMisses
            else { return nil }
            return id
        }
        for id in expired {
            tracks.removeValue(forKey: id)
        }
    }

    private func rankedMatches(
        for detections: [(offset: Int, element: PersonDetection)]
    ) -> [Match] {
        var matches: [Match] = []
        for (trackID, track) in tracks {
            for detection in detections {
                guard let score = PersonIdentityAssociationPolicy.associationScore(
                    candidate: detection.element,
                    previous: track.detection
                ) else { continue }
                matches.append(
                    Match(
                        trackID: trackID,
                        detectionIndex: detection.offset,
                        score: score,
                        distance: PersonIdentityAssociationPolicy.centerDistance(
                            detection.element,
                            track.detection
                        )
                    )
                )
            }
        }
        return matches.sorted {
            if abs($0.score - $1.score) > 0.000_001 { return $0.score > $1.score }
            if abs($0.distance - $1.distance) > 0.000_001 {
                return $0.distance < $1.distance
            }
            if $0.trackID != $1.trackID { return $0.trackID < $1.trackID }
            return $0.detectionIndex < $1.detectionIndex
        }
    }

    private static func isValid(_ detection: PersonDetection) -> Bool {
        detection.x.isFinite
            && detection.y.isFinite
            && detection.width.isFinite
            && detection.height.isFinite
            && detection.width > 0
            && detection.height > 0
            && detection.confidence.isFinite
    }

    private static func detectionOrder(
        _ lhs: (offset: Int, element: PersonDetection),
        _ rhs: (offset: Int, element: PersonDetection)
    ) -> Bool {
        if abs(lhs.element.centerX - rhs.element.centerX) > 0.000_001 {
            return lhs.element.centerX < rhs.element.centerX
        }
        if abs(lhs.element.centerY - rhs.element.centerY) > 0.000_001 {
            return lhs.element.centerY < rhs.element.centerY
        }
        return lhs.offset < rhs.offset
    }

    private static func candidateOrder(_ lhs: PersonCandidate, _ rhs: PersonCandidate) -> Bool {
        if abs(lhs.detection.centerX - rhs.detection.centerX) > 0.000_001 {
            return lhs.detection.centerX < rhs.detection.centerX
        }
        if abs(lhs.detection.centerY - rhs.detection.centerY) > 0.000_001 {
            return lhs.detection.centerY < rhs.detection.centerY
        }
        return lhs.id < rhs.id
    }
}

struct PersonTrackingCorrection: Equatable, Sendable {
    let yawTenths: Int
    let pitchTenths: Int

    var isZero: Bool { yawTenths == 0 && pitchTenths == 0 }
}

/// One Euro filter (Casiez, Roussel, Vogel 2012): a low-pass filter whose
/// cutoff rises with the signal's speed. Slow targets get heavy smoothing so
/// detector jitter never reaches the gimbal; fast targets get light smoothing
/// so filtering does not add visible lag. Its smoothed derivative doubles as
/// the velocity estimate used for predictive aiming.
struct OneEuroFilter: Equatable, Sendable {
    let minimumCutoff: Double
    let beta: Double
    let derivativeCutoff: Double

    private(set) var value: Double?
    private(set) var velocity: Double = 0
    private var lastRaw: Double?
    private var lastTime: TimeInterval?

    init(minimumCutoff: Double, beta: Double, derivativeCutoff: Double) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    @discardableResult
    mutating func filter(_ raw: Double, at time: TimeInterval) -> Double {
        guard let previousValue = value,
              let previousRaw = lastRaw,
              let previousTime = lastTime,
              time > previousTime
        else {
            value = raw
            velocity = 0
            lastRaw = raw
            lastTime = time
            return raw
        }
        let interval = time - previousTime
        // The derivative is taken on the raw signal, not on the filtered
        // estimate as in the canonical formulation: this velocity also feeds
        // the predictive aim, where the catch-up bias of the filtered-value
        // difference would systematically overshoot on a moving target.
        let rawVelocity = (raw - previousRaw) / interval
        let velocityAlpha = Self.smoothingFactor(
            cutoff: derivativeCutoff,
            interval: interval
        )
        velocity += velocityAlpha * (rawVelocity - velocity)
        let cutoff = minimumCutoff + beta * abs(velocity)
        let alpha = Self.smoothingFactor(cutoff: cutoff, interval: interval)
        let filtered = previousValue + alpha * (raw - previousValue)
        value = filtered
        lastRaw = raw
        lastTime = time
        return filtered
    }

    mutating func reset() {
        value = nil
        velocity = 0
        lastRaw = nil
        lastTime = nil
    }

    private static func smoothingFactor(
        cutoff: Double,
        interval: TimeInterval
    ) -> Double {
        let timeConstant = 1.0 / (2.0 * Double.pi * max(cutoff, 0.000_001))
        return 1.0 / (1.0 + timeConstant / interval)
    }
}

/// Per-axis dead-zone hysteresis state. An axis leaves the centered regime
/// only past the outer dead zone and re-enters it only inside the smaller
/// inner zone, so a target hovering at the boundary cannot toggle the gimbal
/// between correcting and stopping.
struct PersonTrackingCenteringState: Equatable, Sendable {
    var yawCentered: Bool
    var pitchCentered: Bool

    static let uncentered = PersonTrackingCenteringState(
        yawCentered: false,
        pitchCentered: false
    )
    static let centered = PersonTrackingCenteringState(
        yawCentered: true,
        pitchCentered: true
    )

    var isFullyCentered: Bool { yawCentered && pitchCentered }
}

/// The outcome of one control cycle. `correction == nil` means either both
/// axes are centered (check `centering`) or a minor direction reversal was
/// absorbed for one cycle; `requiresReversalStop` requests the full
/// STOP-and-pause path for a significant reversal.
struct PersonTrackingControlDecision: Equatable, Sendable {
    let correction: PersonTrackingCorrection?
    let centering: PersonTrackingCenteringState
    let requiresReversalStop: Bool
}

/// A four-direction travel envelope measured relative to the pose where tracking
/// starts. Calibration verifies the four cardinal directions, not every diagonal,
/// so the usable two-axis region is their conservative diamond rather than the
/// larger rectangle implied by treating both axes independently.
struct GimbalTrackingEnvelope: Equatable, Sendable {
    enum Direction: Sendable {
        case left
        case right
        case up
        case down
    }

    let leftYawTenths: Int
    let rightYawTenths: Int
    let upPitchTenths: Int
    let downPitchTenths: Int

    static let conservativeDefault = GimbalTrackingEnvelope(
        leftYawTenths: 450,
        rightYawTenths: 450,
        upPitchTenths: 150,
        downPitchTenths: 150
    )

    init(
        leftYawTenths: Int,
        rightYawTenths: Int,
        upPitchTenths: Int,
        downPitchTenths: Int
    ) {
        precondition(leftYawTenths > 0, "Left yaw limit must be positive")
        precondition(rightYawTenths > 0, "Right yaw limit must be positive")
        precondition(upPitchTenths > 0, "Up pitch limit must be positive")
        precondition(downPitchTenths > 0, "Down pitch limit must be positive")
        self.leftYawTenths = leftYawTenths
        self.rightYawTenths = rightYawTenths
        self.upPitchTenths = upPitchTenths
        self.downPitchTenths = downPitchTenths
    }

    func limitTenths(for direction: Direction) -> Int {
        switch direction {
        case .left: return leftYawTenths
        case .right: return rightYawTenths
        case .up: return upPitchTenths
        case .down: return downPitchTenths
        }
    }

    func yawLimitTenths(for signedYawTenths: Int) -> Int {
        limitTenths(for: signedYawTenths < 0 ? .left : .right)
    }

    func pitchLimitTenths(for signedPitchTenths: Int) -> Int {
        limitTenths(for: signedPitchTenths < 0 ? .up : .down)
    }

    /// Returns 1 at any cardinal boundary and on every edge joining two
    /// adjacent cardinal boundaries. Values below 1 are inside the envelope.
    func normalizedUsage(yawTenths: Int, pitchTenths: Int) -> Double {
        abs(Double(yawTenths)) / Double(yawLimitTenths(for: yawTenths))
            + abs(Double(pitchTenths)) / Double(pitchLimitTenths(for: pitchTenths))
    }

    func contains(yawTenths: Int, pitchTenths: Int) -> Bool {
        normalizedUsage(yawTenths: yawTenths, pitchTenths: pitchTenths)
            <= 1.0 + 0.000_000_001
    }
}

enum PersonSearchDirection: Int, CaseIterable, Sendable {
    case left = -1
    case right = 1

    var opposite: PersonSearchDirection {
        self == .left ? .right : .left
    }

    var title: String {
        switch self {
        case .left: return "向左"
        case .right: return "向右"
        }
    }
}

enum PersonSearchMotionMode: String, CaseIterable, Sendable {
    case coast
    case scan
}

struct PersonSearchStep: Equatable, Sendable {
    let yawTenths: Int
    let reachesSoftBoundary: Bool
}

/// Pure motion policy for reacquiring a person after they leave the camera frame.
/// The coordinator owns timing and accumulated-travel state; this type only
/// defines bounded command parameters and the next relative scan step.
enum PersonSearchPolicy {
    static let exitEdgeThreshold = 0.12
    static let minimumOutwardTravel = 0.04
    static let minimumExitConfidence: Float = 0.65

    static let coastStepTenths = 10
    static let coastDurationTenths: UInt8 = 1
    static let coastCooldown: TimeInterval = 0.23
    static let lossGraceStopCooldown: TimeInterval = 0.12
    static let maximumCoastTravelTenths = 20

    static let scanSoftYawLimitTenths = 200
    static let scanStepTenths = 20
    static let scanDurationTenths: UInt8 = 3
    static let scanCooldown: TimeInterval = 0.45
    static let scanSettleDuration: TimeInterval = 0.30
    static let maximumScanEpisodeDuration: TimeInterval = 12.0
    static let maximumScanEpisodeTravelTenths = 600
    static let maximumScanBoundaryTouches = 2

    static let commandMaximumAge: TimeInterval = 0.25
    static let commandRetryInterval: TimeInterval = 0.05
    static let maximumVisionSilence: TimeInterval = 0.50

    static func latestFirstWriteUptime(
        requestedAtUptime: TimeInterval,
        mustFinishByUptime: TimeInterval,
        durationTenths: UInt8
    ) -> TimeInterval {
        min(
            requestedAtUptime + commandMaximumAge,
            mustFinishByUptime - Double(durationTenths) / 10.0
        )
    }

    static func coastDirection(
        recentCenterXs: [Double],
        lastConfidence: Float,
        lastYawTenths: Int
    ) -> PersonSearchDirection? {
        let observations = Array(recentCenterXs.suffix(4))
        guard observations.count >= 3,
              lastConfidence >= minimumExitConfidence,
              lastYawTenths != 0,
              let first = observations.first,
              let last = observations.last
        else { return nil }

        let direction: PersonSearchDirection
        if last <= exitEdgeThreshold {
            direction = .left
        } else if last >= 1 - exitEdgeThreshold {
            direction = .right
        } else {
            return nil
        }
        let commandedDirection: PersonSearchDirection = lastYawTenths < 0 ? .left : .right
        guard commandedDirection == direction else { return nil }
        guard Double(direction.rawValue) * (last - first) >= minimumOutwardTravel else {
            return nil
        }
        for pair in zip(observations, observations.dropFirst()) {
            guard Double(direction.rawValue) * (pair.1 - pair.0) >= 0 else { return nil }
        }
        return direction
    }

    static func coastStep(
        currentYawTenths: Int,
        direction: PersonSearchDirection
    ) -> PersonSearchStep? {
        boundedStep(
            currentYawTenths: currentYawTenths,
            direction: direction,
            stepTenths: coastStepTenths
        )
    }

    /// Returns one relative yaw command toward the requested soft boundary.
    /// If an estimated position starts outside the soft range, only the
    /// direction that first moves it back toward zero (and then across to the
    /// opposite boundary) is accepted.
    static func scanStep(
        currentYawTenths: Int,
        direction: PersonSearchDirection
    ) -> PersonSearchStep? {
        boundedStep(
            currentYawTenths: currentYawTenths,
            direction: direction,
            stepTenths: scanStepTenths
        )
    }

    private static func boundedStep(
        currentYawTenths: Int,
        direction: PersonSearchDirection,
        stepTenths: Int
    ) -> PersonSearchStep? {
        let limit = scanSoftYawLimitTenths

        switch direction {
        case .left:
            let target = -limit
            guard currentYawTenths > target else { return nil }
            guard currentYawTenths <= target + stepTenths else {
                return PersonSearchStep(
                    yawTenths: -stepTenths,
                    reachesSoftBoundary: false
                )
            }
            return PersonSearchStep(
                yawTenths: target - currentYawTenths,
                reachesSoftBoundary: true
            )

        case .right:
            let target = limit
            guard currentYawTenths < target else { return nil }
            guard currentYawTenths >= target - stepTenths else {
                return PersonSearchStep(
                    yawTenths: stepTenths,
                    reachesSoftBoundary: false
                )
            }
            return PersonSearchStep(
                yawTenths: target - currentYawTenths,
                reachesSoftBoundary: true
            )
        }
    }
}

enum PersonTrackingSpeedMode: Int, CaseIterable, Identifiable, Sendable {
    case smooth = 0
    case standard = 1
    case fast = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .smooth: return "平稳"
        case .standard: return "标准"
        case .fast: return "连续极速 +200%"
        }
    }

    var detail: String {
        if self == .fast {
            return "最大 \(formatTenths(combinedMaximumTenths))° / \(formatTenths(Int(commandDurationTenths))) 秒 · 应用无额外等待"
        }
        return "最大 \(formatTenths(combinedMaximumTenths))° / \(formatTenths(Int(commandDurationTenths))) 秒 · 间隔 \(String(format: "%.2f", commandCooldown)) 秒"
    }

    var yawMaximumTenths: Int {
        switch self {
        case .smooth: return 15
        case .standard: return 20
        case .fast: return 65
        }
    }

    var pitchMaximumTenths: Int {
        switch self {
        case .smooth: return 10
        case .standard: return 15
        case .fast: return 20
        }
    }

    /// The floor of the proportional ramp at the dead-zone edge. Kept small so
    /// a target barely outside the dead zone gets a gentle nudge rather than a
    /// visible kick.
    var minimumStepTenths: Int {
        switch self {
        case .smooth, .standard: return 3
        case .fast: return 5
        }
    }

    var mediumStepTenths: Int {
        switch self {
        case .smooth, .standard: return 10
        case .fast: return 35
        }
    }

    var combinedMaximumTenths: Int {
        switch self {
        case .smooth: return 15
        case .standard: return 20
        case .fast: return 65
        }
    }

    var commandDurationTenths: UInt8 {
        switch self {
        case .smooth, .standard: return 3
        case .fast: return 1
        }
    }

    var commandCooldown: TimeInterval {
        switch self {
        case .smooth: return 0.55
        case .standard: return 0.45
        case .fast: return 0.10
        }
    }

    var maximumSampleAge: TimeInterval {
        switch self {
        case .smooth, .standard: return 0.25
        case .fast: return 0.10
        }
    }

    private func formatTenths(_ value: Int) -> String {
        String(format: "%.1f", Double(value) / 10.0)
    }
}

enum PersonTrackingPolicy {
    static let horizontalDeadZone = 0.12
    static let verticalDeadZone = 0.15
    /// Inner (re-entry) dead zones for the hysteresis: once correcting, an
    /// axis keeps correcting until the error falls inside these.
    static let horizontalInnerDeadZone = 0.07
    static let verticalInnerDeadZone = 0.09
    /// Vertical control anchors on the head — a quarter of the way down the
    /// upper-body box — because the box center jumps when arms raise or the
    /// posture changes. Target 0.32 plus the anchor offset reproduces the
    /// previous head-room framing (box center ≈ 0.42) for a typical box.
    static let headAnchorFraction = 0.25
    static let verticalHeadAnchorTarget = 0.32
    /// Predictive aiming: corrections target where the person will be after
    /// roughly the pipeline latency plus one command duration, with the lead
    /// clamped so a noisy velocity estimate cannot fling the aim point.
    static let predictionHorizon: TimeInterval = 0.18
    static let maximumPredictionLead = 0.12
    /// A correction's magnitude may grow at most this much between consecutive
    /// commands (per axis); decreasing toward zero is never limited.
    static let slewLimitTenths = 20
    /// Axis reversals at or above this magnitude take the full STOP-and-pause
    /// path; smaller ones are absorbed by zeroing the axis for one cycle.
    static let significantReversalTenths = 10
    static let analysisInterval: TimeInterval = 0.08
    static let acquisitionMinimumDuration: TimeInterval = 0.24
    static let reversalPauseDuration: TimeInterval = 0.18
    static let lostTimeout: TimeInterval = 0.40
    static let minimumStopCooldown: TimeInterval = 0.12
    /// Tracker samples may drive corrections only while the detector has
    /// confirmed the locked person this recently. This keeps loss handling and
    /// search purely detector-driven even if the correlation tracker latches
    /// onto background content.
    static let trackerBridgeMaximumGap: TimeInterval = 0.20
    /// The correlation tracker refuses to start from a seed older than this;
    /// the detector refreshes the seed on every resolved frame.
    static let trackerSeedMaximumAge: TimeInterval = 0.50
    static let trackerMinimumConfidence: Float = 0.30
    static let netYawSafetyLimitTenths = GimbalTrackingEnvelope
        .conservativeDefault.rightYawTenths
    static let netPitchSafetyLimitTenths = GimbalTrackingEnvelope
        .conservativeDefault.downPitchTenths

    /// Clips only the final step where its current-to-target line intersects the
    /// calibrated diamond. This lets a fast profile decelerate into the boundary
    /// without changing either requested axis direction. If a newly calibrated
    /// envelope leaves the estimated pose outside, only a command that strictly
    /// reduces normalized envelope usage is allowed until tracking moves back in.
    static func correctionClampedToNetSafetyBoundary(
        _ correction: PersonTrackingCorrection,
        currentYawTenths: Int,
        currentPitchTenths: Int,
        envelope: GimbalTrackingEnvelope = .conservativeDefault
    ) -> PersonTrackingCorrection? {
        guard !correction.isZero else { return nil }

        let targetYaw = currentYawTenths + correction.yawTenths
        let targetPitch = currentPitchTenths + correction.pitchTenths
        let currentUsage = envelope.normalizedUsage(
            yawTenths: currentYawTenths,
            pitchTenths: currentPitchTenths
        )
        let targetUsage = envelope.normalizedUsage(
            yawTenths: targetYaw,
            pitchTenths: targetPitch
        )

        if currentUsage > 1.0 + 0.000_000_001 {
            return targetUsage < currentUsage - 0.000_000_001 ? correction : nil
        }
        guard !envelope.contains(yawTenths: targetYaw, pitchTenths: targetPitch) else {
            return correction
        }

        // The intersection with a convex diamond is a single exit point for a
        // line beginning inside it. Binary search avoids separate sign/quadrant
        // cases when one axis crosses zero during a correction.
        var insideScale = 0.0
        var outsideScale = 1.0
        for _ in 0..<64 {
            let candidateScale = (insideScale + outsideScale) / 2
            let candidateYaw = Double(currentYawTenths)
                + Double(correction.yawTenths) * candidateScale
            let candidatePitch = Double(currentPitchTenths)
                + Double(correction.pitchTenths) * candidateScale
            let usage = normalizedUsage(
                yawTenths: candidateYaw,
                pitchTenths: candidatePitch,
                envelope: envelope
            )
            if usage <= 1.0 {
                insideScale = candidateScale
            } else {
                outsideScale = candidateScale
            }
        }

        let boundaryYaw = Double(currentYawTenths)
            + Double(correction.yawTenths) * insideScale
        let boundaryPitch = Double(currentPitchTenths)
            + Double(correction.pitchTenths) * insideScale
        // Prefer the nearest discrete point to the continuous intersection. A
        // containment check below rejects any outward rounding; that case falls
        // back to rounding both absolute coordinates toward the origin, which
        // can only reduce diamond usage. Since the endpoints are integers, both
        // choices remain between them on each axis and preserve command signs.
        let nearest = PersonTrackingCorrection(
            yawTenths: Int(boundaryYaw.rounded()) - currentYawTenths,
            pitchTenths: Int(boundaryPitch.rounded()) - currentPitchTenths
        )
        let nearestYaw = currentYawTenths + nearest.yawTenths
        let nearestPitch = currentPitchTenths + nearest.pitchTenths
        let bounded = envelope.contains(yawTenths: nearestYaw, pitchTenths: nearestPitch)
            ? nearest
            : PersonTrackingCorrection(
                yawTenths: Int(boundaryYaw.rounded(.towardZero)) - currentYawTenths,
                pitchTenths: Int(boundaryPitch.rounded(.towardZero)) - currentPitchTenths
            )
        guard !bounded.isZero else { return nil }

        let boundedYaw = currentYawTenths + bounded.yawTenths
        let boundedPitch = currentPitchTenths + bounded.pitchTenths
        guard envelope.contains(yawTenths: boundedYaw, pitchTenths: boundedPitch)
        else { return nil }
        return bounded
    }

    static func headAnchorY(for detection: PersonDetection) -> Double {
        detection.y + headAnchorFraction * detection.height
    }

    /// Single-shot compatibility entry point: no velocity, no history. Starts
    /// from the centered regime so the classic outer dead zone applies.
    static func correction(
        for detection: PersonDetection,
        speedMode: PersonTrackingSpeedMode = .fast
    ) -> PersonTrackingCorrection? {
        predictiveCorrection(
            anchorX: detection.centerX,
            anchorY: headAnchorY(for: detection),
            velocityX: 0,
            velocityY: 0,
            centering: .centered,
            previousCorrection: nil,
            speedMode: speedMode
        ).correction
    }

    /// One full control cycle: predictive aiming, hysteresis dead zones,
    /// per-axis reversal handling, slew limiting, then the combined-magnitude
    /// cap. Pure so the whole smoothness profile stays unit-testable.
    static func predictiveCorrection(
        anchorX: Double,
        anchorY: Double,
        velocityX: Double,
        velocityY: Double,
        centering: PersonTrackingCenteringState,
        previousCorrection: PersonTrackingCorrection?,
        speedMode: PersonTrackingSpeedMode
    ) -> PersonTrackingControlDecision {
        let horizontalError = predictedCoordinate(anchorX, velocity: velocityX) - 0.5
        // Coordinates use a top-left origin: a negative error means the person
        // is above the target. The calibrated OM3 mapping uses negative pitch
        // for up.
        let verticalError = predictedCoordinate(anchorY, velocity: velocityY)
            - verticalHeadAnchorTarget

        let yawStep = axisStep(
            error: horizontalError,
            wasCentered: centering.yawCentered,
            innerDeadZone: horizontalInnerDeadZone,
            outerDeadZone: horizontalDeadZone,
            mediumThreshold: 0.22,
            largeThreshold: 0.34,
            minimumTenths: speedMode.minimumStepTenths,
            mediumTenths: speedMode.mediumStepTenths,
            maximumTenths: speedMode.yawMaximumTenths
        )
        let pitchStep = axisStep(
            error: verticalError,
            wasCentered: centering.pitchCentered,
            innerDeadZone: verticalInnerDeadZone,
            outerDeadZone: verticalDeadZone,
            mediumThreshold: 0.25,
            largeThreshold: 0.38,
            minimumTenths: speedMode.minimumStepTenths,
            mediumTenths: speedMode.mediumStepTenths,
            maximumTenths: speedMode.pitchMaximumTenths
        )
        var yaw = yawStep.tenths
        var pitch = pitchStep.tenths
        let newCentering = PersonTrackingCenteringState(
            yawCentered: yawStep.isCentered,
            pitchCentered: pitchStep.isCentered
        )

        if let previous = previousCorrection {
            let yawReverses = reverses(yaw, against: previous.yawTenths)
            let pitchReverses = reverses(pitch, against: previous.pitchTenths)
            if (yawReverses && abs(yaw) >= significantReversalTenths)
                || (pitchReverses && abs(pitch) >= significantReversalTenths) {
                return PersonTrackingControlDecision(
                    correction: nil,
                    centering: newCentering,
                    requiresReversalStop: true
                )
            }
            // A minor reversal is absorbed by holding that axis for one cycle:
            // the previous burst decays inside the OM3 without a hard STOP.
            if yawReverses { yaw = 0 }
            if pitchReverses { pitch = 0 }
            yaw = slewLimited(yaw, previous: previous.yawTenths)
            pitch = slewLimited(pitch, previous: previous.pitchTenths)
        }

        let limited = limitCombinedMagnitude(
            yaw: yaw,
            pitch: pitch,
            maximumTenths: speedMode.combinedMaximumTenths
        )
        let correction = PersonTrackingCorrection(
            yawTenths: limited.yaw,
            pitchTenths: limited.pitch
        )
        return PersonTrackingControlDecision(
            correction: correction.isZero ? nil : correction,
            centering: newCentering,
            requiresReversalStop: false
        )
    }

    private static func predictedCoordinate(
        _ position: Double,
        velocity: Double
    ) -> Double {
        let lead = min(
            maximumPredictionLead,
            max(-maximumPredictionLead, velocity * predictionHorizon)
        )
        return min(1, max(0, position + lead))
    }

    private static func reverses(_ next: Int, against previous: Int) -> Bool {
        next != 0 && previous != 0 && (next < 0) != (previous < 0)
    }

    /// Only magnitude growth is limited; decaying toward zero must always be
    /// allowed so the gimbal can stop within one cycle.
    private static func slewLimited(_ next: Int, previous: Int) -> Int {
        let allowedMagnitude = abs(previous) + slewLimitTenths
        guard abs(next) > allowedMagnitude else { return next }
        return next < 0 ? -allowedMagnitude : allowedMagnitude
    }

    private static func limitCombinedMagnitude(
        yaw: Int,
        pitch: Int,
        maximumTenths: Int
    ) -> (yaw: Int, pitch: Int) {
        let magnitude = hypot(Double(yaw), Double(pitch))
        guard magnitude > Double(maximumTenths) else { return (yaw, pitch) }
        let scale = Double(maximumTenths) / magnitude
        let targetYaw = Double(yaw) * scale
        let targetPitch = Double(pitch) * scale
        let yawSign = yaw < 0 ? -1 : 1
        let pitchSign = pitch < 0 ? -1 : 1
        var best = (yaw: 0, pitch: 0)
        var bestError = Double.infinity
        var bestMagnitude = -Double.infinity

        // Search the tiny 0.5-degree grid instead of independently rounding each
        // axis, which could put the diagonal vector back outside the selected cap.
        for yawMagnitude in stride(from: 0, through: maximumTenths, by: 5) {
            for pitchMagnitude in stride(from: 0, through: maximumTenths, by: 5) {
                let candidateMagnitude = hypot(
                    Double(yawMagnitude),
                    Double(pitchMagnitude)
                )
                guard candidateMagnitude <= Double(maximumTenths) else { continue }
                let candidateYaw = yawMagnitude * yawSign
                let candidatePitch = pitchMagnitude * pitchSign
                let error = pow(Double(candidateYaw) - targetYaw, 2)
                    + pow(Double(candidatePitch) - targetPitch, 2)
                if error < bestError - 0.000_001
                    || (abs(error - bestError) <= 0.000_001
                        && candidateMagnitude > bestMagnitude) {
                    best = (candidateYaw, candidatePitch)
                    bestError = error
                    bestMagnitude = candidateMagnitude
                }
            }
        }
        return best
    }

    private static func normalizedUsage(
        yawTenths: Double,
        pitchTenths: Double,
        envelope: GimbalTrackingEnvelope
    ) -> Double {
        let yawLimit = yawTenths < 0
            ? envelope.leftYawTenths
            : envelope.rightYawTenths
        let pitchLimit = pitchTenths < 0
            ? envelope.upPitchTenths
            : envelope.downPitchTenths
        return abs(yawTenths) / Double(yawLimit)
            + abs(pitchTenths) / Double(pitchLimit)
    }

    private static func axisStep(
        error: Double,
        wasCentered: Bool,
        innerDeadZone: Double,
        outerDeadZone: Double,
        mediumThreshold: Double,
        largeThreshold: Double,
        minimumTenths: Int,
        mediumTenths: Int,
        maximumTenths: Int
    ) -> (tenths: Int, isCentered: Bool) {
        let magnitude = abs(error)
        // Hysteresis: leaving the centered regime needs the outer dead zone;
        // returning to it needs the inner one.
        if wasCentered {
            guard magnitude > outerDeadZone else { return (0, true) }
        } else if magnitude <= innerDeadZone {
            return (0, true)
        }

        let minimum = min(minimumTenths, maximumTenths)
        let medium = min(mediumTenths, maximumTenths)
        // Piecewise-linear through the tuned waypoints instead of flat
        // plateaus: corrections scale continuously with the framing error.
        // Inside the hysteresis band (between the inner and outer dead zones)
        // only the minimum nudge applies.
        let step: Double
        if magnitude >= largeThreshold {
            step = Double(maximumTenths)
        } else if magnitude >= mediumThreshold {
            let ramp = (magnitude - mediumThreshold)
                / max(largeThreshold - mediumThreshold, 0.000_001)
            step = Double(medium) + ramp * Double(maximumTenths - medium)
        } else if magnitude > outerDeadZone {
            let ramp = (magnitude - outerDeadZone)
                / max(mediumThreshold - outerDeadZone, 0.000_001)
            step = Double(minimum) + ramp * Double(medium - minimum)
        } else {
            step = Double(minimum)
        }
        let rounded = max(1, Int(step.rounded()))
        return (error < 0 ? -rounded : rounded, false)
    }
}
