import Foundation

public struct MessageAssembly: Sendable {
    public let frame: [UInt8]?
    public let status: String
}

public struct MessageAssembler {
    private var payload: [UInt8] = []
    private var expectedIndex = 0
    private var expectedCount = 0
    private var lastTime: Double = 0
    public init() {}

    public mutating func consume(_ frame: [UInt8], time: Double) -> MessageAssembly {
        guard frame.count >= 7, frame[0] == 0xf0, frame[1] == 0x70, frame.last == 0xf7,
              frame.dropFirst(2).dropLast().allSatisfy({ $0 < 128 }) else {
            reset(); return MessageAssembly(frame: nil, status: "Unknown envelope")
        }
        let index = Int(frame[2]) | Int(frame[3]) << 7
        let count = Int(frame[4]) | Int(frame[5]) << 7
        guard count > 0, count <= 1024, index < count else {
            reset(); return MessageAssembly(frame: nil, status: "Invalid fragment header")
        }
        if time - lastTime > 10 || time < lastTime { reset() }
        if index == 0 { reset(); expectedCount = count }
        guard index == expectedIndex, count == expectedCount else {
            reset(); return MessageAssembly(frame: nil, status: "Missing or reordered fragment")
        }
        guard payload.count + frame.count - 7 <= 4 * 1_048_576 else {
            reset(); return MessageAssembly(frame: nil, status: "Assembly exceeds 4 MiB")
        }
        payload.append(contentsOf: frame.dropFirst(6).dropLast())
        expectedIndex += 1
        lastTime = time
        if expectedIndex == count {
            // Packing happens before fragmentation; unpack only after concatenating every fragment.
            let normalized = [UInt8(0xf0), 0x70, 0, 0, 1, 0] + payload + [0xf7]
            reset()
            return MessageAssembly(frame: normalized, status: count == 1 ? "Single packet" : "Reassembled \(count) fragments")
        }
        return MessageAssembly(frame: nil, status: "Fragment \(index + 1)/\(count)")
    }

    private mutating func reset() { payload = []; expectedIndex = 0; expectedCount = 0 }
}
