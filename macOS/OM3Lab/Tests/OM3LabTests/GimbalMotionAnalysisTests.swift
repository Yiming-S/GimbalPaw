import XCTest
@testable import OM3Lab

final class GimbalMotionAnalysisTests: XCTestCase {
    func testDetectsPositiveHorizontalTranslation() {
        assertMoved(dx: 5, dy: 0, axis: .horizontal, expectedShift: 5)
    }

    func testDetectsNegativeHorizontalTranslation() {
        assertMoved(dx: -4, dy: 0, axis: .horizontal, expectedShift: -4)
    }

    func testDetectsPositiveVerticalTranslation() {
        assertMoved(dx: 0, dy: 4, axis: .vertical, expectedShift: 4)
    }

    func testDetectsNegativeVerticalTranslation() {
        assertMoved(dx: 0, dy: -3, axis: .vertical, expectedShift: -3)
    }

    func testStationaryFrameIsNoResponse() {
        let reference = richSignature()
        let estimate = GimbalMotionAnalysis.estimate(
            reference: reference,
            current: reference,
            axis: .horizontal
        )

        XCTAssertEqual(estimate.axisShift, 0)
        XCTAssertEqual(estimate.zeroError, 0, accuracy: 0.000_001)
        XCTAssertEqual(estimate.bestError, 0, accuracy: 0.000_001)
        XCTAssertEqual(estimate.verdict, .noResponse)
        XCTAssertEqual(estimate.confidence, 1, accuracy: 0.000_001)
    }

    func testJointHorizontalTranslationCompensatesOrthogonalResidual() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: shifted(reference, dx: 12, dy: 0)
        )

        XCTAssertEqual(estimates.horizontal.axisShift, 12)
        XCTAssertEqual(estimates.horizontal.verdict, .moved)
        XCTAssertEqual(estimates.vertical.axisShift, 0)
        XCTAssertEqual(estimates.vertical.verdict, .noResponse)
        XCTAssertLessThanOrEqual(estimates.vertical.zeroError, 0.035)
    }

    func testJointVerticalTranslationCompensatesOrthogonalResidual() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: shifted(reference, dx: 0, dy: -9)
        )

        XCTAssertEqual(estimates.horizontal.axisShift, 0)
        XCTAssertEqual(estimates.horizontal.verdict, .noResponse)
        XCTAssertEqual(estimates.vertical.axisShift, -9)
        XCTAssertEqual(estimates.vertical.verdict, .moved)
        XCTAssertLessThanOrEqual(estimates.horizontal.zeroError, 0.035)
    }

    func testJointDiagonalTranslationMovesBothAxes() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: shifted(reference, dx: 7, dy: -5)
        )

        XCTAssertEqual(estimates.horizontal.axisShift, 7)
        XCTAssertEqual(estimates.horizontal.verdict, .moved)
        XCTAssertEqual(estimates.vertical.axisShift, -5)
        XCTAssertEqual(estimates.vertical.verdict, .moved)
    }

    func testJointExactSearchIncludesTranslationCorner() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: shifted(reference, dx: 16, dy: -9)
        )

        XCTAssertEqual(estimates.horizontal.axisShift, 16)
        XCTAssertEqual(estimates.horizontal.verdict, .moved)
        XCTAssertEqual(estimates.vertical.axisShift, -9)
        XCTAssertEqual(estimates.vertical.verdict, .moved)
    }

    func testJointExactSearchIncludesBoundaryColumnInterior() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: shifted(reference, dx: 16, dy: -3)
        )

        XCTAssertEqual(estimates.horizontal.axisShift, 16)
        XCTAssertEqual(estimates.horizontal.verdict, .moved)
        XCTAssertEqual(estimates.vertical.axisShift, -3)
        XCTAssertEqual(estimates.vertical.verdict, .moved)
    }

    func testJointExactSearchIncludesBoundaryRowInterior() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: shifted(reference, dx: 5, dy: 9)
        )

        XCTAssertEqual(estimates.horizontal.axisShift, 5)
        XCTAssertEqual(estimates.horizontal.verdict, .moved)
        XCTAssertEqual(estimates.vertical.axisShift, 9)
        XCTAssertEqual(estimates.vertical.verdict, .moved)
    }

    func testJointStationaryFrameIsNoResponseOnBothAxes() {
        let reference = richSignature()
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: reference
        )

        XCTAssertEqual(estimates.horizontal.verdict, .noResponse)
        XCTAssertEqual(estimates.vertical.verdict, .noResponse)
        XCTAssertEqual(estimates.horizontal.confidence, 1, accuracy: 0.000_001)
        XCTAssertEqual(estimates.vertical.confidence, 1, accuracy: 0.000_001)
    }

    func testJointNoResponseRequiresUniqueMatchOnEachAxis() {
        let width = 64
        let height = 36
        let luma = (0..<(width * height)).map { index -> UInt8 in
            let y = index / width
            return UInt8(32 + positiveModulo(y * 71 + (y / 3) * 43, 192))
        }
        let horizontallyAmbiguous = GimbalMotionSignature(
            width: width,
            height: height,
            luma: luma
        )
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: horizontallyAmbiguous,
            current: horizontallyAmbiguous
        )

        guard case let .inconclusive(reason) = estimates.horizontal.verdict else {
            return XCTFail("无水平辨识度的画面不能被判断为水平静止")
        }
        XCTAssertTrue(reason.contains("不唯一"))
    }

    func testJointCommonROIPreventsEdgeOcclusionFromFakingMotion() {
        let width = 128
        let height = 72
        let referenceLuma = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width
            let y = index / width
            return UInt8(24 + positiveModulo((x % 20) * 9 + y * 17 + (y / 3) * 29, 208))
        }
        let reference = GimbalMotionSignature(
            width: width,
            height: height,
            luma: referenceLuma
        )
        var occludedLuma = referenceLuma
        for y in 0..<height {
            for x in 0..<20 {
                let index = y * width + x
                occludedLuma[index] = UInt8(255 - Int(occludedLuma[index]))
            }
        }
        let occluded = GimbalMotionSignature(
            width: width,
            height: height,
            luma: occludedLuma
        )

        let estimate = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: occluded
        )

        XCTAssertNotEqual(estimate.horizontal.verdict, .moved)
        guard case let .inconclusive(reason) = estimate.horizontal.verdict else {
            return XCTFail("边缘遮挡后的周期画面必须保持不确定，而不是授权自动位移")
        }
        XCTAssertTrue(reason.contains("不唯一"))
    }

    func testJointBidirectionalValidationRejectsCentralOcclusion() {
        let width = 128
        let height = 72
        let referenceLuma = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width
            let y = index / width
            return UInt8(24 + positiveModulo((x % 20) * 9 + y * 17 + (y / 3) * 29, 208))
        }
        let reference = GimbalMotionSignature(
            width: width,
            height: height,
            luma: referenceLuma
        )
        var occludedLuma = referenceLuma
        // This band begins at the common ROI's left edge. A forward-only fit
        // can evade it with +20 px and produce a perfect, but false, match.
        for y in 0..<height {
            for x in 32..<52 {
                let index = y * width + x
                occludedLuma[index] = UInt8(255 - Int(occludedLuma[index]))
            }
        }
        let occluded = GimbalMotionSignature(
            width: width,
            height: height,
            luma: occludedLuma
        )

        let estimate = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: occluded
        )

        XCTAssertNotEqual(estimate.horizontal.verdict, .moved)
        guard case let .inconclusive(reason) = estimate.horizontal.verdict else {
            return XCTFail("中心遮挡不能被判定为云台位移")
        }
        XCTAssertTrue(reason.contains("双向"))
    }

    func testLowTextureFrameIsInconclusive() {
        let flat = GimbalMotionSignature(
            width: 64,
            height: 36,
            luma: Array(repeating: 128, count: 64 * 36)
        )
        let estimate = GimbalMotionAnalysis.estimate(
            reference: flat,
            current: flat,
            axis: .horizontal
        )

        guard case let .inconclusive(reason) = estimate.verdict else {
            return XCTFail("低纹理画面不应被判断为静止边界")
        }
        XCTAssertTrue(reason.contains("纹理"))
    }

    func testJointLowTextureFrameIsInconclusiveOnBothAxes() {
        let flat = GimbalMotionSignature(
            width: 64,
            height: 36,
            luma: Array(repeating: 128, count: 64 * 36)
        )
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: flat,
            current: flat
        )

        guard case .inconclusive = estimates.horizontal.verdict,
              case .inconclusive = estimates.vertical.verdict
        else {
            return XCTFail("低纹理画面必须在两轴上都保持 fail-closed")
        }
    }

    func testTranslationSurvivesModerateExposureOffset() {
        let reference = richSignature()
        let translated = shifted(reference, dx: 6, dy: 0, exposureOffset: 24)
        let estimate = GimbalMotionAnalysis.estimate(
            reference: reference,
            current: translated,
            axis: .horizontal
        )

        XCTAssertEqual(estimate.axisShift, 6)
        XCTAssertEqual(estimate.verdict, .moved)
        XCTAssertGreaterThan(estimate.confidence, 0.60)
    }

    func testUnrelatedFrameIsInconclusive() {
        let reference = richSignature(seed: 0)
        let unrelated = richSignature(seed: 91)
        let estimate = GimbalMotionAnalysis.estimate(
            reference: reference,
            current: unrelated,
            axis: .horizontal
        )

        guard case .inconclusive = estimate.verdict else {
            return XCTFail("不匹配画面不应被判断为有效运动")
        }
        XCTAssertNotEqual(estimate.verdict, .moved)
        XCTAssertNotEqual(estimate.verdict, .noResponse)
    }

    func testJointUnrelatedFrameIsInconclusiveOnBothAxes() {
        let reference = richSignature(seed: 0)
        let unrelated = richSignature(seed: 91)
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: unrelated
        )

        guard case .inconclusive = estimates.horizontal.verdict,
              case .inconclusive = estimates.vertical.verdict
        else {
            return XCTFail("不匹配画面必须在两轴上都保持 fail-closed")
        }
    }

    func testLargeExposureChangeIsInconclusive() {
        let reference = richSignature()
        let overexposed = GimbalMotionSignature(
            width: reference.width,
            height: reference.height,
            luma: reference.luma.map { UInt8(min(255, Int($0) + 90)) }
        )
        let estimate = GimbalMotionAnalysis.estimate(
            reference: reference,
            current: overexposed,
            axis: .vertical
        )

        guard case let .inconclusive(reason) = estimate.verdict else {
            return XCTFail("大幅曝光变化不应当作云台运动")
        }
        XCTAssertTrue(reason.contains("曝光"))
    }

    func testJointLargeExposureChangeIsInconclusiveOnBothAxes() {
        let reference = richSignature()
        let overexposed = GimbalMotionSignature(
            width: reference.width,
            height: reference.height,
            luma: reference.luma.map { UInt8(min(255, Int($0) + 90)) }
        )
        let estimates = GimbalMotionAnalysis.estimateTranslation(
            reference: reference,
            current: overexposed
        )

        guard case .inconclusive = estimates.horizontal.verdict,
              case .inconclusive = estimates.vertical.verdict
        else {
            return XCTFail("曝光突变必须在两轴上都保持 fail-closed")
        }
    }

    private func assertMoved(
        dx: Int,
        dy: Int,
        axis: GimbalMotionAxis,
        expectedShift: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reference = richSignature()
        let current = shifted(reference, dx: dx, dy: dy)
        let estimate = GimbalMotionAnalysis.estimate(
            reference: reference,
            current: current,
            axis: axis
        )

        XCTAssertEqual(estimate.axisShift, expectedShift, file: file, line: line)
        XCTAssertEqual(estimate.verdict, .moved, file: file, line: line)
        XCTAssertGreaterThan(estimate.zeroError, estimate.bestError, file: file, line: line)
        XCTAssertGreaterThan(estimate.confidence, 0.60, file: file, line: line)
    }

    private func richSignature(seed: Int = 0) -> GimbalMotionSignature {
        let width = 64
        let height = 36
        let luma = (0..<(width * height)).map { index -> UInt8 in
            let x = index % width
            let y = index / width
            let mixed = x * 29
                + y * 47
                + x * y * 7
                + (x / 3) * 31
                + (y / 5) * 53
                + seed * (x * 11 + y * 17 + 19)
            return UInt8(24 + positiveModulo(mixed, 184))
        }
        return GimbalMotionSignature(width: width, height: height, luma: luma)
    }

    private func shifted(
        _ signature: GimbalMotionSignature,
        dx: Int,
        dy: Int,
        exposureOffset: Int = 0
    ) -> GimbalMotionSignature {
        var output = Array(repeating: UInt8(0), count: signature.luma.count)
        for y in 0..<signature.height {
            for x in 0..<signature.width {
                let sourceX = min(signature.width - 1, max(0, x - dx))
                let sourceY = min(signature.height - 1, max(0, y - dy))
                let source = Int(signature.luma[sourceY * signature.width + sourceX])
                output[y * signature.width + x] = UInt8(
                    min(255, max(0, source + exposureOffset))
                )
            }
        }
        return GimbalMotionSignature(
            width: signature.width,
            height: signature.height,
            luma: output
        )
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
