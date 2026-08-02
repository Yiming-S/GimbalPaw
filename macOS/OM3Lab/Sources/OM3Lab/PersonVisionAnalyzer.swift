@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Vision

/// A locked-target box handed to the analyzer so the correlation tracker can
/// follow it at full frame rate between detector keyframes.
struct PersonTrackingSeed: Sendable {
    let detection: PersonDetection
    let seededAtUptime: TimeInterval
    let generation: UInt64
}

final class PersonVisionAnalyzer:
    NSObject,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    var onSample: (@Sendable (PersonVisionSample) -> Void)?
    var onMotionSample: (@Sendable (GimbalMotionFrameSample) -> Void)?

    private let queue = DispatchQueue(
        label: "com.yimingshen.om3lab.vision",
        qos: .userInitiated
    )
    private let sessionLock = NSLock()
    private var requestedSessionLease: PersonVisionSessionLease?
    private var requestedMotionSessionLease: GimbalMotionSessionLease?
    private var preparedSessionID: UUID?
    private var preparedMotionSessionID: UUID?
    private var sequence: UInt64 = 0
    private var motionSequence: UInt64 = 0
    private var lastProcessedPTS = -Double.infinity
    private var lastMotionPTS = -Double.infinity

    private let seedLock = NSLock()
    private var requestedSeed: PersonTrackingSeed?
    private var seedGenerationCounter: UInt64 = 0
    // Vision-queue-only correlation-tracker state.
    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackedObservation: VNDetectedObjectObservation?
    private var consumedSeedGeneration: UInt64 = 0

    func attach(to output: AVCaptureVideoDataOutput) {
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func detach(from output: AVCaptureVideoDataOutput) {
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func setSession(_ sessionLease: PersonVisionSessionLease?) {
        sessionLock.lock()
        if requestedSessionLease?.id != sessionLease?.id {
            requestedSessionLease?.revoke()
        }
        requestedSessionLease = sessionLease
        sessionLock.unlock()

        let sessionID = sessionLease?.id

        queue.async { [weak self] in
            guard let self else { return }
            self.lastProcessedPTS = -Double.infinity
            guard self.currentSessionID() == sessionID else { return }
            self.preparedSessionID = sessionID
        }
    }

    func setMotionSession(_ sessionLease: GimbalMotionSessionLease?) {
        sessionLock.lock()
        if requestedMotionSessionLease?.id != sessionLease?.id {
            requestedMotionSessionLease?.revoke()
        }
        requestedMotionSessionLease = sessionLease
        sessionLock.unlock()

        let sessionID = sessionLease?.id
        queue.async { [weak self] in
            guard let self else { return }
            self.lastMotionPTS = -Double.infinity
            guard self.currentMotionSessionID() == sessionID else { return }
            self.preparedMotionSessionID = sessionID
        }
    }

    /// Updates (or clears) the locked-target seed for the correlation tracker.
    /// The coordinator refreshes this on every detector frame that resolves
    /// the lock, so tracker output can never drift far from a detector-
    /// confirmed position.
    func setTrackingSeed(_ detection: PersonDetection?) {
        seedLock.lock()
        if let detection {
            seedGenerationCounter &+= 1
            requestedSeed = PersonTrackingSeed(
                detection: detection,
                seededAtUptime: ProcessInfo.processInfo.systemUptime,
                generation: seedGenerationCounter
            )
        } else {
            requestedSeed = nil
        }
        seedLock.unlock()
    }

    func resetForCameraChange() {
        setSession(nil)
        setMotionSession(nil)
        setTrackingSeed(nil)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let frameSessionID = currentSessionID()
        let frameMotionSessionID = currentMotionSessionID()
        guard frameSessionID != nil || frameMotionSessionID != nil else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard pts.isFinite else { return }
        let capturedAtUptime = ProcessInfo.processInfo.systemUptime

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if let frameMotionSessionID,
           preparedMotionSessionID == frameMotionSessionID,
           pts < lastMotionPTS || pts - lastMotionPTS >= GimbalRangeCalibrationPolicy.analysisInterval {
            lastMotionPTS = pts
            publishMotionSample(
                pixelBuffer: pixelBuffer,
                sessionID: frameMotionSessionID,
                observedAtUptime: capturedAtUptime
            )
        }

        guard let frameSessionID,
              preparedSessionID == frameSessionID
        else { return }
        if pts >= lastProcessedPTS,
           pts - lastProcessedPTS < PersonTrackingPolicy.analysisInterval {
            // Frames between detector keyframes still feed the correlation
            // tracker, giving the locked target full-frame-rate position
            // updates without re-running the detector.
            runTrackerIfSeeded(
                pixelBuffer: pixelBuffer,
                sessionID: frameSessionID,
                observedAtUptime: capturedAtUptime
            )
            return
        }
        lastProcessedPTS = pts

        autoreleasepool {
            let request = VNDetectHumanRectanglesRequest()
            request.revision = VNDetectHumanRectanglesRequestRevision2
            request.upperBodyOnly = true

            do {
                let handler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    orientation: .up,
                    options: [:]
                )
                try handler.perform([request])
                guard currentSessionID() == frameSessionID else { return }
                consume(
                    request.results ?? [],
                    sessionID: frameSessionID,
                    observedAtUptime: capturedAtUptime
                )
            } catch {
                guard currentSessionID() == frameSessionID else { return }
                registerMiss(
                    sessionID: frameSessionID,
                    observedAtUptime: capturedAtUptime
                )
            }
        }
    }

    private func runTrackerIfSeeded(
        pixelBuffer: CVPixelBuffer,
        sessionID: UUID,
        observedAtUptime: TimeInterval
    ) {
        seedLock.lock()
        let seed = requestedSeed
        seedLock.unlock()
        guard let seed,
              observedAtUptime - seed.seededAtUptime
                <= PersonTrackingPolicy.trackerSeedMaximumAge
        else {
            trackedObservation = nil
            return
        }

        if consumedSeedGeneration != seed.generation {
            consumedSeedGeneration = seed.generation
            let box = seed.detection
            // PersonDetection uses a top-left origin; Vision uses bottom-left.
            let visionRect = CGRect(
                x: box.x,
                y: 1 - (box.y + box.height),
                width: box.width,
                height: box.height
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard visionRect.width > 0.005, visionRect.height > 0.005 else {
                trackedObservation = nil
                return
            }
            trackedObservation = VNDetectedObjectObservation(boundingBox: visionRect)
            // A fresh observation starts a new track; the sequence handler is
            // recreated with it so stale temporal state cannot leak in.
            sequenceHandler = VNSequenceRequestHandler()
        }
        guard let inputObservation = trackedObservation else { return }

        autoreleasepool {
            let request = VNTrackObjectRequest(
                detectedObjectObservation: inputObservation
            )
            request.trackingLevel = .fast
            do {
                try sequenceHandler.perform(
                    [request],
                    on: pixelBuffer,
                    orientation: .up
                )
                guard currentSessionID() == sessionID,
                      let result = request.results?.first as? VNDetectedObjectObservation,
                      result.confidence >= PersonTrackingPolicy.trackerMinimumConfidence
                else {
                    trackedObservation = nil
                    return
                }
                trackedObservation = result
                let box = result.boundingBox
                let detection = PersonDetection(
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height,
                    confidence: result.confidence
                )
                sequence &+= 1
                onSample?(
                    PersonVisionSample(
                        sessionID: sessionID,
                        detections: [detection],
                        selectedDetection: detection,
                        sequence: sequence,
                        observedAtUptime: observedAtUptime,
                        origin: .tracker
                    )
                )
            } catch {
                trackedObservation = nil
            }
        }
    }

    private func consume(
        _ observations: [VNHumanObservation],
        sessionID: UUID,
        observedAtUptime: TimeInterval
    ) {
        let candidates = observations.compactMap { observation -> PersonDetection? in
            let box = observation.boundingBox
            let area = box.width * box.height
            guard observation.confidence >= 0.50, area >= 0.012 else { return nil }
            return PersonDetection(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height,
                confidence: observation.confidence
            )
        }
        publish(
            detections: candidates,
            sessionID: sessionID,
            observedAtUptime: observedAtUptime
        )
    }

    private func registerMiss(sessionID: UUID, observedAtUptime: TimeInterval) {
        publish(
            detections: [],
            sessionID: sessionID,
            observedAtUptime: observedAtUptime
        )
    }

    private func publish(
        detections: [PersonDetection],
        sessionID: UUID,
        observedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        sequence &+= 1
        onSample?(
            PersonVisionSample(
                sessionID: sessionID,
                detections: detections,
                sequence: sequence,
                observedAtUptime: observedAtUptime
            )
        )
    }

    private func currentSessionID() -> UUID? {
        sessionLock.lock()
        let lease = requestedSessionLease
        sessionLock.unlock()
        guard lease?.isValid == true else { return nil }
        return lease?.id
    }

    private func publishMotionSample(
        pixelBuffer: CVPixelBuffer,
        sessionID: UUID,
        observedAtUptime: TimeInterval
    ) {
        guard let signature = GimbalMotionAnalysis.makeSignature(from: pixelBuffer),
              currentMotionSessionID() == sessionID
        else { return }
        motionSequence &+= 1
        onMotionSample?(
            GimbalMotionFrameSample(
                sessionID: sessionID,
                signature: signature,
                sequence: motionSequence,
                observedAtUptime: observedAtUptime
            )
        )
    }

    private func currentMotionSessionID() -> UUID? {
        sessionLock.lock()
        let lease = requestedMotionSessionLease
        sessionLock.unlock()
        guard lease?.isValid == true else { return nil }
        return lease?.id
    }

}
