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

enum GimbalMotionAnalysis {
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
        let xStart = axis == .horizontal ? max(0, -shift) : 0
        let xEnd = axis == .horizontal ? min(reference.width, reference.width - shift) : reference.width
        let yStart = axis == .vertical ? max(0, -shift) : 0
        let yEnd = axis == .vertical ? min(reference.height, reference.height - shift) : reference.height
        guard xStart < xEnd, yStart < yEnd else { return 1 }

        var differenceTotal = 0
        var sampleCount = 0
        for y in yStart..<yEnd {
            for x in xStart..<xEnd {
                let currentX = axis == .horizontal ? x + shift : x
                let currentY = axis == .vertical ? y + shift : y
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
                let currentX = axis == .horizontal ? x + shift : x
                let currentY = axis == .vertical ? y + shift : y
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

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
