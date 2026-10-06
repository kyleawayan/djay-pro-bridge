import Foundation

public enum StartupKeepalive {
    public static func frame() -> [UInt8] {
        func string(_ field: UInt8, _ value: String) -> [UInt8] {
            let bytes = Array(value.utf8)
            precondition(bytes.count < 128)
            return [field << 3 | 2, UInt8(bytes.count)] + bytes
        }
        // Identify this application truthfully; no controller firmware identity is fabricated.
        let body = string(1, "System One Inspector") + string(2, "0.1.0")
        let protobuf = [UInt8(0x0a), UInt8(body.count)] + body
        var result: [UInt8] = [0xf0,0x70,0,0,1,0]
        var accumulator: UInt64 = 0, bits = 0
        for byte in protobuf {
            accumulator |= UInt64(byte) << bits
            bits += 8
            while bits >= 7 { result.append(UInt8(accumulator & 127)); accumulator >>= 7; bits -= 7 }
        }
        if bits > 0 { result.append(UInt8(accumulator & 127)) }
        return result + [0xf7]
    }
}
