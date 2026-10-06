import Foundation
import SwiftProtobuf
import XCTest
@testable import SystemOneProbeSupport

final class PacketDebuggerTests: XCTestCase {
    private func frame(_ payload: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [0xf0,0x70,0,0,1,0]
        var accumulator: UInt64 = 0, bits = 0
        for byte in payload {
            accumulator |= UInt64(byte) << bits; bits += 8
            while bits >= 7 { output.append(UInt8(accumulator & 127)); accumulator >>= 7; bits -= 7 }
        }
        if bits > 0 { output.append(UInt8(accumulator & 127)) }
        return output + [0xf7]
    }
    func testWaveformFourByteSamplesAndOffset() {
        let samples: [UInt8] = [255,0,0,128,0,255,0,64]
        let body: [UInt8] = [16,10,26,8] + samples
        let packet = PacketDebugger.inspect(frame([0xf2,0x03,UInt8(body.count)] + body), catalog: nil)
        XCTAssertEqual(packet.field, 62)
        XCTAssertEqual(packet.waveformOffset, 10)
        XCTAssertEqual(packet.waveform, samples)
        XCTAssertEqual(packet.deckIndex, 0)
    }
    func testOutOfRangeWaveformOffsetDoesNotBecomeAPreview() {
        let body: [UInt8] = [16] + Array(repeating: 255, count: 9) + [1,26,4,255,0,0,128]
        let packet = PacketDebugger.inspect(frame([0xf2,0x03,UInt8(body.count)] + body), catalog: nil)
        XCTAssertNil(packet.waveform)
        XCTAssertNil(packet.waveformOffset)
    }
    func testInvalidWaveformWidthDoesNotBecomeAPreview() {
        let packet = PacketDebugger.inspect(frame([0xf2,0x03,5,26,3,1,2,3]), catalog: nil)
        XCTAssertNil(packet.waveform)
    }
    func testEmbeddedDescriptorExtractionRejectsStrayNameStrings() throws {
        var field = Google_Protobuf_FieldDescriptorProto()
        field.name = "example"; field.number = 1; field.type = .bool; field.label = .optional
        var envelope = Google_Protobuf_DescriptorProto()
        envelope.name = "HybridModeMessage"; envelope.field = [field]
        var file = Google_Protobuf_FileDescriptorProto()
        file.name = "remote_host_screen_service_test.proto"
        file.package = "remotehostscreen.v1"; file.syntax = "proto3"; file.messageType = [envelope]
        let binary = Data("stray remote_host_screen_service_name\0".utf8) + (try file.serializedData()) + Data([0,0,0])
        let catalog = try ProtocolCatalog.extract(from: binary)
        XCTAssertEqual(catalog.envelopes[1]?.name, "example")
        XCTAssertThrowsError(try ProtocolCatalog.extract(from: Data("remote_host_screen_service_invalid.proto".utf8)))
    }
    func testOfficialDescriptorRuntimeNamesFieldsAndMarksText() throws {
        var field = Google_Protobuf_FieldDescriptorProto()
        field.name = "title"; field.number = 1; field.type = .string; field.label = .optional
        var body = Google_Protobuf_DescriptorProto()
        body.name = "TestBody"; body.field = [field]
        var envelopeField = Google_Protobuf_FieldDescriptorProto()
        envelopeField.name = "test_message"; envelopeField.number = 110; envelopeField.type = .message
        envelopeField.typeName = ".remotehostscreen.v1.TestBody"; envelopeField.label = .optional
        var envelope = Google_Protobuf_DescriptorProto()
        envelope.name = "HybridModeMessage"; envelope.field = [envelopeField]
        var descriptor = Google_Protobuf_FileDescriptorProto()
        descriptor.name = "synthetic.proto"; descriptor.package = "remotehostscreen.v1"; descriptor.syntax = "proto3"
        descriptor.messageType = [body,envelope]
        let catalog = try ProtocolCatalog(descriptor: descriptor.serializedData())
        let packet = PacketDebugger.inspect(frame([0xf2,0x06,3,10,1,65]), catalog: catalog)
        XCTAssertEqual(packet.name, "test_message")
        XCTAssertEqual(packet.fields.first?.name, "1: title")
        XCTAssertEqual(packet.fields.first?.value, "A")
        XCTAssertEqual(packet.fields.first?.privateValue, true)
    }
}
