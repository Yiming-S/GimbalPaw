import XCTest
@testable import OM3Lab

final class OM3ProtocolTests: XCTestCase {
    func testKnownPositiveYawFrame() throws {
        let frame = try OM3Protocol.relativeNudge(yawDegrees: 5, pitchDegrees: 0)

        XCTAssertEqual(
            OM3Protocol.hex(frame),
            "55 15 04 a9 02 04 01 00 00 04 14 32 00 00 00 00 00 04 0a 39 cd"
        )
        XCTAssertEqual(frame.count, 21)
    }

    func testAllFixedNudgeGoldenFrames() throws {
        let cases: [(Int, Int, String)] = [
            (-5, 0, "55 15 04 a9 02 04 01 00 00 04 14 ce ff 00 00 00 00 04 0a 65 3b"),
            (0, 5, "55 15 04 a9 02 04 01 00 00 04 14 00 00 00 00 32 00 04 0a 5a 5e"),
            (0, -5, "55 15 04 a9 02 04 01 00 00 04 14 00 00 00 00 ce ff 04 0a b6 78"),
        ]

        for (yaw, pitch, expected) in cases {
            XCTAssertEqual(
                OM3Protocol.hex(try OM3Protocol.relativeNudge(yawDegrees: yaw, pitchDegrees: pitch)),
                expected
            )
        }
    }

    func testStopFrameUsesSpeedCommandAndMode() throws {
        let frame = try OM3Protocol.stopMessage()

        XCTAssertEqual(frame.count, 21)
        XCTAssertEqual(frame[10], 0x0c)
        XCTAssertEqual(frame[17], 0x80)
        XCTAssertEqual(frame[18], 0x00)
        XCTAssertEqual(
            OM3Protocol.hex(frame),
            "55 15 04 a9 02 04 01 00 00 04 0c 00 00 00 00 00 00 80 00 76 ef"
        )
    }

    func testNegativeValuesAreLittleEndian() throws {
        let frame = try OM3Protocol.relativeNudge(yawDegrees: -5, pitchDegrees: -5)

        XCTAssertEqual(frame[11], 0xce)
        XCTAssertEqual(frame[12], 0xff)
        XCTAssertEqual(frame[15], 0xce)
        XCTAssertEqual(frame[16], 0xff)
    }

    func testVerticalPersonSearchCorrectionsOccupyPitchField() throws {
        for (direction, expectedPitch) in [
            (PersonSearchDirection.up, -PersonSearchPolicy.scanStepTenths),
            (PersonSearchDirection.down, PersonSearchPolicy.scanStepTenths),
        ] {
            let correction = PersonSearchPolicy.requestedStep(direction: direction, mode: .scan)
            let frame = try OM3Protocol.relativeMove(
                yawTenths: correction.yawTenths,
                pitchTenths: correction.pitchTenths,
                durationTenths: PersonSearchPolicy.scanDurationTenths
            )
            XCTAssertEqual(frame[11], 0)
            XCTAssertEqual(frame[12], 0)
            let encodedPitch = Int16(
                bitPattern: UInt16(frame[15]) | UInt16(frame[16]) << 8
            )
            XCTAssertEqual(Int(encodedPitch), expectedPitch)
            XCTAssertEqual(frame[18], PersonSearchPolicy.scanDurationTenths)
        }
    }

    func testOutOfRangeValueIsRejected() {
        XCTAssertThrowsError(
            try OM3Protocol.rotationMessage(yawTenths: 40_000, pitchTenths: 0)
        )
    }
}
