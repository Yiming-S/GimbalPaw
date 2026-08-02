import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let candidateBoxLayer = CAShapeLayer()
    private let selectedPersonBoxLayer = CAShapeLayer()
    private let personCenterLayer = CAShapeLayer()
    private let frameCenterLayer = CAShapeLayer()
    private var personCandidates: [PersonCandidate] = []
    private var selectedPersonID: PersonCandidateID?
    private var candidateLabelLayers: [PersonCandidateID: CATextLayer] = [:]
    private var trackingEnabled = false

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
        trackingEnabled = enabled
        personCandidates = candidates
        self.selectedPersonID = selectedPersonID
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateTrackingLayers()
        CATransaction.commit()
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
            removeAllCandidateLabels()
            return
        }

        let guide = CGMutablePath()
        let center = CGPoint(x: previewLayer.bounds.midX, y: previewLayer.bounds.midY)
        guide.move(to: CGPoint(x: center.x - 13, y: center.y))
        guide.addLine(to: CGPoint(x: center.x + 13, y: center.y))
        guide.move(to: CGPoint(x: center.x, y: center.y - 13))
        guide.addLine(to: CGPoint(x: center.x, y: center.y + 13))
        frameCenterLayer.path = guide

        let candidatePath = CGMutablePath()
        let selectedPath = CGMutablePath()
        let centerPath = CGMutablePath()
        var visibleIDs = Set<PersonCandidateID>()

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
                centerPath.addEllipse(
                    in: CGRect(
                        x: layerRect.midX - 4,
                        y: layerRect.midY - 4,
                        width: 8,
                        height: 8
                    )
                )
            } else {
                candidatePath.addPath(box)
            }
            updateLabel(for: candidate, in: layerRect, selected: isSelected)
        }

        let staleLabelIDs = candidateLabelLayers.keys.filter { !visibleIDs.contains($0) }
        for id in staleLabelIDs {
            candidateLabelLayers[id]?.removeFromSuperlayer()
            candidateLabelLayers.removeValue(forKey: id)
        }
        candidateBoxLayer.path = candidatePath
        selectedPersonBoxLayer.path = selectedPath
        personCenterLayer.path = centerPath
    }

    private func updateLabel(
        for candidate: PersonCandidate,
        in layerRect: CGRect,
        selected: Bool
    ) {
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
        label.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        label.string = selected ? "锁定 \(candidate.id.rawValue)" : candidate.id.title
        label.foregroundColor = selected ? NSColor.black.cgColor : NSColor.white.cgColor
        label.backgroundColor = selected
            ? NSColor.systemGreen.cgColor
            : NSColor.systemCyan.withAlphaComponent(0.85).cgColor
        let width: CGFloat = selected ? 58 : 52
        let x = min(
            max(4, layerRect.minX),
            max(4, previewLayer.bounds.maxX - width - 4)
        )
        let y = min(
            max(4, layerRect.minY + 4),
            max(4, previewLayer.bounds.maxY - 22)
        )
        label.frame = CGRect(x: x, y: y, width: width, height: 18)
    }

    private func removeAllCandidateLabels() {
        for label in candidateLabelLayers.values {
            label.removeFromSuperlayer()
        }
        candidateLabelLayers.removeAll(keepingCapacity: true)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let personCandidates: [PersonCandidate]
    let selectedPersonID: PersonCandidateID?
    let trackingEnabled: Bool

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView(session: session)
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
