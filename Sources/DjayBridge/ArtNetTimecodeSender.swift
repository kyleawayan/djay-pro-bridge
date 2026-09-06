import Foundation
import Network

/// Sends Art-Net timecode (ArtTimeCode, OpCode 0x9700) over UDP.
/// See the Art-Net 4 spec, section on ArtTimeCode.
public class ArtNetTimecodeSender {
    private let connection: NWConnection
    private let fps: Double
    private let typeByte: UInt8

    public enum Framerate {
        case film24, ebu25, dropFrame2997, smpte30

        var fps: Double {
            switch self {
            case .film24: return 24
            case .ebu25: return 25
            // 29.97 drop-frame counts 30 frame slots per second; the drop is in
            // the numbering, not the packet's frame field, so treat it as 30 here.
            case .dropFrame2997: return 30
            case .smpte30: return 30
            }
        }

        /// The Type field value the Art-Net spec assigns to each rate.
        var typeByte: UInt8 {
            switch self {
            case .film24: return 0
            case .ebu25: return 1
            case .dropFrame2997: return 2
            case .smpte30: return 3
            }
        }

        /// Parse a CLI value like "24", "25", "29.97", "30".
        public static func parse(_ s: String) -> Framerate? {
            switch s {
            case "24": return .film24
            case "25": return .ebu25
            case "29.97", "29", "2997": return .dropFrame2997
            case "30": return .smpte30
            default: return nil
            }
        }
    }

    public init(host: String, port: UInt16, framerate: Framerate) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            fatalError("Invalid port: \(port)")
        }
        self.fps = framerate.fps
        self.typeByte = framerate.typeByte
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: .udp
        )
        connection.start(queue: DispatchQueue(label: "artnet-sender"))
    }

    deinit {
        connection.cancel()
    }

    /// Sends the given time (seconds) as an ArtTimeCode packet.
    public func send(seconds: Double) {
        let packet = Self.buildPacket(seconds: max(0, seconds), fps: fps, typeByte: typeByte)
        connection.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                printError("ArtNetTimecodeSender: failed to send: \(error)")
            }
        })
    }

    // MARK: - Packet encoding

    static func buildPacket(seconds: Double, fps: Double, typeByte: UInt8) -> Data {
        // Timecode fields wrap at their SMPTE maximums; the hours field is 0-23.
        let totalFrames = Int((seconds * fps).rounded(.down))
        let framesPerSec = Int(fps.rounded())
        let frames = totalFrames % framesPerSec
        let totalSecs = totalFrames / framesPerSec
        let secs = totalSecs % 60
        let mins = (totalSecs / 60) % 60
        let hours = (totalSecs / 3600) % 24

        var data = Data()
        // ID: "Art-Net" + null
        data.append(contentsOf: Array("Art-Net".utf8))
        data.append(0)
        // OpCode 0x9700 (OpTimeCode), transmitted low byte first
        data.append(0x00)
        data.append(0x97)
        // Protocol version 14, high byte first
        data.append(0)
        data.append(14)
        // Filler1, Filler2
        data.append(0)
        data.append(0)
        // Frames, Seconds, Minutes, Hours
        data.append(UInt8(frames))
        data.append(UInt8(secs))
        data.append(UInt8(mins))
        data.append(UInt8(hours))
        // Type (framerate)
        data.append(typeByte)
        return data
    }
}
