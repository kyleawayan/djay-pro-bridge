import Foundation

public struct RealtimeTelemetry: Equatable, Sendable {
    public let deckIndex: UInt64?
    public let position: Double?
    public let rate: Double?
    public let senderClock: Double?
}

public enum DecodedMessage: Equatable, Sendable {
    case realtime(RealtimeTelemetry)
    case identification(version: String?)
    case image(bytes: Int, isJPEG: Bool)
    case unknown(field: UInt64?)
    case malformed

    public var title: String {
        switch self {
        case .realtime: return "Position / rate"
        case .identification: return "App identification"
        case .image: return "Cached image"
        case .unknown(let field): return field.map { "Unknown field \($0)" } ?? "Unrecognized envelope"
        case .malformed: return "Malformed payload"
        }
    }
    public var field: UInt64? {
        switch self {
        case .realtime: return 51
        case .identification: return 1
        case .image: return 90
        case .unknown(let field): return field
        case .malformed: return nil
        }
    }
}

enum WireValue {
    case integer(UInt64)
    case bytes([UInt8])
    case fixed64(UInt64)
    case fixed32(UInt32)
}

private enum DecodeError: Error { case invalid }

public enum SystemOneDecoder {
    public static func decode(_ frame: [UInt8]) -> DecodedMessage {
        guard frame.count >= 7,
              frame.prefix(6).elementsEqual([0xf0, 0x70, 0x00, 0x00, 0x01, 0x00]),
              frame.last == 0xf7 else { return .unknown(field: nil) }
        do {
            let payload = try unpack(Array(frame.dropFirst(6).dropLast()))
            let outer = try wireFields(payload)
            guard outer.count == 1, let top = outer.first, case .bytes(let body) = top.1 else { return .malformed }
            guard [1, 51, 90].contains(top.0) else { return .unknown(field: top.0) }
            let nested = try wireFields(body)
            func value(_ index: UInt64) -> WireValue? { nested.last(where: { $0.0 == index })?.1 }
            func number(_ index: UInt64) throws -> Double? {
                guard let item = value(index) else { return nil }
                guard case .fixed64(let bits) = item else { throw DecodeError.invalid }
                let result = Double(bitPattern: bits)
                guard result.isFinite else { throw DecodeError.invalid }
                return result
            }
            switch top.0 {
            case 51:
                var index: UInt64?
                if let item = value(1) {
                    guard case .integer(let raw) = item else { throw DecodeError.invalid }
                    index = raw
                }
                return .realtime(RealtimeTelemetry(deckIndex: index ?? 0, position: try number(2) ?? 0,
                                                   rate: try number(3) ?? 0, senderClock: try number(4) ?? 0))
            case 1:
                var version: String?
                if case .bytes(let data) = value(2), data.count <= 32,
                   let text = String(bytes: data, encoding: .utf8),
                   text.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil {
                    version = text
                }
                return .identification(version: version)
            default:
                guard case .bytes(let image) = value(2) else { return .image(bytes: 0, isJPEG: false) }
                return .image(bytes: image.count, isJPEG: image.prefix(3).elementsEqual([0xff, 0xd8, 0xff]))
            }
        } catch { return .malformed }
    }

    static func unpack(_ bytes: [UInt8]) throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count * 7 / 8)
        var accumulator: UInt64 = 0
        var bits = 0
        for byte in bytes {
            guard byte < 128 else { throw DecodeError.invalid }
            accumulator |= UInt64(byte) << bits
            bits += 7
            while bits >= 8 {
                result.append(UInt8(accumulator & 255))
                accumulator >>= 8
                bits -= 8
            }
        }
        return result
    }

    static func wireFields(_ bytes: [UInt8]) throws -> [(UInt64, WireValue)] {
        var index = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw DecodeError.invalid }
                let byte = bytes[index]
                index += 1
                guard shift != 63 || byte <= 1 else { throw DecodeError.invalid }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            throw DecodeError.invalid
        }
        func take(_ size: Int) throws -> [UInt8] {
            guard size >= 0 && size <= bytes.count - index else { throw DecodeError.invalid }
            let value = Array(bytes[index..<index + size])
            index += size
            return value
        }
        var result: [(UInt64, WireValue)] = []
        while index < bytes.count {
            let tag = try varint(), field = tag >> 3
            guard field > 0 else { throw DecodeError.invalid }
            let value: WireValue
            switch tag & 7 {
            case 0: value = .integer(try varint())
            case 1:
                let data = try take(8)
                let bits = data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
                value = .fixed64(bits)
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - index) else { throw DecodeError.invalid }
                value = .bytes(try take(Int(count)))
            case 5:
                let data = try take(4)
                let bits = data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                value = .fixed32(bits)
            default: throw DecodeError.invalid
            }
            result.append((field, value))
        }
        return result
    }
}
