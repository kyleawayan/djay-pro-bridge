import Foundation
import Network

public class OSCSender {
    private let connection: NWConnection

    public init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connection.start(queue: DispatchQueue(label: "osc-sender"))
    }

    public func sendKeyChange(rootNoteIndex: Int, scale: String) {
        let msg1 = oscMessage(address: "/root-key-change", intArg: Int32(rootNoteIndex))
        let msg2 = oscMessage(address: "/scale-name-change", stringArg: scale)
        let bundle = oscBundle(messages: [msg1, msg2])
        connection.send(content: bundle, completion: .contentProcessed { _ in })
    }

    // MARK: - OSC encoding

    private func oscMessage(address: String, intArg: Int32) -> Data {
        var data = Data()
        data.append(oscString(address))
        data.append(oscString(",i"))
        data.append(oscInt32(intArg))
        return data
    }

    private func oscMessage(address: String, stringArg: String) -> Data {
        var data = Data()
        data.append(oscString(address))
        data.append(oscString(",s"))
        data.append(oscString(stringArg))
        return data
    }

    private func oscBundle(messages: [Data]) -> Data {
        var data = Data()
        // Bundle header: "#bundle\0"
        data.append(oscString("#bundle"))
        // Timetag: 1 = "immediately"
        var timetag: UInt64 = 1
        data.append(Data(bytes: &timetag, count: 8))
        // Each message prefixed with its size as int32
        for msg in messages {
            data.append(oscInt32(Int32(msg.count)))
            data.append(msg)
        }
        return data
    }

    /// Null-terminated string padded to 4-byte boundary.
    private func oscString(_ s: String) -> Data {
        var data = Data(s.utf8)
        data.append(0)  // null terminator
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    /// Big-endian 32-bit integer.
    private func oscInt32(_ value: Int32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }
}
