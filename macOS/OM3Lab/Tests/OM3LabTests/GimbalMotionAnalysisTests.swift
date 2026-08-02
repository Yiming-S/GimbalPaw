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
