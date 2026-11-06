import CryptoKit
import Foundation

/// One `GetRecordStatus` round trip, stamped with `CLOCK_UPTIME_RAW` on both ends.
public struct OBSSyncSample: Equatable, Sendable {
    public let sentNS: UInt64
    public let receivedNS: UInt64
    public let active: Bool
    public let paused: Bool
    /// Recording position reported by OBS; obs-websocket derives it from frames written, so it steps once per frame.
    public let videoMS: Double

    public init(sentNS: UInt64, receivedNS: UInt64, active: Bool, paused: Bool, videoMS: Double) {
        self.sentNS = sentNS; self.receivedNS = receivedNS; self.active = active; self.paused = paused; self.videoMS = videoMS
    }

    public var midNS: UInt64 { sentNS + (receivedNS &- sentNS) / 2 }
    public var rttMS: Double { Double(receivedNS &- sentNS) / 1e6 }
}

/// A `RecordStateChanged` event. Its clock is the receive time; one-way latency is unknown.
public struct OBSRecordState: Equatable, Sendable {
    public let receivedNS: UInt64
    public let state: String
    public let active: Bool
    public let path: String?

    public init(receivedNS: UInt64, state: String, active: Bool, path: String?) {
        self.receivedNS = receivedNS; self.state = state; self.active = active; self.path = path
    }
}

public struct OBSProtocolError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum OBSMessage: Equatable {
    case hello(challenge: String?, salt: String?)
    case identified
    case recordStatus(requestID: String, active: Bool, paused: Bool, videoMS: Double)
    case requestFailed(requestID: String, comment: String)
    case requestSucceeded(requestID: String)
    case recordStateChanged(state: String, active: Bool, path: String?)
    case other
}

/// obs-websocket 5.x message encoding. https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md
public enum OBSProtocol {
    static let rpcVersion = 1
    static let outputsSubscription = 1 << 6

    public static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    public static func identify(challenge: String?, salt: String?, password: String?) throws -> Data {
        var d: [String: Any] = ["rpcVersion": rpcVersion, "eventSubscriptions": outputsSubscription]
        if let challenge, let salt {
            guard let password, !password.isEmpty else { throw OBSProtocolError("OBS requires a WebSocket password") }
            d["authentication"] = authentication(password: password, salt: salt, challenge: challenge)
        }
        return try JSONSerialization.data(withJSONObject: ["op": 1, "d": d], options: [.sortedKeys])
    }

    public static func request(_ type: String, id: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["op": 6, "d": ["requestType": type, "requestId": id]], options: [.sortedKeys])
    }

    public static func parse(_ data: Data) throws -> OBSMessage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? Int, let d = object["d"] as? [String: Any] else {
            throw OBSProtocolError("Unreadable OBS message")
        }
        switch op {
        case 0:
            let auth = d["authentication"] as? [String: Any]
            return .hello(challenge: auth?["challenge"] as? String, salt: auth?["salt"] as? String)
        case 2:
            return .identified
        case 5:
            guard d["eventType"] as? String == "RecordStateChanged", let event = d["eventData"] as? [String: Any],
                  let state = event["outputState"] as? String else { return .other }
            return .recordStateChanged(state: state, active: event["outputActive"] as? Bool ?? false, path: event["outputPath"] as? String)
        case 7:
            guard let id = d["requestId"] as? String else { return .other }
            let status = d["requestStatus"] as? [String: Any]
            guard status?["result"] as? Bool == true else {
                return .requestFailed(requestID: id, comment: status?["comment"] as? String ?? "code \(status?["code"] ?? "?")")
            }
            guard d["requestType"] as? String == "GetRecordStatus" else { return .requestSucceeded(requestID: id) }
            guard let response = d["responseData"] as? [String: Any],
                  let duration = (response["outputDuration"] as? NSNumber)?.doubleValue, duration.isFinite else {
                throw OBSProtocolError("GetRecordStatus response is missing outputDuration")
            }
            return .recordStatus(requestID: id, active: response["outputActive"] as? Bool ?? false,
                                 paused: response["outputPaused"] as? Bool ?? false, videoMS: duration)
        default:
            return .other
        }
    }
}

/// Least-squares line `videoMS = offset + slope · seconds` over the fastest round trips.
/// The slope absorbs the rate difference between the Mac and the OBS machine.
public struct OBSSyncFit: Equatable, Sendable {
    public let offsetMS: Double
    public let slope: Double
    public let residualMS: Double
    public let used: Int
    public let bestRTTMS: Double

    public func videoMS(atSeconds seconds: Double) -> Double { offsetMS + slope * seconds }

    /// `seconds` are measured from `originNS`. Slow round trips carry more timing uncertainty, so samples slower
    /// than max(1.5 × best, best + 2 ms) are dropped before fitting.
    public static func fit(_ samples: [OBSSyncSample], originNS: UInt64) -> OBSSyncFit? {
        let recording = samples.filter { $0.active && !$0.paused && $0.receivedNS >= $0.sentNS }
        guard let best = recording.map(\.rttMS).min() else { return nil }
        let limit = max(best * 1.5, best + 2)
        let points = recording.filter { $0.rttMS <= limit }.map {
            (x: ($0.midNS >= originNS ? Double($0.midNS - originNS) : -Double(originNS - $0.midNS)) / 1e9, y: $0.videoMS)
        }
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        let meanX = points.map(\.x).reduce(0, +) / n, meanY = points.map(\.y).reduce(0, +) / n
        let sxx = points.map { ($0.x - meanX) * ($0.x - meanX) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = points.map { ($0.x - meanX) * ($0.y - meanY) }.reduce(0, +) / sxx
        let offset = meanY - slope * meanX
        let residual = (points.map { pow($0.y - offset - slope * $0.x, 2) }.reduce(0, +) / n).squareRoot()
        return OBSSyncFit(offsetMS: offset, slope: slope, residualMS: residual, used: points.count, bestRTTMS: best)
    }
}
