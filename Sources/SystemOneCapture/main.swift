import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import SystemOneProbeSupport
import UniformTypeIdentifiers

struct ExportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
struct Asset: Codable {
    let file: String
    let label: String
    let kind: String
    let width: Int
    let height: Int
    let sha256: String
}

func image(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = properties[kCGImagePropertyPixelWidth] as? Int,
          let h = properties[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0, w <= 4096, h <= 4096, w * h <= 8_000_000 else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
func context(_ width: Int, _ height: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ExportError("Could not allocate image")
    }
    return context
}
func png(_ image: CGImage, at url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ExportError("Could not create PNG")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ExportError("Could not finish PNG") }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
func label(_ text: String, x: CGFloat, y: CGFloat, in context: CGContext, size: CGFloat = 14) {
    let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    context.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, context)
}
func detailImage(_ deck: DeckOverview) throws -> CGImage {
    let width = 1400, height = 160
    let context = try context(width, height)
    context.setFillColor(CGColor(gray: 0.14, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height))
    let maximum: UInt64 = try deck.detailChunks.map { offset, bytes -> UInt64 in
        let (end, overflow) = offset.addingReportingOverflow(UInt64(bytes.count / 4))
        guard !overflow, offset <= UInt32.max else { throw ExportError("Invalid waveform sample range") }
        return end
    }.max() ?? 1
    let durationSamples = (deck.duration ?? 0) * 315
    let extent = durationSamples.isFinite && durationSamples > 0 && durationSamples < Double(UInt32.max)
        ? max(maximum, UInt64(durationSamples)) : maximum
    var strongest = [UInt8](repeating: 0, count: width * 4)
    var covered = [Bool](repeating: false, count: width)
    for (offset, bytes) in deck.detailChunks {
        for sample in 0..<(bytes.count / 4) {
            let x = min(width - 1, Int(Double(offset + UInt64(sample)) / Double(max(1,extent)) * Double(width)))
            let input = sample * 4, output = x * 4
            if !covered[x] || bytes[input + 3] > strongest[output + 3] {
                for channel in 0..<4 { strongest[output + channel] = bytes[input + channel] }
            }
            covered[x] = true
        }
    }
    for x in 0..<width where covered[x] {
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x:x,y:0,width:1,height:height))
        let offset = x * 4
        let amplitude = CGFloat(strongest[offset + 3]) / 255 * CGFloat(height)
        context.setFillColor(CGColor(red: CGFloat(strongest[offset])/255, green: CGFloat(strongest[offset+1])/255,
                                     blue: CGFloat(strongest[offset+2])/255, alpha: 1))
        context.fill(CGRect(x:CGFloat(x),y:(CGFloat(height)-amplitude)/2,width:1,height:amplitude))
    }
    guard let result = context.makeImage() else { throw ExportError("Could not render waveform") }
    return result
}
func contactSheets(_ assets: [Asset], in output: URL) throws -> [String] {
    let ordered = assets.sorted { a,b in
        let rank: [String:Int] = ["overview-waveform":0,"detailed-waveform":1,"album-art-cache":2,"app-icon":3]
        return (rank[a.kind] ?? 4, a.file) < (rank[b.kind] ?? 4, b.file)
    }
    var sheets: [String] = []
    for page in stride(from: 0, to: ordered.count, by: 24) {
        let subset = Array(ordered[page..<min(ordered.count,page+24)])
        let rowHeight = 190, width = 1440, height = 90 + subset.count * rowHeight
        let canvas = try context(width,height)
        canvas.setFillColor(CGColor(gray: 0.06, alpha: 1)); canvas.fill(CGRect(x:0,y:0,width:width,height:height))
        label("SYSTEM ONE — received images and rendered waveform samples", x:20,y:CGFloat(height-30),in:canvas,size:18)
        label("Gray waveform regions: no detail samples captured. Images remain local.", x:20,y:CGFloat(height-54),in:canvas,size:12)
        for (row, asset) in subset.enumerated() {
            let top = height - 85 - row * rowHeight
            label(asset.label + " [\(asset.width) x \(asset.height)]", x:20,y:CGFloat(top),in:canvas,size:13)
            let data = try Data(contentsOf: output.appendingPathComponent(asset.file))
            guard let picture = image(data) else { continue }
            let scale = min(1400 / CGFloat(picture.width), 150 / CGFloat(picture.height))
            let w = CGFloat(picture.width) * scale, h = CGFloat(picture.height) * scale
            canvas.draw(picture, in: CGRect(x:20,y:CGFloat(top)-12-h,width:w,height:h))
        }
        guard let rendered = canvas.makeImage() else { throw ExportError("Could not render contact sheet") }
        let filename = "image-strip-\(sheets.count + 1).png"
        try png(rendered, at: output.appendingPathComponent(filename))
        sheets.append(filename)
    }
    return sheets
}

func run() throws {
    var args = ArraySlice(CommandLine.arguments.dropFirst())
    guard let inputName = args.popFirst(), inputName != "--help" else {
        print("Usage: SystemOneCapture traffic.ndjson [--output new-directory] [--app djay.app]")
        print("Offline only: export captured images, render detailed waveforms, and create contact sheets outside Git.")
        return
    }
    let input = URL(fileURLWithPath: inputName)
    var output = FileManager.default.temporaryDirectory.appendingPathComponent("system-one-export-\(UUID().uuidString)", isDirectory: true)
    var app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.algoriddim.djay-iphone-free")
    while let flag = args.popFirst() {
        guard let value = args.popFirst() else { throw ExportError("Missing value for \(flag)") }
        switch flag {
        case "--output": output = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        case "--app": app = URL(fileURLWithPath: value)
        default: throw ExportError("Unknown option \(flag)")
        }
    }
    guard !FileManager.default.fileExists(atPath: output.path) else { throw ExportError("Choose a new output directory; existing exports are not overwritten") }
    for ancestor in ancestorDirectories(of: output.deletingLastPathComponent().resolvingSymlinksInPath()) {
        if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
            throw ExportError("Exports must stay outside Git")
        }
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
    guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 128 * 1_048_576 else { throw ExportError("Capture exceeds 128 MiB") }
    let catalog = try app.map { try ProtocolCatalog.load(app: $0) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var assembler = MessageAssembler(), overview = OverviewState()
    var assets: [Asset] = [], seen = Set<String>(), families: [String:Int] = [:]
    var packets = 0, frames = 0, groups = 0, txBytes = 0, errors = 0, partialLines = 0, assemblyErrors = 0
    var cacheSlots = Set<UInt32>()
    let text = try String(contentsOf: input, encoding: .utf8)
    let lines = text.split(whereSeparator: \.isNewline)
    for (lineNumber,line) in lines.enumerated() {
        let record: [String:Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String:Any] else { throw ExportError("Invalid capture record") }
            record = object
        } catch {
            if lineNumber == lines.count - 1 && !text.hasSuffix("\n") { partialLines += 1; break }
            throw error
        }
        if record["kind"] as? String == "packet" { packets += 1 }
        if record["kind"] as? String == "transmit" { txBytes = try CaptureCounters.add(record["length"], to: txBytes) }
        guard record["kind"] as? String == "sysex", let hex = record["hex"] as? String,
              let elapsed = record["elapsed_seconds"] as? Double else { continue }
        frames += 1
        let components = hex.split(separator: " ")
        let raw = components.compactMap { UInt8($0, radix:16) }
        guard raw.count == components.count else { errors += 1; continue }
        let assembly = assembler.consume(raw,time:elapsed)
        guard let frame = assembly.frame else {
            if !assembly.status.hasPrefix("Fragment ") { assemblyErrors += 1 }
            continue
        }
        groups += 1
        let packet = PacketDebugger.inspect(frame,catalog:catalog)
        families[packet.name,default:0] += 1
        overview.consume(packet)
        guard let bytes = packet.image, let decoded = image(bytes) else { continue }
        if let slot = packet.cacheIndex { cacheSlots.insert(slot) }
        let digest = SHA256.hash(data: bytes).map { String(format:"%02x", $0) }.joined()
        let kind = packet.field == 69 ? "overview-waveform" : packet.field == 90 ? "album-art-cache" : "app-icon"
        let index = packet.deckIndex ?? packet.cacheIndex ?? 0
        let identity = "\(kind)-\(index)-\(digest)"
        guard seen.insert(identity).inserted else { continue }
        let suffix = bytes.starts(with: [0xff,0xd8]) ? "jpg" : "png"
        let filename = "\(kind)-\(index)-\(assets.count + 1).\(suffix)"
        let path = output.appendingPathComponent(filename)
        try bytes.write(to:path)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        let name = packet.field == 69 ? "Deck \(UInt64(index)+1) overview waveform" : "\(kind) slot \(index)"
        assets.append(Asset(file:filename,label:name,kind:kind,width:decoded.width,height:decoded.height,sha256:digest))
    }
    for (index,deck) in overview.decks.sorted(by:{$0.key<$1.key}) where !deck.detailChunks.isEmpty {
        let rendered = try detailImage(deck)
        let filename = "deck-\(UInt64(index)+1)-detailed-waveform.png"
        let path = output.appendingPathComponent(filename)
        try png(rendered,at:path)
        let hash = SHA256.hash(data:try Data(contentsOf:path)).map { String(format:"%02x",$0) }.joined()
        assets.append(Asset(file:filename,label:"Deck \(UInt64(index)+1) detail waveform · \(deck.detailSampleCount) received samples",
                            kind:"detailed-waveform",width:rendered.width,height:rendered.height,sha256:hash))
    }
    let strips = try contactSheets(assets,in:output)
    let assetsJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(assets))
    let coverage: [[String:Any]] = overview.decks.sorted { $0.key < $1.key }.map { index,deck in
        ["deck_index": index, "has_title": !deck.title.isEmpty, "has_artist": !deck.artist.isEmpty,
         "has_overview": deck.overview != nil, "detail_samples": deck.detailSampleCount,
         "beat_anchors": deck.beatAnchors, "cues": deck.cues.count,
         "loop_label_present": !deck.loopLabel.isEmpty, "beat_jump_label_present": !deck.beatJumpLabel.isEmpty,
         "art_reference_resolved": deck.artIndex.map { cacheSlots.contains($0) } ?? false]
    }
    let summary: [String:Any] = ["midi_packets":packets,"sysex_frames":frames,"completed_messages":groups,
        "transmitted_bytes":txBytes,"malformed_hex_records":errors,"partial_log_lines":partialLines,"assembly_errors":assemblyErrors,"message_families":families,
        "decoded_library_rows":overview.libraryRows.count,"deck_coverage":coverage,"assets":assetsJSON,"contact_sheets":strips,
        "note":"No track titles or library rows are included in this manifest. Original capture remains the complete source."]
    let summaryURL = output.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]).write(to:summaryURL)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:summaryURL.path)
    print("Decoded \(groups) messages across \(families.count) families; \(overview.libraryRows.count) library rows; TX \(txBytes) bytes.")
    print("Exported \(assets.count) images and \(strips.count) contact sheet(s): \(output.path)")
}
do { try run() } catch {
    FileHandle.standardError.write(Data("SystemOneCapture: \(error)\n".utf8)); exit(1)
}
