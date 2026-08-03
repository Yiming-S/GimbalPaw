import CoreVideo
import Foundation

struct GimbalMotionSignature: Sendable, Equatable {
    let width: Int
    let height: Int
    let luma: [UInt8]
    let meanLuma: Double
    let textureScore: Double

    init(
        width: Int,
        height: Int,
        luma: [UInt8],
        meanLuma: Double,
        textureScore: Double
    ) {
        self.width = width
        self.height = height
        self.luma = luma
        self.meanLuma = meanLuma
        self.textureScore = textureScore
    }

    init(width: Int, height: Int, luma: [UInt8]) {
        self.init(
            width: width,
            height: height,
            luma: luma,
            meanLuma: Self.mean(of: luma),
            textureScore: Self.textureScore(
                luma: luma,
                width: width,
                height: height
            )
        )
    }

    private static func mean(of values: [UInt8]) -> Double {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(into: UInt64(0)) { result, value in
            result += UInt64(value)
        }
        return Double(total) / Double(values.count)
    }

    private static func textureScore(
        luma: [UInt8],
        width: Int,
        height: Int
    ) -> Double {
        guard width > 0,
              height > 0,
              luma.count == width * height
        else { return 0 }

        var differenceTotal: UInt64 = 0
        var pairCount = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let value = Int(luma[row + x])
                if x + 1 < width {
                    differenceTotal += UInt64(abs(value - Int(luma[row + x + 1])))
                    pairCount += 1
                }
                if y + 1 < height {
                    differenceTotal += UInt64(abs(value - Int(luma[row + width + x])))
                    pairCount += 1
                }
            }
        }
        guard pairCount > 0 else { return 0 }
        return Double(differenceTotal) / Double(pairCount) / 255.0
    }
}

enum GimbalMotionAxis: Sendable, Equatable {
    case horizontal
    case vertical
}

enum GimbalMotionVerdict: Sendable, Equatable {
    case moved
    case noResponse
    case inconclusive(String)
}

struct GimbalMotionEstimate: Sendable, Equatable {
    let axisShift: Int
    let zeroError: Double
    let bestError: Double
    let confidence: Double
    let verdict: GimbalMotionVerdict
}

/// A single two-dimensional registration result projected onto both gimbal axes.
/// `zeroError` in each estimate is conditional: the other axis is held at its
/// jointly fitted shift so primary-axis motion cannot inflate the orthogonal
/// axis residual.
struct GimbalMotionVectorEstimate: Sendable, Equatable {
    let horizontal: GimbalMotionEstimate
    let vertical: GimbalMotionEstimate
}

enum GimbalMotionAnalysis {
    private struct TranslationShift: Hashable {
        let horizontal: Int
        let vertical: Int
    }

    private struct TranslationCandidate {
        let shift: TranslationShift
        let error: Double
    }

    private static let minimumTextureScore = 0.012
    private static let maximumExposureDelta = 48.0
    private static let noResponseError = 0.035
    private static let maximumMotionResidual = 0.10
    private static let minimumMovedShift = 2
    private static let minimumAbsoluteImprovement = 0.012
    private static let minimumRelativeImprovement = 0.28
    private static let minimumAlternativeSeparation = 0.006

    /// Copies a compact luminance representation while the pixel buffer is locked.
    /// No CVPixelBuffer-backed storage escapes this function.
    static func makeSignature(
        from pixelBuffer: CVPixelBuffer,
        width targetWidth: Int = 128,
        height targetHeight: Int = 72
    ) -> GimbalMotionSignature? {
        guard targetWidth > 1, targetHeight > 1 else { return nil }

        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let values: [UInt8]?
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            values = downsampleBiPlanarLuma(
                pixelBuffer,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        case kCVPixelFormatType_32BGRA:
            values = downsamplePackedColor(
                pixelBuffer,
                channelOffsets: (red: 2, green: 1, blue: 0),
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        case kCVPixelFormatType_32ARGB:
            values = downsamplePackedColor(
                pixelBuffer,
                channelOffsets: (red: 1, green: 2, blue: 3),
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        default:
            values = nil
        }

        guard let values, values.count == targetWidth * targetHeight else { return nil }
        return GimbalMotionSignature(
            width: targetWidth,
            height: targetHeight,
            luma: values
        )
    }

    /// Finds one global translation along the requested axis. Positive shifts mean
    /// scene content moved right/down in `current` relative to `reference`.
    static func estimate(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature,
        axis: GimbalMotionAxis
    ) -> GimbalMotionEstimate {
        guard reference.width == current.width,
              reference.height == current.height,
              reference.width > 3,
              reference.height > 3,
              reference.luma.count == reference.width * reference.height,
              current.luma.count == current.width * current.height
        else {
            return inconclusive("画面签名尺寸不一致")
        }

        guard min(reference.textureScore, current.textureScore) >= minimumTextureScore else {
            return inconclusive("画面纹理不足")
        }

        let exposureDelta = abs(current.meanLuma - reference.meanLuma)
        guard exposureDelta <= maximumExposureDelta else {
            return inconclusive("曝光变化过大")
        }

        let axisLength = axis == .horizontal ? reference.width : reference.height
        let absoluteCap = axis == .horizontal ? 32 : 20
        let maximumShift = min(absoluteCap, max(3, axisLength / 4))
        let candidates = (-maximumShift...maximumShift).map { shift in
            (
                shift: shift,
                error: compensatedError(
                    reference: reference,
                    current: current,
                    axis: axis,
                    shift: shift
                )
            )
        }
        guard let zeroError = candidates.first(where: { $0.shift == 0 })?.error,
              let best = candidates.min(by: {
                  if abs($0.error - $1.error) < 0.000_001 {
                      return abs($0.shift) < abs($1.shift)
                  }
                  return $0.error < $1.error
              })
        else {
            return inconclusive("画面无法比较")
        }

        if abs(best.shift) <= 1, zeroError <= noResponseError {
            let confidence = clamp01(1 - zeroError / noResponseError)
            return GimbalMotionEstimate(
                axisShift: best.shift,
                zeroError: zeroError,
                bestError: best.error,
                confidence: confidence,
                verdict: .noResponse
            )
        }

        guard best.error <= maximumMotionResidual else {
            return GimbalMotionEstimate(
                axisShift: best.shift,
                zeroError: zeroError,
                bestError: best.error,
                confidence: 0,
                verdict: .inconclusive("画面残差过高")
            )
        }

        let absoluteImprovement = zeroError - best.error
        let relativeImprovement = absoluteImprovement / max(zeroError, 0.000_001)
        let alternatives = candidates.filter { abs($0.shift - best.shift) >= 2 }
        let alternativeError = alternatives.map { $0.error }.min() ?? 1
        let alternativeSeparation = alternativeError - best.error
        let uniqueness = clamp01(
            alternativeSeparation / max(alternativeError, minimumAlternativeSeparation)
        )
        let residualQuality = clamp01(1 - best.error / maximumMotionResidual)
        let confidence = clamp01(
            0.55 * relativeImprovement
                + 0.25 * residualQuality
                + 0.20 * uniqueness
        )

        guard abs(best.shift) >= minimumMovedShift,
              absoluteImprovement >= minimumAbsoluteImprovement,
              relativeImprovement >= minimumRelativeImprovement
        else {
            return GimbalMotionEstimate(
                axisShift: best.shift,
                zeroError: zeroError,
                bestError: best.error,
                confidence: confidence,
                verdict: .inconclusive("轴向位移证据不足")
            )
        }

        guard alternativeSeparation >= minimumAlternativeSeparation else {
            return GimbalMotionEstimate(
                axisShift: best.shift,
                zeroError: zeroError,
                bestError: best.error,
                confidence: confidence,
                verdict: .inconclusive("位移方向不唯一")
            )
        }

        return GimbalMotionEstimate(
            axisShift: best.shift,
            zeroError: zeroError,
            bestError: best.error,
            confidence: confidence,
            verdict: .moved
        )
    }

    /// Fits one global `(horizontal, vertical)` translation and then evaluates
    /// both axes from that same registration. This is the calibration-facing
    /// API: unlike two independent one-dimensional estimates, a large shift on
    /// one axis is compensated before the other axis is classified.
    static func estimateTranslation(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature
    ) -> GimbalMotionVectorEstimate {
        let forward = estimateTranslationOneWay(
            reference: reference,
            current: current
        )
        guard isConclusive(forward.horizontal),
              isConclusive(forward.vertical)
        else {
            return forward
        }

        // A fixed reference ROI prevents an edge-only change from disappearing
        // for one candidate, but a new obstruction inside that ROI can still be
        // escaped by shifting the current-frame sampling window. Genuine camera
        // translation must also register in the reverse direction with the same
        // magnitude and opposite sign. Fold the weaker quality from both passes
        // into the public result so unattended gates cannot ignore a poor reverse
        // fit even when the forward fit looks perfect.
        let reverse = estimateTranslationOneWay(
            reference: current,
            current: reference
        )
        guard let horizontal = bidirectionallyValidated(
                forward: forward.horizontal,
                reverse: reverse.horizontal
              ),
              let vertical = bidirectionallyValidated(
                forward: forward.vertical,
                reverse: reverse.vertical
              )
        else {
            return jointInconclusive("双向位移验证不一致")
        }
        return GimbalMotionVectorEstimate(
            horizontal: horizontal,
            vertical: vertical
        )
    }

    private static func estimateTranslationOneWay(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature
    ) -> GimbalMotionVectorEstimate {
        guard reference.width == current.width,
              reference.height == current.height,
              reference.width > 3,
              reference.height > 3,
              reference.luma.count == reference.width * reference.height,
              current.luma.count == current.width * current.height
        else {
            return jointInconclusive("画面签名尺寸不一致")
        }

        guard min(reference.textureScore, current.textureScore) >= minimumTextureScore else {
            return jointInconclusive("画面纹理不足")
        }

        let exposureDelta = abs(current.meanLuma - reference.meanLuma)
        guard exposureDelta <= maximumExposureDelta else {
            return jointInconclusive("曝光变化过大")
        }

        let horizontalMaximumShift = min(32, max(3, reference.width / 4))
        let verticalMaximumShift = min(20, max(3, reference.height / 4))
        let horizontalRange = -horizontalMaximumShift...horizontalMaximumShift
        let verticalRange = -verticalMaximumShift...verticalMaximumShift
        var evaluated: [TranslationShift: Double] = [:]
        evaluated.reserveCapacity(horizontalRange.count * verticalRange.count)

        func evaluateExact(horizontal: Int, vertical: Int) {
            guard horizontalRange.contains(horizontal),
                  verticalRange.contains(vertical)
            else { return }
            let shift = TranslationShift(horizontal: horizontal, vertical: vertical)
            guard evaluated[shift] == nil else { return }
            evaluated[shift] = compensatedErrorOnCommonROI(
                reference: reference,
                current: current,
                horizontalShift: horizontal,
                verticalShift: vertical,
                horizontalMargin: horizontalMaximumShift,
                verticalMargin: verticalMaximumShift
            )
        }

        // Calibration is safety-sensitive and runs off the main actor, so the
        // complete bounded domain is evaluated with the exact brightness-
        // compensated metric. This makes the global uniqueness test genuine:
        // no odd-pixel, diagonal, periodic, or non-seeded alternative can be
        // omitted by a coarse-to-fine shortlist.
        for verticalShift in verticalRange {
            for horizontalShift in horizontalRange {
                evaluateExact(
                    horizontal: horizontalShift,
                    vertical: verticalShift
                )
            }
        }

        guard let best = bestCandidate(in: evaluated) else {
            return jointInconclusive("画面无法比较")
        }

        let candidates = evaluated.map {
            TranslationCandidate(shift: $0.key, error: $0.value)
        }

        let horizontalCandidates = candidates.compactMap { candidate -> (shift: Int, error: Double)? in
            guard candidate.shift.vertical == best.shift.vertical else { return nil }
            return (candidate.shift.horizontal, candidate.error)
        }
        let verticalCandidates = candidates.compactMap { candidate -> (shift: Int, error: Double)? in
            guard candidate.shift.horizontal == best.shift.horizontal else { return nil }
            return (candidate.shift.vertical, candidate.error)
        }
        guard let horizontalZeroError = horizontalCandidates.first(where: { $0.shift == 0 })?.error,
              let verticalZeroError = verticalCandidates.first(where: { $0.shift == 0 })?.error
        else {
            return jointInconclusive("画面无法比较")
        }

        // A repeated diagonal pattern can appear unique on either conditional
        // one-axis slice while remaining ambiguous in two dimensions. Include
        // a joint uniqueness check so such frames fail closed.
        let globalAlternatives = candidates.filter {
            abs($0.shift.horizontal - best.shift.horizontal) >= 2
                || abs($0.shift.vertical - best.shift.vertical) >= 2
        }
        let globalAlternativeError = globalAlternatives.map(\.error).min() ?? 1
        let globalAlternativeSeparation = globalAlternativeError - best.error

        return GimbalMotionVectorEstimate(
            horizontal: classifyJointAxis(
                shift: best.shift.horizontal,
                conditionalZeroError: horizontalZeroError,
                bestError: best.error,
                candidates: horizontalCandidates,
                globalAlternativeSeparation: globalAlternativeSeparation
            ),
            vertical: classifyJointAxis(
                shift: best.shift.vertical,
                conditionalZeroError: verticalZeroError,
                bestError: best.error,
                candidates: verticalCandidates,
                globalAlternativeSeparation: globalAlternativeSeparation
            )
        )
    }

    private static func isConclusive(_ estimate: GimbalMotionEstimate) -> Bool {
        switch estimate.verdict {
        case .moved, .noResponse:
            return true
        case .inconclusive:
            return false
        }
    }

    private static func bidirectionallyValidated(
        forward: GimbalMotionEstimate,
        reverse: GimbalMotionEstimate
    ) -> GimbalMotionEstimate? {
        switch (forward.verdict, reverse.verdict) {
        case (.moved, .moved):
            guard forward.axisShift != 0,
                  reverse.axisShift != 0,
                  (forward.axisShift > 0) != (reverse.axisShift > 0),
                  abs(abs(forward.axisShift) - abs(reverse.axisShift)) <= 1
            else { return nil }
        case (.noResponse, .noResponse):
            guard abs(forward.axisShift) <= 1,
                  abs(reverse.axisShift) <= 1,
                  abs(forward.axisShift + reverse.axisShift) <= 1
            else { return nil }
        case (.moved, .noResponse),
             (.moved, .inconclusive),
             (.noResponse, .moved),
             (.noResponse, .inconclusive),
             (.inconclusive, _):
            return nil
        }

        return GimbalMotionEstimate(
            axisShift: forward.axisShift,
            zeroError: max(forward.zeroError, reverse.zeroError),
            bestError: max(forward.bestError, reverse.bestError),
            confidence: min(forward.confidence, reverse.confidence),
            verdict: forward.verdict
        )
    }

    private static func bestCandidate(
        in evaluated: [TranslationShift: Double]
    ) -> TranslationCandidate? {
        evaluated.map {
            TranslationCandidate(shift: $0.key, error: $0.value)
        }.min(by: candidatePrecedes)
    }

    private static func candidatePrecedes(
        _ lhs: TranslationCandidate,
        _ rhs: TranslationCandidate
    ) -> Bool {
        if lhs.error != rhs.error {
            return lhs.error < rhs.error
        }
        let lhsDistance = abs(lhs.shift.horizontal) + abs(lhs.shift.vertical)
        let rhsDistance = abs(rhs.shift.horizontal) + abs(rhs.shift.vertical)
        if lhsDistance == rhsDistance {
            if lhs.shift.vertical == rhs.shift.vertical {
                return lhs.shift.horizontal < rhs.shift.horizontal
            }
            return lhs.shift.vertical < rhs.shift.vertical
        }
        return lhsDistance < rhsDistance
    }

    private static func classifyJointAxis(
        shift: Int,
        conditionalZeroError: Double,
        bestError: Double,
        candidates: [(shift: Int, error: Double)],
        globalAlternativeSeparation: Double
    ) -> GimbalMotionEstimate {
        guard bestError <= maximumMotionResidual else {
            return GimbalMotionEstimate(
                axisShift: shift,
                zeroError: conditionalZeroError,
                bestError: bestError,
                confidence: 0,
                verdict: .inconclusive("画面残差过高")
            )
        }

        let alternatives = candidates.filter { abs($0.shift - shift) >= 2 }
        let alternativeError = alternatives.map(\.error).min() ?? 1
        let axisAlternativeSeparation = alternativeError - bestError
        let effectiveAlternativeSeparation = min(
            axisAlternativeSeparation,
            globalAlternativeSeparation
        )
        let uniqueness = clamp01(
            effectiveAlternativeSeparation
                / max(alternativeError, minimumAlternativeSeparation)
        )

        if abs(shift) <= 1 {
            guard conditionalZeroError <= noResponseError else {
                return GimbalMotionEstimate(
                    axisShift: shift,
                    zeroError: conditionalZeroError,
                    bestError: bestError,
                    confidence: 0,
                    verdict: .inconclusive("轴向静止证据不足")
                )
            }
            guard effectiveAlternativeSeparation >= minimumAlternativeSeparation else {
                return GimbalMotionEstimate(
                    axisShift: shift,
                    zeroError: conditionalZeroError,
                    bestError: bestError,
                    confidence: uniqueness,
                    verdict: .inconclusive("轴向静止匹配不唯一")
                )
            }
            let residualQuality = clamp01(1 - conditionalZeroError / noResponseError)
            return GimbalMotionEstimate(
                axisShift: shift,
                zeroError: conditionalZeroError,
                bestError: bestError,
                confidence: clamp01(0.75 * residualQuality + 0.25 * uniqueness),
                verdict: .noResponse
            )
        }

        let absoluteImprovement = conditionalZeroError - bestError
        let relativeImprovement = absoluteImprovement / max(conditionalZeroError, 0.000_001)
        let residualQuality = clamp01(1 - bestError / maximumMotionResidual)
        let confidence = clamp01(
            0.55 * relativeImprovement
                + 0.25 * residualQuality
                + 0.20 * uniqueness
        )

        guard abs(shift) >= minimumMovedShift,
              absoluteImprovement >= minimumAbsoluteImprovement,
              relativeImprovement >= minimumRelativeImprovement
        else {
            return GimbalMotionEstimate(
                axisShift: shift,
                zeroError: conditionalZeroError,
                bestError: bestError,
                confidence: confidence,
                verdict: .inconclusive("轴向位移证据不足")
            )
        }

        guard effectiveAlternativeSeparation >= minimumAlternativeSeparation else {
            return GimbalMotionEstimate(
                axisShift: shift,
                zeroError: conditionalZeroError,
                bestError: bestError,
                confidence: confidence,
                verdict: .inconclusive("位移方向不唯一")
            )
        }

        return GimbalMotionEstimate(
            axisShift: shift,
            zeroError: conditionalZeroError,
            bestError: bestError,
            confidence: confidence,
            verdict: .moved
        )
    }

    private static func downsampleBiPlanarLuma(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        else { return nil }

        let sourceWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let sourceHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return downsample(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        ) { x, y in
            bytes[y * bytesPerRow + x]
        }
    }

    private static func downsamplePackedColor(
        _ pixelBuffer: CVPixelBuffer,
        channelOffsets: (red: Int, green: Int, blue: Int),
        targetWidth: Int,
        targetHeight: Int
    ) -> [UInt8]? {
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return downsample(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        ) { x, y in
            let pixel = bytes.advanced(by: y * bytesPerRow + x * 4)
            let red = Int(pixel[channelOffsets.red])
            let green = Int(pixel[channelOffsets.green])
            let blue = Int(pixel[channelOffsets.blue])
            return UInt8((77 * red + 150 * green + 29 * blue + 128) >> 8)
        }
    }

    private static func downsample(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int,
        sample: (Int, Int) -> UInt8
    ) -> [UInt8]? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(targetWidth * targetHeight)

        for targetY in 0..<targetHeight {
            let yStart = targetY * sourceHeight / targetHeight
            let yEnd = min(
                sourceHeight,
                max(yStart + 1, (targetY + 1) * sourceHeight / targetHeight)
            )
            let ySamples = min(4, yEnd - yStart)

            for targetX in 0..<targetWidth {
                let xStart = targetX * sourceWidth / targetWidth
                let xEnd = min(
                    sourceWidth,
                    max(xStart + 1, (targetX + 1) * sourceWidth / targetWidth)
                )
                let xSamples = min(4, xEnd - xStart)
                var total = 0
                for sampleY in 0..<ySamples {
                    let y = yStart + (2 * sampleY + 1) * (yEnd - yStart) / (2 * ySamples)
                    for sampleX in 0..<xSamples {
                        let x = xStart + (2 * sampleX + 1) * (xEnd - xStart) / (2 * xSamples)
                        total += Int(sample(x, y))
                    }
                }
                result.append(UInt8(total / (xSamples * ySamples)))
            }
        }
        return result
    }

    private static func compensatedError(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature,
        axis: GimbalMotionAxis,
        shift: Int
    ) -> Double {
        compensatedError(
            reference: reference,
            current: current,
            horizontalShift: axis == .horizontal ? shift : 0,
            verticalShift: axis == .vertical ? shift : 0
        )
    }

    private static func compensatedError(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature,
        horizontalShift: Int,
        verticalShift: Int
    ) -> Double {
        let xStart = max(0, -horizontalShift)
        let xEnd = min(reference.width, reference.width - horizontalShift)
        let yStart = max(0, -verticalShift)
        let yEnd = min(reference.height, reference.height - verticalShift)
        guard xStart < xEnd, yStart < yEnd else { return 1 }

        var differenceTotal = 0
        var sampleCount = 0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let currentX = x + horizontalShift
                let currentY = y + verticalShift
                let referenceValue = Int(reference.luma[y * reference.width + x])
                let currentValue = Int(current.luma[currentY * current.width + currentX])
                differenceTotal += currentValue - referenceValue
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 1 }
        let brightnessOffset = Double(differenceTotal) / Double(sampleCount)

        var residualTotal = 0.0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let currentX = x + horizontalShift
                let currentY = y + verticalShift
                let referenceValue = Double(reference.luma[y * reference.width + x])
                let currentValue = Double(current.luma[currentY * current.width + currentX])
                residualTotal += abs((currentValue - referenceValue) - brightnessOffset)
            }
        }
        return residualTotal / Double(sampleCount) / 255.0
    }

    /// Scores every joint translation candidate on the exact same reference
    /// pixels. Candidate-specific overlap can hide an edge obstruction only at
    /// a non-zero shift and manufacture a unique false motion match.
    private static func compensatedErrorOnCommonROI(
        reference: GimbalMotionSignature,
        current: GimbalMotionSignature,
        horizontalShift: Int,
        verticalShift: Int,
        horizontalMargin: Int,
        verticalMargin: Int
    ) -> Double {
        let xStart = horizontalMargin
        let xEnd = reference.width - horizontalMargin
        let yStart = verticalMargin
        let yEnd = reference.height - verticalMargin
        guard xStart < xEnd,
              yStart < yEnd,
              xStart + horizontalShift >= 0,
              xEnd - 1 + horizontalShift < current.width,
              yStart + verticalShift >= 0,
              yEnd - 1 + verticalShift < current.height
        else { return 1 }

        var differenceTotal = 0
        var sampleCount = 0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let currentX = x + horizontalShift
                let currentY = y + verticalShift
                let referenceValue = Int(reference.luma[y * reference.width + x])
                let currentValue = Int(current.luma[currentY * current.width + currentX])
                differenceTotal += currentValue - referenceValue
                sampleCount += 1
            }
        }
        guard sampleCount > 0 else { return 1 }
        let brightnessOffset = Double(differenceTotal) / Double(sampleCount)

        var residualTotal = 0.0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let currentX = x + horizontalShift
                let currentY = y + verticalShift
                let referenceValue = Double(reference.luma[y * reference.width + x])
                let currentValue = Double(current.luma[currentY * current.width + currentX])
                residualTotal += abs((currentValue - referenceValue) - brightnessOffset)
            }
        }
        return residualTotal / Double(sampleCount) / 255.0
    }

    private static func inconclusive(_ reason: String) -> GimbalMotionEstimate {
        GimbalMotionEstimate(
            axisShift: 0,
            zeroError: 1,
            bestError: 1,
            confidence: 0,
            verdict: .inconclusive(reason)
        )
    }

    private static func jointInconclusive(_ reason: String) -> GimbalMotionVectorEstimate {
        let estimate = inconclusive(reason)
        return GimbalMotionVectorEstimate(horizontal: estimate, vertical: estimate)
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

enum GimbalCalibrationProbeDisposition: Equatable, Sendable {
    /// Both axes were still before any motion command was sent.
    case proceedToCommand
    /// No command was sent, so retrying cannot compound an unknown pose.
    case retryBeforeCommand
    /// The commanded-axis motion was verified and is ready for the operator's
    /// normal safety-margin decision.
    case awaitMovedStepConfirmation
    /// Neither axis showed motion after the command. Only the operator may
    /// confirm that the physical gimbal truly did not move before returning
    /// along the previously verified path.
    case awaitPhysicalNoMovementConfirmation
    /// A command was sent and the resulting pose cannot be reconstructed from
    /// the verified-step ledger. Automatic retry/return is therefore unsafe.
    case abortForUnknownPose
}

/// Pure fail-closed policy shared by the coordinator and regression tests.
/// A retry is only possible before a command has been sent. After a command,
/// anything except a clean same-axis move or a two-axis no-response requires
/// either an explicit physical no-movement confirmation or a full abort.
enum GimbalRangeCalibrationSafetyPolicy {
    static func disposition(
        commandWasSent: Bool,
        primaryVerdict: GimbalMotionVerdict,
        orthogonalVerdict: GimbalMotionVerdict,
        reversesAcceptedDirection: Bool = false,
        shiftBelowExpected: Bool = false
    ) -> GimbalCalibrationProbeDisposition {
        guard commandWasSent else {
            if case .noResponse = primaryVerdict,
               case .noResponse = orthogonalVerdict {
                return .proceedToCommand
            }
            return .retryBeforeCommand
        }

        switch primaryVerdict {
        case .moved:
            guard case .noResponse = orthogonalVerdict,
                  !reversesAcceptedDirection,
                  !shiftBelowExpected
            else { return .abortForUnknownPose }
            return .awaitMovedStepConfirmation
        case .noResponse:
            guard case .noResponse = orthogonalVerdict else {
                return .abortForUnknownPose
            }
            return .awaitPhysicalNoMovementConfirmation
        case .inconclusive:
            return .abortForUnknownPose
        }
    }
}

enum GimbalCalibrationPostCommandAutomationAction: Equatable, Sendable {
    case acceptMovedStep
    case requestNoMovementConfirmation
    case resampleObservation
    case pauseForManualRecovery
}

/// Pure policy that reduces nuisance interaction without ever resubmitting an
/// already queued probe. Geometric conflicts remain manual recovery events;
/// only transient visual uncertainty may consume the bounded resample budget.
enum GimbalRangeCalibrationAutomationPolicy {
    static let maximumObservationAttempts = 3

    static func postCommandAction(
        disposition: GimbalCalibrationProbeDisposition,
        transientVisualUncertainty: Bool,
        observationAttempt: Int,
        maximumObservationAttempts: Int = GimbalRangeCalibrationAutomationPolicy
            .maximumObservationAttempts
    ) -> GimbalCalibrationPostCommandAutomationAction {
        switch disposition {
        case .awaitMovedStepConfirmation:
            return .acceptMovedStep
        case .awaitPhysicalNoMovementConfirmation:
            return .requestNoMovementConfirmation
        case .abortForUnknownPose:
            guard observationAttempt >= 1,
                  transientVisualUncertainty,
                  observationAttempt < maximumObservationAttempts
            else { return .pauseForManualRecovery }
            return .resampleObservation
        case .proceedToCommand, .retryBeforeCommand:
            return .pauseForManualRecovery
        }
    }

    static func isTransientVisualUncertainty(
        primaryVerdict: GimbalMotionVerdict,
        orthogonalVerdict: GimbalMotionVerdict,
        reversesAcceptedDirection: Bool,
        shiftBelowExpected: Bool
    ) -> Bool {
        guard !reversesAcceptedDirection, !shiftBelowExpected else { return false }
        if case .moved = orthogonalVerdict {
            return false
        }
        if case .inconclusive = primaryVerdict {
            return true
        }
        if case .inconclusive = orthogonalVerdict {
            return true
        }
        return false
    }
}

/// Stricter evidence gate used only for unattended transitions. The ordinary
/// verdict remains useful for operator-assisted decisions, but automatic
/// ledger changes require high confidence, low residual, room inside the
/// registration search boundary, and a second consistent observation.
enum GimbalRangeCalibrationAutomaticEvidencePolicy {
    static let minimumConfidence = 0.65
    static let maximumMovedResidual = 0.06
    static let maximumStationaryResidual = 0.025

    static func isReliableStationary(_ estimate: GimbalMotionEstimate) -> Bool {
        guard case .noResponse = estimate.verdict else { return false }
        return estimate.confidence >= minimumConfidence
            && estimate.zeroError <= maximumStationaryResidual
            && estimate.bestError <= maximumStationaryResidual
            && abs(estimate.axisShift) <= 1
    }

    static func isReliableStationary(_ estimate: GimbalMotionVectorEstimate) -> Bool {
        isReliableStationary(estimate.horizontal)
            && isReliableStationary(estimate.vertical)
    }

    static func isReliableMoved(
        primary: GimbalMotionEstimate,
        orthogonal: GimbalMotionEstimate,
        axis: GimbalMotionAxis
    ) -> Bool {
        guard case .moved = primary.verdict,
              isReliableStationary(orthogonal)
        else { return false }
        // The 128×72 calibration signature searches ±32 horizontally and
        // ±18 vertically. Keep a two-pixel margin from either boundary so a
        // saturated fit can never authorize unattended bookkeeping.
        let maximumReliableShift = axis == .horizontal ? 30 : 16
        return primary.confidence >= minimumConfidence
            && primary.bestError <= maximumMovedResidual
            && abs(primary.axisShift) >= 2
            && abs(primary.axisShift) <= maximumReliableShift
    }

    static func movedObservationsAreConsistent(
        _ first: GimbalMotionEstimate,
        _ second: GimbalMotionEstimate
    ) -> Bool {
        guard first.axisShift != 0, second.axisShift != 0 else { return false }
        return (first.axisShift > 0) == (second.axisShift > 0)
            && abs(first.axisShift - second.axisShift) <= 1
    }
}

enum GimbalRangeCalibrationRecoveryAction: Equatable, Sendable {
    case pauseForManualRecovery
    case terminate
}

enum GimbalRangeCalibrationRecoveryPolicy {
    /// Unknown post-command motion can remain inside the current calibration
    /// lease only after a STOP was accepted and both leases are still valid.
    /// Otherwise there is no safe way to promise that another command cannot
    /// be issued, so the entire calibration must terminate fail-closed.
    static func action(
        stopAccepted: Bool,
        sessionsAreValid: Bool
    ) -> GimbalRangeCalibrationRecoveryAction {
        stopAccepted && sessionsAreValid ? .pauseForManualRecovery : .terminate
    }
}
