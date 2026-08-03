import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    var onSelectCandidate: ((PersonCandidateID) -> Void)?

    private let candidateBoxLayer = CAShapeLayer()
    private let selectedPersonBoxLayer = CAShapeLayer()
    private let personCenterLayer = CAShapeLayer()
    private let frameCenterLayer = CAShapeLayer()
    private var personCandidates: [PersonCandidate] = []
    private var selectedPersonID: PersonCandidateID?
    private var candidateLabelLayers: [PersonCandidateID: CATextLayer] = [:]
    private var candidateLabelStates: [PersonCandidateID: LabelState] = [:]
    private var candidateHitTargets: [(id: PersonCandidateID, rect: CGRect)] = []
    private var trackingEnabled = false

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
        selectedPersonID: PersonCandidateID?
    ) {
        // SwiftUI calls updateNSView for unrelated parent re-renders too;
        // rebuilding every path and re-rasterizing every label costs real CPU
        // at the vision cadence, so bail when nothing changed.
        guard enabled != trackingEnabled
            || candidates != personCandidates
            || selectedPersonID != self.selectedPersonID
        else { return }
        trackingEnabled = enabled
        personCandidates = candidates
        self.selectedPersonID = selectedPersonID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateTrackingLayers()
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Prefer the smallest box under the cursor, so a person standing in
        // front of another remains individually selectable.
        let hit = candidateHitTargets
            .filter { $0.rect.insetBy(dx: -6, dy: -6).contains(point) }
            .min { lhs, rhs in
                lhs.rect.width * lhs.rect.height < rhs.rect.width * rhs.rect.height
            }
        guard let hit else {
            super.mouseDown(with: event)
            return
        }
        onSelectCandidate?(hit.id)
    }

    private func updateTrackingLayers() {
        candidateBoxLayer.frame = previewLayer.bounds
        selectedPersonBoxLayer.frame = previewLayer.bounds
        personCenterLayer.frame = previewLayer.bounds
        frameCenterLayer.frame = previewLayer.bounds

        guard trackingEnabled else {
            candidateBoxLayer.path = nil
            selectedPersonBoxLayer.path = nil
            personCenterLayer.path = nil
            frameCenterLayer.path = nil
            candidateHitTargets.removeAll(keepingCapacity: true)
            removeAllCandidateLabels()
            return
        }

        let guide = CGMutablePath()
        let target = layerPoint(
            metadataX: 0.5,
            metadataY: PersonTrackingPolicy.verticalHeadAnchorTarget
        )
        guide.move(to: CGPoint(x: target.x - 13, y: target.y))
        guide.addLine(to: CGPoint(x: target.x + 13, y: target.y))
        guide.move(to: CGPoint(x: target.x, y: target.y - 13))
        guide.addLine(to: CGPoint(x: target.x, y: target.y + 13))
        frameCenterLayer.path = guide

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
    var onSelectCandidate: ((PersonCandidateID) -> Void)?

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session)
        view.onSelectCandidate = onSelectCandidate
        view.updateTracking(
            enabled: trackingEnabled,
            candidates: personCandidates,
            selectedPersonID: selectedPersonID
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
            selectedPersonID: selectedPersonID
        )
    }

    static func dismantleNSView(_ nsView: CameraPreviewNSView, coordinator: ()) {
        nsView.previewLayer.session = nil
    }
}
