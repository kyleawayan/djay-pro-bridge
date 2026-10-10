import Foundation
import SwiftProtobuf

public struct ProtocolField: Sendable {
    public let number: UInt64
    public let name: String
    public let type: Int
    public let typeName: String
    public let repeated: Bool
    public let hasPresence: Bool
}

public final class ProtocolCatalog: @unchecked Sendable {
    public let package: String
    public let filename: String
    public let messages: [String: [ProtocolField]]
    public let envelopes: [UInt64: ProtocolField]
    public let enumValues: [String: [Int: String]]

    public init(descriptor: Data) throws {
        let file = try Google_Protobuf_FileDescriptorProto(serializedBytes: descriptor)
        guard file.package == "remotehostscreen.v1", file.syntax == "proto3" else { throw CatalogError.invalidDescriptor }
        package = file.package
        filename = file.name
        var types: [String: [ProtocolField]] = [:]
        var enums: [String: [Int: String]] = [:]
        func addEnum(_ entry: Google_Protobuf_EnumDescriptorProto, parent: String) {
            enums[parent + "." + entry.name] = Dictionary(entry.value.map { (Int($0.number), $0.name) }, uniquingKeysWith: { first, _ in first })
        }
        func add(_ entry: Google_Protobuf_DescriptorProto, parent: String) {
            let name = parent + "." + entry.name
            types[name] = entry.field.map {
                ProtocolField(number: UInt64($0.number), name: $0.name, type: $0.type.rawValue,
                              typeName: $0.typeName, repeated: $0.label == .repeated, hasPresence: $0.proto3Optional || $0.hasOneofIndex)
            }
            for child in entry.nestedType { add(child, parent: name) }
            for child in entry.enumType { addEnum(child, parent: name) }
        }
        for entry in file.messageType { add(entry, parent: "." + file.package) }
        for entry in file.enumType { addEnum(entry, parent: "." + file.package) }
        messages = types
        enumValues = enums
        envelopes = Dictionary((types["." + file.package + ".HybridModeMessage"] ?? []).map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        guard !envelopes.isEmpty else { throw CatalogError.invalidDescriptor }
    }

    public static func load(app: URL) throws -> ProtocolCatalog {
        guard let executable = Bundle(url: app)?.executableURL else { throw CatalogError.missingExecutable }
        let binary = try Data(contentsOf: executable, options: .mappedIfSafe)
        return try extract(from: binary)
    }

    static func extract(from binary: Data) throws -> ProtocolCatalog {
        let needle = Data("remote_host_screen_service_".utf8)
        var cursor = binary.startIndex
        while cursor < binary.endIndex, let match = binary.range(of: needle, in: cursor..<binary.endIndex) {
            cursor = match.upperBound
            guard match.lowerBound >= 2 else { continue }
            let start = match.lowerBound - 2
            guard binary[start] == 10 else { continue }
            let end = min(binary.endIndex, start + 1_048_576)
            guard let suffix = binary.range(of: Data([0x62, 6] + Array("proto3".utf8)), in: match.upperBound..<end) else { continue }
            if let catalog = try? ProtocolCatalog(descriptor: binary.subdata(in: start..<suffix.upperBound)) { return catalog }
        }
        throw CatalogError.notFound
    }
}

public enum CatalogError: Error { case invalidDescriptor, missingExecutable, notFound }

public struct DebugField: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let wire: String
    public let value: String
    public let privateValue: Bool
    public let depth: Int
}

public struct DebugPacket: Sendable {
    public let field: UInt64?
    public let name: String
    public let payload: [UInt8]
    public let fields: [DebugField]
    public let image: Data?
    public let waveform: [UInt8]?
    public let waveformOffset: UInt64?
    public let status: String
    public let deckIndex: UInt32?
    public let cacheIndex: UInt32?
}

public enum PacketDebugger {
    public static func inspect(_ frame: [UInt8], catalog: ProtocolCatalog?) -> DebugPacket {
        func failure(_ status: String) -> DebugPacket {
            DebugPacket(field: nil, name: status, payload: [], fields: [], image: nil, waveform: nil, waveformOffset: nil, status: status, deckIndex: nil, cacheIndex: nil)
        }
        guard frame.count >= 7, frame[0] == 0xf0, frame[1] == 0x70, frame.last == 0xf7 else { return failure("Unknown envelope") }
        let index = Int(frame[2]) | Int(frame[3]) << 7
        let count = Int(frame[4]) | Int(frame[5]) << 7
        guard index == 0 && count == 1 else { return failure("Fragment \(index + 1)/\(count); awaiting assembly") }
        do {
            let payload = try SystemOneDecoder.unpack(Array(frame.dropFirst(6).dropLast()))
            let outer = try SystemOneDecoder.wireFields(payload)
            guard outer.count == 1, let top = outer.first, case .bytes(let body) = top.1 else { return failure("Unexpected protobuf envelope") }
            let schema = catalog?.envelopes[top.0]
            var rendered: [DebugField] = []
            render(body, type: schema?.typeName ?? "", path: "", depth: 0, catalog: catalog, into: &rendered)
            let nested = try SystemOneDecoder.wireFields(body)
            func bytes(_ number: UInt64) -> [UInt8]? {
                guard case .bytes(let value) = nested.last(where: { $0.0 == number })?.1 else { return nil }
                return value
            }
            func indexValue(_ number: UInt64, implicitDefault: Bool) -> UInt32? {
                if let item = nested.last(where: { $0.0 == number }) {
                    guard case .integer(let value) = item.1, value <= UInt32.max else { return nil }
                    return UInt32(value)
                }
                return implicitDefault ? 0 : nil
            }
            let definitions = catalog?.messages[schema?.typeName ?? ""] ?? []
            let deckField = definitions.first(where: { $0.name == "deckIndex" })
            let knownDeckMessage = [UInt64(51),62,63,69].contains(top.0)
            let deckIndex = deckField.map { indexValue($0.number, implicitDefault: !$0.hasPresence) }
                ?? (knownDeckMessage ? indexValue(1, implicitDefault: true) : nil)
            let cacheIndex = top.0 == 90 ? indexValue(1, implicitDefault: true) : nil
            var waveform: [UInt8]?
            var offset: UInt64?
            if top.0 == 62, let data = bytes(3), data.count % 4 == 0 {
                let value = nested.last(where: { $0.0 == 2 })?.1
                let candidate: UInt64?
                if case .integer(let raw) = value { candidate = raw }
                else { candidate = value == nil ? 0 : nil }
                if let candidate, candidate <= UInt32.max {
                    waveform = data
                    offset = candidate
                }
            }
            let image = [UInt64(69), 90, 94].contains(top.0) ? bytes(2).map { Data($0) } : nil
            let fallback: [UInt64: String] = [1:"keep_alive",51:"set_deck_playhead_position",62:"update_waveform_chunk",63:"set_deck_beatgrid",69:"set_deck_overview_waveform",90:"set_album_art_image"]
            return DebugPacket(field: top.0, name: schema?.name ?? fallback[top.0] ?? "field_\(top.0)", payload: payload,
                               fields: rendered, image: image, waveform: waveform, waveformOffset: offset,
                               status: schema == nil ? "Numeric fields; schema unavailable" : "Names from installed app descriptor",
                               deckIndex: deckIndex, cacheIndex: cacheIndex)
        } catch { return failure("Malformed protobuf") }
    }

    private static func render(_ data: [UInt8], type: String, path: String, depth: Int,
                               catalog: ProtocolCatalog?, into output: inout [DebugField]) {
        guard depth <= 6, output.count < 20000, let wireFields = try? SystemOneDecoder.wireFields(data) else { return }
        let definitions = catalog?.messages[type] ?? []
        for (order, item) in wireFields.enumerated() {
            if output.count >= 20000 { return }
            let (number, value) = item
            let field = definitions.first(where: { $0.number == number })
            let name = field?.name ?? "field_\(number)"
            let id = path + "\(number)[\(order)]"
            var label = "", wire = "", hidden = false
            switch value {
            case .integer(let integer):
                wire = "varint"
                if field?.type == 8 { label = integer == 0 ? "false" : "true" }
                else if field?.type == 14 {
                    let signed = Int(Int32(truncatingIfNeeded: integer))
                    label = catalog?.enumValues[field?.typeName ?? ""]?[signed].map { "\($0) (\(signed))" } ?? "\(signed)"
                } else if field?.type == 5 { label = "\(Int32(truncatingIfNeeded: integer))" }
                else if field?.type == 3 { label = "\(Int64(bitPattern: integer))" }
                else if [17,18].contains(field?.type ?? 0) { label = "\(Int64(integer >> 1) ^ -Int64(integer & 1))" }
                else { label = "\(integer)" }
            case .fixed64(let bits):
                wire = "fixed64"
                label = field?.type == 1 ? "\(Double(bitPattern: bits))" : field == nil ? "bits=\(bits); f64=\(Double(bitPattern: bits))" : "\(bits)"
            case .fixed32(let bits):
                wire = "fixed32"
                label = field?.type == 2 ? "\(Float(bitPattern: bits))" : "\(bits)"
            case .bytes(let bytes):
                wire = "length-delimited"
                if field?.type == 11 {
                    label = "message (\(bytes.count) bytes)"
                } else if field?.type == 9 {
                    label = String(bytes: bytes, encoding: .utf8) ?? "Invalid UTF-8"
                    hidden = true
                } else {
                    label = "\(bytes.count) bytes" + ((field?.repeated == true) ? " (packed values)" : "")
                }
            }
            output.append(DebugField(id: id, name: "\(number): \(name)", wire: wire, value: label, privateValue: hidden, depth: depth))
            if case .bytes(let bytes) = value, field?.type == 11 {
                render(bytes, type: field?.typeName ?? "", path: id + ".", depth: depth + 1, catalog: catalog, into: &output)
            }
        }
        let present = Set(wireFields.map { $0.0 })
        for field in definitions where !present.contains(field.number) && !field.repeated && !field.hasPresence && field.type != 11 {
            guard output.count < 20000 else { return }
            let value: String
            switch field.type {
            case 8: value = "false"
            case 9: value = "(empty string)"
            case 12: value = "0 bytes"
            case 14: value = catalog?.enumValues[field.typeName]?[0].map { "\($0) (0)" } ?? "0"
            default: value = "0"
            }
            output.append(DebugField(id: path + "\(field.number).default", name: "\(field.number): \(field.name)",
                                     wire: "implicit default", value: value, privateValue: field.type == 9, depth: depth))
        }
    }
}
