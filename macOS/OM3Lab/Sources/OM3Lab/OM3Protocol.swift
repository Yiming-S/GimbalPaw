import Foundation

enum OM3MotionMode: UInt8 {
    case relative = 0x04
    case absolute = 0x05
    case speed = 0x80

    var command: UInt8 {
        switch self {
        case .relative, .absolute:
            return 0x14
        case .speed:
            return 0x0c
        }
    }
}

enum OM3ProtocolError: LocalizedError, Equatable {
    case valueOutOfRange(String)

    var errorDescription: String? {
        switch self {
        case let .valueOutOfRange(field):
            return "\(field) 超出 Int16 范围"
        }
    }
}

enum OM3Protocol {
    static let testStepDegrees = 5
    static let testDurationTenths: UInt8 = 10

    static func crc16<S: Sequence>(_ bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0xdf0c

        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 == 1 {
                    crc = (crc >> 1) ^ 0x8408
                } else {
                    crc >>= 1
                }
            }
        }

        return crc
    }

    static func rotationMessage(
        yawTenths: Int,
        pitchTenths: Int,
        rollTenths: Int = 0,
        mode: OM3MotionMode = .relative,
        durationTenths: UInt8 = testDurationTenths
    ) throws -> Data {
        let yaw = try int16(yawTenths, field: "yaw")
        let pitch = try int16(pitchTenths, field: "pitch")
        let roll = try int16(rollTenths, field: "roll")

        let header: [UInt8] = [0x55, 0x15, 0x04, 0xa9]
        var body: [UInt8] = [0x02, 0x04, 0x01, 0x00, 0x00, 0x04, mode.command]
        body.append(contentsOf: littleEndianBytes(yaw))
        body.append(contentsOf: littleEndianBytes(roll))
        body.append(contentsOf: littleEndianBytes(pitch))
        body.append(mode.rawValue)
        body.append(durationTenths)

        let checksum = crc16(body)
        return Data(header + body + [UInt8(checksum & 0xff), UInt8(checksum >> 8)])
    }

    static func relativeNudge(yawDegrees: Int, pitchDegrees: Int) throws -> Data {
        try relativeMove(
            yawTenths: yawDegrees * 10,
            pitchTenths: pitchDegrees * 10,
            durationTenths: testDurationTenths
        )
    }

    static func relativeMove(
        yawTenths: Int,
        pitchTenths: Int,
        durationTenths: UInt8
    ) throws -> Data {
        try rotationMessage(
            yawTenths: yawTenths,
            pitchTenths: pitchTenths,
            mode: .relative,
            durationTenths: durationTenths
        )
    }

    static func stopMessage() throws -> Data {
        try rotationMessage(
            yawTenths: 0,
            pitchTenths: 0,
            rollTenths: 0,
            mode: .speed,
            durationTenths: 0
        )
    }

    static func hex(_ data: Data, limit: Int? = nil) -> String {
        let bytes = limit.map { data.prefix($0) } ?? data[...]
        let value = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        return limit.map { data.count > $0 ? value + " …" : value } ?? value
    }

    private static func int16(_ value: Int, field: String) throws -> Int16 {
        guard let converted = Int16(exactly: value) else {
            throw OM3ProtocolError.valueOutOfRange(field)
        }
        return converted
    }

    private static func littleEndianBytes(_ value: Int16) -> [UInt8] {
        let bits = UInt16(bitPattern: value)
        return [UInt8(bits & 0xff), UInt8(bits >> 8)]
    }
}
