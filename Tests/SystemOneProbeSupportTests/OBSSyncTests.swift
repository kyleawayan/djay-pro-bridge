import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class OBSSyncTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }

    func testAuthenticationMatchesProtocolExample() {
        XCTAssertEqual(OBSProtocol.authentication(password: "supersecretpassword",
                                                  salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
                                                  challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY="),
                       "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=")
    }

    func testIdentifySubscribesToOutputsAndAuthenticatesOnlyWhenAsked() throws {
        let open = try json(OBSProtocol.identify(challenge: nil, salt: nil, password: nil))
        let d = open["d"] as! [String: Any]
        XCTAssertEqual(open["op"] as? Int, 1)
        XCTAssertEqual(d["eventSubscriptions"] as? Int, 64)
        XCTAssertNil(d["authentication"])
        let locked = try json(OBSProtocol.identify(challenge: "c", salt: "s", password: "p"))
        XCTAssertEqual((locked["d"] as! [String: Any])["authentication"] as? String,
                       OBSProtocol.authentication(password: "p", salt: "s", challenge: "c"))
        XCTAssertThrowsError(try OBSProtocol.identify(challenge: "c", salt: "s", password: ""))
    }

    func testParsesHelloStatusFailureAndRecordEvents() throws {
        func parse(_ text: String) throws -> OBSMessage { try OBSProtocol.parse(Data(text.utf8)) }
        XCTAssertEqual(try parse(#"{"op":0,"d":{"rpcVersion":1,"authentication":{"challenge":"c","salt":"s"}}}"#),
                       .hello(challenge: "c", salt: "s"))
        XCTAssertEqual(try parse(#"{"op":0,"d":{"rpcVersion":1}}"#), .hello(challenge: nil, salt: nil))
        XCTAssertEqual(try parse(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#), .identified)
        XCTAssertEqual(try parse(#"{"op":7,"d":{"requestType":"GetRecordStatus","requestId":"r1","requestStatus":{"result":true,"code":100},"responseData":{"outputActive":true,"outputPaused":false,"outputTimecode":"00:00:01.500","outputDuration":1500,"outputBytes":10}}}"#),
                       .recordStatus(requestID: "r1", active: true, paused: false, videoMS: 1500))
        XCTAssertEqual(try parse(#"{"op":7,"d":{"requestType":"GetRecordStatus","requestId":"r2","requestStatus":{"result":false,"code":604,"comment":"no output"}}}"#),
                       .requestFailed(requestID: "r2", comment: "no output"))
        XCTAssertEqual(try parse(#"{"op":5,"d":{"eventType":"RecordStateChanged","eventIntent":64,"eventData":{"outputActive":false,"outputState":"OBS_WEBSOCKET_OUTPUT_STOPPED","outputPath":"C:\\Videos\\set.mkv"}}}"#),
                       .recordStateChanged(state: "OBS_WEBSOCKET_OUTPUT_STOPPED", active: false, path: "C:\\Videos\\set.mkv"))
        XCTAssertEqual(try parse(#"{"op":7,"d":{"requestType":"StartRecord","requestId":"c1","requestStatus":{"result":true,"code":100}}}"#),
                       .requestSucceeded(requestID: "c1"))
        XCTAssertEqual(try parse(#"{"op":7,"d":{"requestType":"StopRecord","requestId":"c2","requestStatus":{"result":false,"code":501,"comment":"Output not running"}}}"#),
                       .requestFailed(requestID: "c2", comment: "Output not running"))
        XCTAssertEqual(try parse(#"{"op":5,"d":{"eventType":"SceneNameChanged","eventData":{}}}"#), .other)
        XCTAssertThrowsError(try parse("not json"))
    }

    /// Two hours at 60 fps with 40 ppm drift, frame-quantized positions, Wi-Fi jitter and occasional 150 ms spikes.
    func testFitRecoversOffsetAndDriftThroughJitterAndQuantization() {
        let origin: UInt64 = 5_000_000_000
        let frame = 1000.0 / 60, startMS = 12_345.0, rate = 1.000040
        var generator = SystemRandomNumberGenerator()
        var samples: [OBSSyncSample] = []
        for second in 0..<7200 {
            let mid = 1 + Double(second) + Double.random(in: 0..<0.5, using: &generator)
            let rtt = Double.random(in: 0.002...0.008, using: &generator) + (second % 37 == 0 ? 0.15 : 0)
            // OBS answers at an unknown point inside the round trip; up to 70% of it can be on the way there.
            let answeredAt = mid - rtt / 2 + rtt * Double.random(in: 0.3...0.7, using: &generator)
            let video = ((startMS + answeredAt * 1000 * rate) / frame).rounded(.down) * frame
            let sent = origin + UInt64((mid - rtt / 2) * 1e9), received = origin + UInt64((mid + rtt / 2) * 1e9)
            samples.append(OBSSyncSample(sentNS: sent, receivedNS: received, active: true, paused: false, videoMS: video))
        }
        samples.append(OBSSyncSample(sentNS: origin, receivedNS: origin + 1_000_000, active: false, paused: false, videoMS: 0))
        let fit = try! XCTUnwrap(OBSSyncFit.fit(samples, originNS: origin))
        for seconds in [0.0, 3600, 7199] {
            let expected = startMS + seconds * 1000 * rate - frame / 2
            XCTAssertEqual(fit.videoMS(atSeconds: seconds), expected, accuracy: 2, "at \(seconds) s")
        }
        XCTAssertLessThan(fit.bestRTTMS, 2.1)
        XCTAssertLessThan(fit.used, samples.count - 1)
    }

    func testFitNeedsRecordingSamples() {
        let idle = (0..<10).map { OBSSyncSample(sentNS: UInt64($0) * 1_000_000_000, receivedNS: UInt64($0) * 1_000_000_000 + 2_000_000,
                                                active: false, paused: false, videoMS: 0) }
        XCTAssertNil(OBSSyncFit.fit(idle, originNS: 0))
    }

    func testRecorderWritesOBSSyncRelativeToSessionClock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = TelemetryRecorder()
        recorder.record(OBSSyncSample(sentNS: 1, receivedNS: 2, active: true, paused: false, videoMS: 1))
        try recorder.start(at: folder)
        let origin = try XCTUnwrap(recorder.clockOrigin)
        recorder.record(OBSSyncSample(sentNS: origin - 2_000_000, receivedNS: origin + 4_000_000, active: true, paused: false, videoMS: 900))
        recorder.record(OBSRecordState(receivedNS: origin + 1_500_000_000, state: "OBS_WEBSOCKET_OUTPUT_STOPPED", active: false, path: "/videos/set.mkv"))
        try recorder.stop()
        XCTAssertNil(recorder.clockOrigin)
        let manifest = try json(Data(contentsOf: folder.appendingPathComponent("session.json")))
        XCTAssertEqual(manifest["obs_sync"] as? String, "obs-sync.ndjson")
        let lines = try String(contentsOf: folder.appendingPathComponent("obs-sync.ndjson")).split(separator: "\n")
            .map { try json(Data($0.utf8)) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0]["kind"] as? String, "sample")
        XCTAssertEqual(lines[0]["t"] as! Double, 0.001, accuracy: 1e-9)
        XCTAssertEqual(lines[0]["rtt_ms"] as! Double, 6, accuracy: 1e-9)
        XCTAssertEqual(lines[0]["video_ms"] as? Double, 900)
        XCTAssertEqual(lines[1]["kind"] as? String, "state")
        XCTAssertEqual(lines[1]["t"] as! Double, 1.5, accuracy: 1e-9)
        XCTAssertEqual(lines[1]["path"] as? String, "/videos/set.mkv")
    }
}
