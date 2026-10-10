import Foundation
import XCTest
import SwiftProtobuf
@testable import SystemOneProbeSupport

final class TelemetryRecorderTests: XCTestCase {
    private func position(_ value: Double) -> [UInt8] {
        let body: [UInt8] = [0x11] + (0..<8).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
        let payload: [UInt8] = [0x9a, 0x03, UInt8(body.count)] + body
        var result: [UInt8] = [0xf0,0x70,0,0,1,0]
        var accumulator: UInt64 = 0, bits = 0
        for byte in payload {
            accumulator |= UInt64(byte) << bits; bits += 8
            while bits >= 7 { result.append(UInt8(accumulator & 127)); accumulator >>= 7; bits -= 7 }
        }
        if bits > 0 { result.append(UInt8(accumulator & 127)) }
        return result + [0xf7]
    }
    private func frame(_ family: UInt64, _ body: [UInt8]) -> [UInt8] {
        func varint(_ value: UInt64) -> [UInt8] {
            var n = value, result: [UInt8] = []
            while n > 127 { result.append(UInt8(n & 127) | 128); n >>= 7 }
            return result + [UInt8(n)]
        }
        let payload = varint(family << 3 | 2) + varint(UInt64(body.count)) + body
        var result: [UInt8] = [0xf0,0x70,0,0,1,0]
        var accumulator: UInt64 = 0, bits = 0
        for byte in payload {
            accumulator |= UInt64(byte) << bits; bits += 8
            while bits >= 7 { result.append(UInt8(accumulator & 127)); accumulator >>= 7; bits -= 7 }
        }
        if bits > 0 { result.append(UInt8(accumulator & 127)) }
        return result + [0xf7]
    }
    private func loopCatalog() throws -> ProtocolCatalog {
        var index = Google_Protobuf_FieldDescriptorProto()
        index.name = "deckIndex"; index.number = 1; index.type = .uint32
        var body = Google_Protobuf_DescriptorProto()
        body.name = "SyntheticDeckMessage"; body.field = [index]
        var envelope = Google_Protobuf_DescriptorProto()
        envelope.name = "HybridModeMessage"
        envelope.field = [55, 60, 67, 68].map { number in
            var field = Google_Protobuf_FieldDescriptorProto()
            field.name = "message_\(number)"; field.number = Int32(number); field.type = .message
            field.typeName = ".remotehostscreen.v1.SyntheticDeckMessage"
            return field
        }
        var descriptor = Google_Protobuf_FileDescriptorProto()
        descriptor.name = "synthetic.proto"; descriptor.package = "remotehostscreen.v1"; descriptor.syntax = "proto3"
        descriptor.messageType = [body, envelope]
        return try ProtocolCatalog(descriptor: descriptor.serializedData())
    }
    private func doubleField(_ field: UInt8, _ value: Double) -> [UInt8] {
        [field << 3 | 1] + (0..<8).map { UInt8((value.bitPattern >> ($0 * 8)) & 255) }
    }
    func testLoopSnapshotChangesRemovalAndDeckClear() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = TelemetryRecorder(), catalog = try loopCatalog()
        func send(_ family: UInt64, _ body: [UInt8]) {
            let bytes = frame(family, body)
            recorder.consume(CapturedMessage(sequence: 1, elapsedSeconds: 0, bytes: bytes,
                packets: 1, receivedBytes: bytes.count, droppedPackets: 0), catalog: catalog)
        }
        // Proto3 omits a zero start boundary and the default status.
        send(67, [16, 2] + doubleField(4, 8))
        try recorder.start(at: folder)
        send(60, [16, 1])
        send(67, [16, 2] + doubleField(3, 2) + doubleField(4, 6) + [56, 1])
        send(67, [8, 1, 16, 3] + doubleField(3, 10) + doubleField(4, 12) + [56, 2])
        send(60, [])
        send(68, [16, 2])
        send(55, [8, 1])
        try recorder.stop()
        let lines = try String(contentsOf: folder.appendingPathComponent("events.ndjson")).split(separator: "\n")
        let events = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let decks = events.filter { $0["kind"] as? String == "deck" }
        XCTAssertEqual(decks.count, 7)
        guard decks.count == 7 else { return }
        func state(_ n: Int) -> [String: Any] { decks[n]["state"] as! [String: Any] }
        func regions(_ n: Int) -> [[String: Any]] { state(n)["loopRegions"] as! [[String: Any]] }
        XCTAssertEqual(decks[0]["t"] as? Double, 0)
        XCTAssertEqual(regions(0).first?["index"] as? Int, 2)
        XCTAssertEqual(regions(0).first?["start"] as? Double, 0)
        XCTAssertEqual(regions(0).first?["end"] as? Double, 8)
        XCTAssertEqual(regions(0).first?["status"] as? Int, 0)
        XCTAssertEqual(state(1)["loopEnabled"] as? Bool, true)
        XCTAssertEqual(regions(2).first?["start"] as? Double, 2)
        XCTAssertEqual(regions(2).first?["end"] as? Double, 6)
        XCTAssertEqual(regions(2).first?["status"] as? Int, 1)
        XCTAssertEqual(decks[3]["deck"] as? Int, 1)
        XCTAssertEqual(regions(3).first?["index"] as? Int, 3)
        XCTAssertEqual(regions(3).first?["status"] as? Int, 2)
        XCTAssertEqual(state(4)["loopEnabled"] as? Bool, false)
        XCTAssertTrue(regions(5).isEmpty)
        XCTAssertTrue(regions(6).isEmpty)
        XCTAssertTrue(events.contains { $0["kind"] as? String == "clear" && $0["deck"] as? Int == 1 })
    }
    func testInvalidLoopBoundariesRemoveOldRegion() throws {
        let catalog = try loopCatalog()
        for invalid in [doubleField(3, .nan) + doubleField(4, 8),
                        doubleField(3, 8) + doubleField(4, 2),
                        [24, 0] + doubleField(4, 8)] {
            var state = OverviewState()
            state.consume(PacketDebugger.inspect(frame(67, [16, 2] + doubleField(4, 8)), catalog: catalog))
            XCTAssertEqual(state.decks[0]?.loopRegions.count, 1)
            state.consume(PacketDebugger.inspect(frame(67, [16, 2] + invalid), catalog: catalog))
            XCTAssertTrue(state.decks[0]?.loopRegions.isEmpty == true)
        }
    }
    func testArtworkRemovalAndRestorationAreExplicit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = TelemetryRecorder()
        try recorder.start(at: folder)
        var deckField = Google_Protobuf_FieldDescriptorProto()
        deckField.name = "deckIndex"; deckField.number = 1; deckField.type = .uint32
        var body = Google_Protobuf_DescriptorProto()
        body.name = "ArtworkReference"; body.field = [deckField]
        var envelopeField = Google_Protobuf_FieldDescriptorProto()
        envelopeField.name = "artwork_reference"; envelopeField.number = 56; envelopeField.type = .message
        envelopeField.typeName = ".remotehostscreen.v1.ArtworkReference"
        var envelope = Google_Protobuf_DescriptorProto()
        envelope.name = "HybridModeMessage"; envelope.field = [envelopeField]
        var descriptor = Google_Protobuf_FileDescriptorProto()
        descriptor.name = "synthetic.proto"; descriptor.package = "remotehostscreen.v1"; descriptor.syntax = "proto3"
        descriptor.messageType = [body, envelope]
        let catalog = try ProtocolCatalog(descriptor: descriptor.serializedData())
        let packets = [frame(90, [8, 4, 18, 3, 1, 2, 3]), frame(56, [16, 4]), frame(56, [16, 5]), frame(56, [16, 4])]
        for (index, bytes) in packets.enumerated() {
            recorder.consume(CapturedMessage(sequence: index + 1, elapsedSeconds: Double(index), bytes: bytes, packets: index + 1, receivedBytes: bytes.count, droppedPackets: 0), catalog: catalog)
        }
        try recorder.stop()
        let lines = try String(contentsOf: folder.appendingPathComponent("events.ndjson")).split(separator: "\n")
        let events = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }.filter { $0["kind"] as? String == "deck-artwork" }
        XCTAssertEqual(events.count, 3)
        guard events.count == 3 else { return }
        XCTAssertNotNil(events[0]["asset"] as? String)
        XCTAssertTrue(events[1]["asset"] is NSNull)
        XCTAssertEqual(events[0]["asset"] as? String, events[2]["asset"] as? String)
    }
    func testFinalizedCreationTimeMatchesStartAndNewRecordingGetsNewTime() throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Date(timeIntervalSince1970: 1_000_000)
            func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
            func advance() { lock.lock(); value.addTimeInterval(3600); lock.unlock() }
        }
        let clock = Clock()
        let recorder = TelemetryRecorder(now: { clock.now() })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func created(_ folder: URL) throws -> String {
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("session.json"))) as! [String: Any]
            return manifest["created_at"] as! String
        }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try recorder.start(at: first, transportDroppedPackets: 2)
        let before = try created(first)
        clock.advance()
        try recorder.stop(transportDroppedPackets: 2)
        XCTAssertEqual(try created(first), before)
        try recorder.start(at: second, transportDroppedPackets: 3)
        try recorder.stop(transportDroppedPackets: 3)
        XCTAssertNotEqual(try created(second), before)
    }
    func testRecordingSeedsStateAndFinishesReadableSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = TelemetryRecorder()
        recorder.consume(CapturedMessage(sequence: 1, elapsedSeconds: 0, bytes: position(0.25), packets: 1, receivedBytes: 20, droppedPackets: 0), catalog: nil)
        try recorder.start(at: folder)
        recorder.consume(CapturedMessage(sequence: 2, elapsedSeconds: 1, bytes: position(0.5), packets: 2, receivedBytes: 40, droppedPackets: 0), catalog: nil)
        try recorder.stop()
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("session.json"))) as! [String: Any]
        XCTAssertEqual(manifest["complete"] as? Bool, true)
        XCTAssertNotNil(UInt64(manifest["clock_origin_ns"] as! String))
        XCTAssertEqual(manifest["clock"] as? String, "monotonic-ns")
        XCTAssertEqual(manifest["clock_source"] as? String, "CLOCK_UPTIME_RAW")
        let lines = try String(contentsOf: folder.appendingPathComponent("events.ndjson")).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let event = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(event["t"] as? Double, 0)
        XCTAssertEqual((event["state"] as? [String:Any])?["position"] as? Double, 0.25)
        XCTAssertThrowsError(try recorder.start(at: folder))
    }
    func testTransportLossMarksRecordingIncomplete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = TelemetryRecorder()
        try recorder.start(at: folder)
        recorder.consume(CapturedMessage(sequence: 1, elapsedSeconds: 0, bytes: position(0.3), packets: 1, receivedBytes: 20, droppedPackets: 1), catalog: nil)
        XCTAssertThrowsError(try recorder.stop())
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("session.json"))) as! [String: Any]
        XCTAssertEqual(manifest["complete"] as? Bool, false)
    }
}
