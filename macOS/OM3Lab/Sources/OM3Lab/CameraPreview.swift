import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// Guide data for the preview overlay, in metadata (top-left, normalized)
/// coordinates. The preview layer converts them, so letterboxing and aspect
/// fit stay correct on every camera.
struct TrackingGuideOverlay: Equatable {
    let outerDeadZoneRect: CGRect
    let innerDeadZoneRect: CGRect
    let target: CGPoint
    let correction: PersonTrackingCorrection?
    let correctionMaximumTenths: Int
}

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onSelectCandidate: ((PersonCandidateID) -> Void)?

    private let candidateBoxLayer = CAShapeLayer()
    private let selectedPersonBoxLayer = CAShapeLayer()
    private let personCenterLayer = CAShapeLayer()
    private let frameCenterLayer = CAShapeLayer()
    private let guideOuterLayer = CAShapeLayer()
    private let guideInnerLayer = CAShapeLayer()
    private let correctionArrowLayer = CAShapeLayer()
    private let hoverBoxLayer = CAShapeLayer()
    private var personCandidates: [PersonCandidate] = []
    private var selectedPersonID: PersonCandidateID?
    private var candidateLabelLayers: [PersonCandidateID: CATextLayer] = [:]
    private var candidateLabelStates: [PersonCandidateID: LabelState] = [:]
    private var candidateHitTargets: [(id: PersonCandidateID, rect: CGRect)] = []
    private var trackingEnabled = false
    private var guides: TrackingGuideOverlay?
    private var hoveredCandidateID: PersonCandidateID?

    private struct LabelState: Equatable {
        let text: String
        let selected: Bool
        let frame: CGRect
        let contentsScale: CGFloat
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor

        candidateBoxLayer.fillColor = NSColor.clear.cgColor
        candidateBoxLayer.strokeColor = NSColor.systemCyan.withAlphaComponent(0.9).cgColor
        candidateBoxLayer.lineWidth = 1.5
        candidateBoxLayer.lineDashPattern = [6, 4]
        previewLayer.addSublayer(candidateBoxLayer)

        selectedPersonBoxLayer.fillColor = NSColor.clear.cgColor
        selectedPersonBoxLayer.strokeColor = NSColor.systemGreen.cgColor
        selectedPersonBoxLayer.lineWidth = 2.5
        selectedPersonBoxLayer.shadowColor = NSColor.black.cgColor
        selectedPersonBoxLayer.shadowOpacity = 0.6
        selectedPersonBoxLayer.shadowRadius = 2
        previewLayer.addSublayer(selectedPersonBoxLayer)

        personCenterLayer.fillColor = NSColor.systemGreen.cgColor
        previewLayer.addSublayer(personCenterLayer)

        frameCenterLayer.fillColor = NSColor.clear.cgColor
        frameCenterLayer.strokeColor = NSColor.systemCyan.withAlphaComponent(0.7).cgColor
        frameCenterLayer.lineWidth = 1
        frameCenterLayer.lineDashPattern = [4, 4]
        previewLayer.addSublayer(frameCenterLayer)

        guideOuterLayer.fillColor = NSColor.clear.cgColor
        guideOuterLayer.strokeColor = NSColor.white.withAlphaComponent(0.28).cgColor
        guideOuterLayer.lineWidth = 1
        guideOuterLayer.lineDashPattern = [5, 5]
        previewLayer.addSublayer(guideOuterLayer)

        guideInnerLayer.fillColor = NSColor.clear.cgColor
        guideInnerLayer.strokeColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        guideInnerLayer.lineWidth = 1
        guideInnerLayer.lineDashPattern = [3, 4]
        previewLayer.addSublayer(guideInnerLayer)

        correctionArrowLayer.fillColor = NSColor.clear.cgColor
        correctionArrowLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        correctionArrowLayer.lineWidth = 2.5
        correctionArrowLayer.lineCap = .round
        previewLayer.addSublayer(correctionArrowLayer)

        hoverBoxLayer.fillColor = NSColor.clear.cgColor
        hoverBoxLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        hoverBoxLayer.lineWidth = 2.5
        previewLayer.addSublayer(hoverBoxLayer)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        updateTrackingLayers()
        CATransaction.commit()
    }

    func updateTracking(
        enabled: Bool,
        candidates: [PersonCandidate],
        selectedPersonID: PersonCandidateID?,
        guides: TrackingGuideOverlay?
    ) {
        // SwiftUI calls updateNSView for unrelated parent re-renders too;
        // rebuilding every path and re-rasterizing every label costs real CPU
        // at the vision cadence, so bail when nothing changed.
        guard enabled != trackingEnabled
            || candidates != personCandidates
            || selectedPersonID != self.selectedPersonID
            || guides != self.guides
        else { return }
        trackingEnabled = enabled
        personCandidates = candidates
        self.selectedPersonID = selectedPersonID
        self.guides = guides
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateTrackingLayers()
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = candidateHit(at: point) else {
            super.mouseDown(with: event)
            return
        }
        onSelectCandidate?(hit.id)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hoveredID = candidateHit(at: point)?.id
        if hoveredID != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        guard hoveredID != hoveredCandidateID else { return }
        hoveredCandidateID = hoveredID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateHoverLayer()
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        guard hoveredCandidateID != nil else { return }
        hoveredCandidateID = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateHoverLayer()
        CATransaction.commit()
    }

    /// Prefers the smallest box under the cursor, so a person standing in
    /// front of another remains individually selectable.
    private func candidateHit(
        at point: CGPoint
    ) -> (id: PersonCandidateID, rect: CGRect)? {
        candidateHitTargets
            .filter { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
            .min { lhs, rhs in
                lhs.rect.width * lhs.rect.height < rhs.rect.width * rhs.rect.height
            }
    }

    private func updateHoverLayer() {
        hoverBoxLayer.frame = previewLayer.bounds
        guard trackingEnabled,
              let hoveredCandidateID,
              let target = candidateHitTargets.first(
                where: { $0.id == hoveredCandidateID }
              )
        else {
            hoverBoxLayer.path = nil
            return
        }
        hoverBoxLayer.path = CGPath(
            roundedRect: target.rect.insetBy(dx: -2, dy: -2),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    private func updateTrackingLayers() {
        candidateBoxLayer.frame = previewLayer.bounds
        selectedPersonBoxLayer.frame = previewLayer.bounds
        personCenterLayer.frame = previewLayer.bounds
        frameCenterLayer.frame = previewLayer.bounds
        guideOuterLayer.frame = previewLayer.bounds
        guideInnerLayer.frame = previewLayer.bounds
        correctionArrowLayer.frame = previewLayer.bounds

        guard trackingEnabled else {
            candidateBoxLayer.path = nil
            selectedPersonBoxLayer.path = nil
            personCenterLayer.path = nil
            frameCenterLayer.path = nil
            guideOuterLayer.path = nil
            guideInnerLayer.path = nil
            correctionArrowLayer.path = nil
            candidateHitTargets.removeAll(keepingCapacity: true)
            hoveredCandidateID = nil
            updateHoverLayer()
            removeAllCandidateLabels()
            return
        }

        let targetPoint = guides?.target
            ?? CGPoint(
                x: 0.5,
                y: PersonTrackingPolicy.verticalHeadAnchorTarget
            )
        let guide = CGMutablePath()
        let target = layerPoint(
            metadataX: targetPoint.x,
            metadataY: targetPoint.y
        )
        guide.move(to: CGPoint(x: target.x - 13, y: target.y))
        guide.addLine(to: CGPoint(x: target.x + 13, y: target.y))
        guide.move(to: CGPoint(x: target.x, y: target.y - 13))
        guide.addLine(to: CGPoint(x: target.x, y: target.y + 13))
        frameCenterLayer.path = guide
        updateGuideLayers(around: target)

        let candidatePath = CGMutablePath()
        let selectedPath = CGMutablePath()
        let centerPath = CGMutablePath()
        var visibleIDs = Set<PersonCandidateID>()
        let videoRect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1)
        )
        candidateHitTargets.removeAll(keepingCapacity: true)

        for candidate in personCandidates {
            visibleIDs.insert(candidate.id)
            let detection = candidate.detection
            let metadataRect = CGRect(
                x: detection.x,
                y: detection.y,
                width: detection.width,
                height: detection.height
            )
            let layerRect = previewLayer.layerRectConverted(
                fromMetadataOutputRect: metadataRect
            )
            let box = CGPath(
                roundedRect: layerRect,
                cornerWidth: 7,
                cornerHeight: 7,
                transform: nil
            )
            let isSelected = candidate.id == selectedPersonID
            if isSelected {
                selectedPath.addPath(box)
                let headAnchor = layerPoint(
                    metadataX: detection.centerX,
                    metadataY: PersonTrackingPolicy.headAnchorY(for: detection)
                )
                centerPath.addEllipse(
                    in: CGRect(
                        x: headAnchor.x - 4,
                        y: headAnchor.y - 4,
                        width: 8,
                        height: 8
                    )
                )
            } else {
                candidatePath.addPath(box)
            }
            candidateHitTargets.append((id: candidate.id, rect: layerRect))
            updateLabel(
                for: candidate,
                in: layerRect,
                videoRect: videoRect,
                selected: isSelected
            )
        }

        let staleLabelIDs = candidateLabelLayers.keys.filter { !visibleIDs.contains($0) }
        for id in staleLabelIDs {
            candidateLabelLayers[id]?.removeFromSuperlayer()
            candidateLabelLayers.removeValue(forKey: id)
            candidateLabelStates.removeValue(forKey: id)
        }
        candidateBoxLayer.path = candidatePath
        selectedPersonBoxLayer.path = selectedPath
        personCenterLayer.path = centerPath
        updateHoverLayer()
    }

    /// Draws the hysteresis dead-zone rectangles and the in-flight correction
    /// arrow. All source rects are normalized metadata coordinates so the
    /// drawing survives aspect-fit letterboxing on any camera.
    private func updateGuideLayers(around targetLayerPoint: CGPoint) {
        guard let guides else {
            guideOuterLayer.path = nil
            guideInnerLayer.path = nil
            correctionArrowLayer.path = nil
            return
        }
        guideOuterLayer.path = CGPath(
            rect: previewLayer.layerRectConverted(
                fromMetadataOutputRect: guides.outerDeadZoneRect
            ),
            transform: nil
        )
        guideInnerLayer.path = CGPath(
            rect: previewLayer.layerRectConverted(
                fromMetadataOutputRect: guides.innerDeadZoneRect
            ),
            transform: nil
        )

        guard let correction = guides.correction,
              !correction.isZero,
              guides.correctionMaximumTenths > 0
        else {
            correctionArrowLayer.path = nil
            return
        }
        // The arrow points from the framing target toward where the command is
        // steering the aim: right for positive yaw, down for positive pitch.
        let scale = 0.15 / Double(guides.correctionMaximumTenths)
        let tip = layerPoint(
            metadataX: guides.target.x + Double(correction.yawTenths) * scale,
            metadataY: guides.target.y + Double(correction.pitchTenths) * scale
        )
        let arrow = CGMutablePath()
        arrow.move(to: targetLayerPoint)
        arrow.addLine(to: tip)
        let angle = atan2(
            tip.y - targetLayerPoint.y,
            tip.x - targetLayerPoint.x
        )
        let headLength: CGFloat = 8
        for offset in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            arrow.move(to: tip)
            arrow.addLine(
                to: CGPoint(
                    x: tip.x + cos(angle + offset) * headLength,
                    y: tip.y + sin(angle + offset) * headLength
                )
            )
        }
        correctionArrowLayer.path = arrow
    }

    /// AVCaptureVideoPreviewLayer owns aspect-fit and letterbox conversion.
    /// Converting a tiny metadata rectangle is more reliable than duplicating
    /// that geometry, and keeps the control marker aligned on every camera.
    private func layerPoint(metadataX: Double, metadataY: Double) -> CGPoint {
        let epsilon = 0.000_1
        let rect = previewLayer.layerRectConverted(
            fromMetadataOutputRect: CGRect(
                x: metadataX - epsilon / 2,
                y: metadataY - epsilon / 2,
                width: epsilon,
                height: epsilon
            )
        )
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func updateLabel(
        for candidate: PersonCandidate,
        in layerRect: CGRect,
        videoRect: CGRect,
        selected: Bool
    ) {
        let text = selected ? "锁定 \(candidate.id.rawValue)" : candidate.id.title
        let width: CGFloat = selected ? 58 : 52
        // AppKit layer space is not flipped, so the on-screen top of the box is
        // its maxY edge; clamping against the video rect keeps labels off the
        // letterbox bars.
        let clampRect = videoRect.isEmpty ? previewLayer.bounds : videoRect
        let x = min(
            max(clampRect.minX + 4, layerRect.minX),
            max(clampRect.minX + 4, clampRect.maxX - width - 4)
        )
        let y = min(
            max(clampRect.minY + 4, layerRect.maxY - 22),
            max(clampRect.minY + 4, clampRect.maxY - 22)
        )
        let frame = CGRect(x: x, y: y, width: width, height: 18)
        let contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let desiredState = LabelState(
            text: text,
            selected: selected,
            frame: frame,
            contentsScale: contentsScale
        )
        // CATextLayer re-rasterizes on every property write (string is Any?,
        // so it cannot diff internally); only touch what actually changed.
        guard candidateLabelStates[candidate.id] != desiredState else { return }

        let label: CATextLayer
        if let existing = candidateLabelLayers[candidate.id] {
            label = existing
        } else {
            label = CATextLayer()
            label.alignmentMode = .center
            label.fontSize = 11
            label.cornerRadius = 4
            label.masksToBounds = true
            previewLayer.addSublayer(label)
            candidateLabelLayers[candidate.id] = label
        }
        let previousState = candidateLabelStates[candidate.id]
        if previousState?.contentsScale != contentsScale {
            label.contentsScale = contentsScale
        }
        if previousState?.text != text {
            label.string = text
        }
        if previousState?.selected != selected {
            label.foregroundColor = selected
                ? NSColor.black.cgColor
                : NSColor.white.cgColor
            label.backgroundColor = selected
                ? NSColor.systemGreen.cgColor
                : NSColor.systemCyan.withAlphaComponent(0.85).cgColor
        }
        if previousState?.frame != frame {
            label.frame = frame
        }
        candidateLabelStates[candidate.id] = desiredState
    }

    private func removeAllCandidateLabels() {
        for label in candidateLabelLayers.values {
            label.removeFromSuperlayer()
        }
        candidateLabelLayers.removeAll(keepingCapacity: true)
        candidateLabelStates.removeAll(keepingCapacity: true)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let personCandidates: [PersonCandidate]
    let selectedPersonID: PersonCandidateID?
    let trackingEnabled: Bool
    var guides: TrackingGuideOverlay?
    var onSelectCandidate: ((PersonCandidateID) -> Void)?

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session)
        view.onSelectCandidate = onSelectCandidate
        view.updateTracking(
            enabled: trackingEnabled,
            candidates: personCandidates,
            selectedPersonID: selectedPersonID,
            guides: guides
        )
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
        nsView.onSelectCandidate = onSelectCandidate
        nsView.updateTracking(
            enabled: trackingEnabled,
            candidates: personCandidates,
            selectedPersonID: selectedPersonID,
            guides: guides
        )
    }

    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.previewLayer.session = nil
    }
}
