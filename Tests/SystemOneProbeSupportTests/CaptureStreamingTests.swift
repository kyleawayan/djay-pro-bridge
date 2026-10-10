import CoreMIDI
import Foundation
import XCTest
@testable import SystemOneProbeSupport

final class CaptureStreamingTests: XCTestCase {
    private func send(_ bytes: [UInt8], to capture: Capture) {
        var packets = MIDIPacketList()
        withUnsafeMutablePointer(to: &packets) { pointer in
            let first = MIDIPacketListInit(pointer)
            bytes.withUnsafeBufferPointer { buffer in
                XCTAssertNotNil(MIDIPacketListAdd(pointer, MemoryLayout<MIDIPacketList>.size, first, 0, bytes.count, buffer.baseAddress!))
            }
            capture.receive(UnsafePointer(pointer))
        }
    }
    func testLiveSessionExceedsFormerPacketAndByteLimits() throws {
        var received = 0
        let capture = try Capture(verbose: false, recordTraffic: false, onMessage: { _ in received += 1 })
        defer { try? FileManager.default.removeItem(at: capture.directory) }
        let packet: [UInt8] = [0xf0,0x70,0,0,1,0] + Array(repeating: 0, count: 90) + [0xf7]
        for n in 0..<100_100 {
            send(packet, to: capture)
            if n.isMultiple(of: 100) { capture.drain() }
        }
        XCTAssertTrue(capture.finish(identity: "test", reason: "test", endpointNames: [:]))
        XCTAssertEqual(received, 100_100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.directory.appendingPathComponent("traffic.ndjson").path))
    }
    func testTerminalTransportLossMarksSessionIncompleteWithoutAnotherMessage() throws {
        let capture = try Capture(verbose: false, recordTraffic: false, maximumPendingBytes: 0)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: capture.directory); try? FileManager.default.removeItem(at: folder) }
        let recorder = TelemetryRecorder()
        try capture.withSynchronizedDropCount { try recorder.start(at: folder, transportDroppedPackets: $0) }
        send([0xf0, 0xf7], to: capture)
        XCTAssertThrowsError(try capture.withSynchronizedDropCount { try recorder.stop(transportDroppedPackets: $0) })
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("session.json"))) as! [String: Any]
        XCTAssertEqual(manifest["complete"] as? Bool, false)
        XCTAssertFalse(capture.finish(identity: "test", reason: "test", endpointNames: [:]))
        XCTAssertFalse(capture.finish(identity: "test", reason: "test", endpointNames: [:]))
    }

    func testRawRecordingIsExplicitAndQueueProtectionRemains() throws {
        let capture = try Capture(verbose: false, recordTraffic: true)
        defer { try? FileManager.default.removeItem(at: capture.directory) }
        send([0xf0,0x70,0,0,1,0,0xf7], to: capture)
        XCTAssertTrue(capture.finish(identity: "test", reason: "test", endpointNames: [:]))
        XCTAssertEqual(try String(contentsOf: capture.directory.appendingPathComponent("traffic.ndjson")).split(separator: "\n").count, 2)
        let bounded = try Capture(verbose: false, recordTraffic: false, maximumPendingBytes: 0)
        defer { try? FileManager.default.removeItem(at: bounded.directory) }
        send([0xf0,0xf7], to: bounded)
        _ = bounded.finish(identity: "test", reason: "test", endpointNames: [:])
        let summary = try JSONSerialization.jsonObject(with: Data(contentsOf: bounded.directory.appendingPathComponent("summary.json"))) as! [String:Any]
        XCTAssertEqual(summary["dropped_packets"] as? Int, 1)
    }
}
