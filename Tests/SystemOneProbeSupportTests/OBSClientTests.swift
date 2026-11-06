import Foundation
import Network
import XCTest
@testable import SystemOneProbeSupport

/// Minimal obs-websocket stand-in on loopback: password auth, GetRecordStatus and one RecordStateChanged event.
private final class FakeOBS: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake.obs")
    let password: String
    var identifyAuth: String?
    var recording = true
    var connections: [NWConnection] = []

    init(password: String) throws {
        self.password = password
        let socket = NWProtocolWebSocket.Options()
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> Int {
        let ready = expectationPort()
        listener.newConnectionHandler = { [self] connection in
            connections.append(connection)
            connection.start(queue: queue)
            send(#"{"op":0,"d":{"obsWebSocketVersion":"5.5.0","rpcVersion":1,"authentication":{"challenge":"c","salt":"s"}}}"#, on: connection)
            receive(on: connection)
        }
        listener.start(queue: queue)
        return try await ready()
    }

    private func expectationPort() -> () async throws -> Int {
        { [self] in
            for _ in 0..<200 {
                if let port = listener.port?.rawValue, port != 0 { return Int(port) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw OBSProtocolError("Fake OBS did not start")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil, let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = object["d"] as? [String: Any] else { return }
            if object["op"] as? Int == 1 {
                identifyAuth = d["authentication"] as? String
                guard identifyAuth == OBSProtocol.authentication(password: password, salt: "s", challenge: "c") else {
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
                    metadata.closeCode = .privateCode(4009)
                    connection.send(content: nil, contentContext: .init(identifier: "close", metadata: [metadata]),
                                    isComplete: true, completion: .idempotent)
                    return
                }
                send(#"{"op":2,"d":{"negotiatedRpcVersion":1}}"#, on: connection)
                send(#"{"op":5,"d":{"eventType":"RecordStateChanged","eventIntent":64,"eventData":{"outputActive":true,"outputState":"OBS_WEBSOCKET_OUTPUT_STARTED","outputPath":null}}}"#, on: connection)
            } else if object["op"] as? Int == 6, let id = d["requestId"] as? String, let type = d["requestType"] as? String {
                switch type {
                case "StartRecord", "StopRecord":
                    let starting = type == "StartRecord"
                    guard starting != recording else {
                        send(#"{"op":7,"d":{"requestType":"\#(type)","requestId":"\#(id)","requestStatus":{"result":false,"code":500,"comment":"Output already in that state"}}}"#, on: connection)
                        break
                    }
                    recording = starting
                    send(#"{"op":7,"d":{"requestType":"\#(type)","requestId":"\#(id)","requestStatus":{"result":true,"code":100}}}"#, on: connection)
                    let state = starting ? "OBS_WEBSOCKET_OUTPUT_STARTED" : "OBS_WEBSOCKET_OUTPUT_STOPPED"
                    let path = starting ? "null" : #""C:\\Videos\\set.mkv""#
                    send(#"{"op":5,"d":{"eventType":"RecordStateChanged","eventIntent":64,"eventData":{"outputActive":\#(starting),"outputState":"\#(state)","outputPath":\#(path)}}}"#, on: connection)
                default:
                    send(#"{"op":7,"d":{"requestType":"GetRecordStatus","requestId":"\#(id)","requestStatus":{"result":true,"code":100},"responseData":{"outputActive":\#(recording),"outputPaused":false,"outputDuration":4200}}}"#, on: connection)
                }
            }
            receive(on: connection)
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        connection.send(content: Data(text.utf8), contentContext: .init(identifier: "text", metadata: [metadata]),
                        isComplete: true, completion: .idempotent)
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}

final class OBSClientTests: XCTestCase {
    func testAuthenticatesPollsAndReportsRecordState() async throws {
        let obs = try FakeOBS(password: "pw")
        defer { obs.stop() }
        let port = try await obs.start()
        let client = try OBSClient(host: "127.0.0.1", port: port, password: "pw")
        let sampled = expectation(description: "sample"), stated = expectation(description: "state"), connected = expectation(description: "connected")
        sampled.assertForOverFulfill = false; connected.assertForOverFulfill = false
        let received = Locked<[OBSSyncSample]>([])
        client.onStatus = { if $0 == .connected { connected.fulfill() } }
        client.onSample = { sample in received.mutate { $0.append(sample) }; sampled.fulfill() }
        client.onRecordState = { state in
            XCTAssertEqual(state.state, "OBS_WEBSOCKET_OUTPUT_STARTED")
            XCTAssertNil(state.path)
            stated.fulfill()
        }
        client.start()
        await fulfillment(of: [connected, stated, sampled], timeout: 5)
        client.stop()
        let sample = try XCTUnwrap(received.value.first)
        XCTAssertEqual(sample.videoMS, 4200)
        XCTAssertTrue(sample.active)
        XCTAssertGreaterThanOrEqual(sample.receivedNS, sample.sentNS)
        XCTAssertLessThan(sample.rttMS, 1000)
    }

    func testWrongPasswordStopsWithoutRetrying() async throws {
        let obs = try FakeOBS(password: "pw")
        defer { obs.stop() }
        let port = try await obs.start()
        let client = try OBSClient(host: "127.0.0.1", port: port, password: "wrong")
        let failed = expectation(description: "failed")
        client.onStatus = { if case .failed(let reason) = $0 { XCTAssertTrue(reason.contains("password")); failed.fulfill() } }
        client.start()
        await fulfillment(of: [failed], timeout: 5)
        client.stop()
    }

    func testStartAndStopRecordReportResultsAndStateEvents() async throws {
        let obs = try FakeOBS(password: "pw")
        defer { obs.stop() }
        let port = try await obs.start()
        let client = try OBSClient(host: "127.0.0.1", port: port, password: "pw")
        let connected = expectation(description: "connected"); connected.assertForOverFulfill = false
        let states = Locked<[OBSRecordState]>([])
        client.onStatus = { if $0 == .connected { connected.fulfill() } }
        client.onRecordState = { state in states.mutate { $0.append(state) } }
        client.start()
        await fulfillment(of: [connected], timeout: 5)
        func run(_ type: String) async -> String? {
            await withCheckedContinuation { continuation in client.command(type) { continuation.resume(returning: $0) } }
        }
        let duplicate = await run("StartRecord")
        XCTAssertEqual(duplicate, "Output already in that state")
        let stopped = await run("StopRecord")
        XCTAssertNil(stopped)
        let started = await run("StartRecord")
        XCTAssertNil(started)
        for _ in 0..<100 where states.value.count < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
        client.stop()
        XCTAssertEqual(states.value.map(\.state), ["OBS_WEBSOCKET_OUTPUT_STARTED", "OBS_WEBSOCKET_OUTPUT_STOPPED", "OBS_WEBSOCKET_OUTPUT_STARTED"])
        XCTAssertEqual(states.value[1].path, #"C:\Videos\set.mkv"#)
        let afterStop = await run("StartRecord")
        XCTAssertEqual(afterStop, "OBS is not connected")
    }

    func testRejectsMissingAddress() {
        XCTAssertThrowsError(try OBSClient(host: " ", port: 4455, password: nil))
        XCTAssertThrowsError(try OBSClient(host: "192.168.1.20", port: 0, password: nil))
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
