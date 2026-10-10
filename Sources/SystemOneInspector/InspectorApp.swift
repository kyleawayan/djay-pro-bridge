import AppKit
import ImageIO
import SwiftUI
import SystemOneProbeSupport

@MainActor
final class InspectorAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: InspectorModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}

@main
struct SystemOneInspectorApp: App {
    @NSApplicationDelegateAdaptor(InspectorAppDelegate.self) private var delegate
    @StateObject private var model = InspectorModel()
    var body: some Scene {
        Window("SYSTEM ONE packet debugger", id: "inspector") {
            DashboardWindow(model: model).onAppear { delegate.model = model }
                .frame(minWidth: 950, minHeight: 700).preferredColorScheme(.dark)
        }.defaultSize(width: 1150, height: 850)
    }
}

struct PacketWindow: View {
    @ObservedObject var model: InspectorModel
    var embedded = false
    @State private var unpacked = false
    @State private var page = 0
    private var snapshot: PacketSnapshot? { model.selectedPacket }
    private var bytes: [UInt8] { unpacked ? snapshot?.packet.payload ?? [] : snapshot?.raw ?? [] }
    private var changes: [Date] { unpacked ? snapshot?.payloadChanged ?? [] : snapshot?.changed ?? [] }
    private var keys: [UInt64] { Array(Set(model.scopedPackets.keys).union(model.selectedScope == .global ? [1] : [51])).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !embedded {
            HStack {
                Picker("Identity", selection: $model.identity) {
                    Text("SYSTEM ONE Port 2").tag("system-one-display")
                    Text("Neutral").tag("generic")
                }.frame(width: 255).disabled(model.busy)
                Button(model.connected ? "Disconnect" : "Connect") { model.connected ? model.stop() : model.connect() }
                    .disabled(!model.connected && !model.canConnect)
                Button("Open capture…", action: model.chooseCapture).disabled(model.busy)
                Toggle("Freeze display", isOn: $model.freezeDisplay).toggleStyle(.checkbox)
                Spacer()
                Text(model.phase).foregroundStyle(model.connected ? .green : .secondary)
            }
            HStack {
                Text("packets=\(model.state.packets)  sysex=\(model.state.messages)  rx=\(model.state.bytes) B  tx=\(model.state.transmittedBytes) B")
                Spacer()
                if let directory = model.logDirectory { Button("Local logs") { NSWorkspace.shared.open(directory) } }
            }.font(.system(.caption, design: .monospaced))
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
            }
            Picker("Packet scope", selection: $model.selectedScope) {
                ForEach(model.scopes, id: \.self) { scope in Text(scope.title).tag(scope) }
            }.pickerStyle(.menu).frame(maxWidth: 330)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MESSAGE TYPES").foregroundStyle(.yellow)
                        ForEach(keys, id: \.self) { key in
                            Button {
                                model.selectedType = key
                                page = 0
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key == UInt64.max ? "Unclassified / fragments" : "\(key)  \(model.scopedPackets[key]?.packet.name ?? (key == 1 ? "keep_alive" : "set_deck_playhead_position"))")
                                        .lineLimit(3)
                                    Text("n=\(model.scopedPackets[key]?.count ?? 0)").foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                    .background(model.selectedType == key ? Color.blue.opacity(0.25) : .clear)
                            }.buttonStyle(.plain)
                        }
                        Divider()
                        Text("\(model.schemaStatus)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text("Waveform families").foregroundStyle(.yellow)
                        Text("62  RGB/height samples\n63  beat-grid anchors\n69  overview image")
                        Text("No packets of a family means no live preview. Decoding support does not imply reception.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: 11, design: .monospaced)).padding(6)
                }.frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(snapshot?.packet.name ?? "Waiting for field \(model.selectedType)").foregroundStyle(.yellow)
                            Spacer()
                            Toggle("Unpacked protobuf", isOn: $unpacked).toggleStyle(.checkbox)
                        }
                        Text("Green: recognized framing · white: payload bytes · blue background: changed within 1 second")
                            .foregroundStyle(.secondary).font(.caption)
                        if bytes.count > 256 {
                            Stepper("Byte page \(page + 1)/\(max(1, (bytes.count + 255) / 256))", value: $page, in: 0...max(0, (bytes.count - 1) / 256))
                        }
                        hexGrid
                        if model.selectedScope == .global && model.selectedType == 90 && !model.state.store.images.isEmpty {
                            Picker("Image cache slot", selection: $model.selectedImageIndex) {
                                ForEach(model.state.store.images.keys.sorted(), id: \.self) { index in
                                    Text("Slot \(index)").tag(index)
                                }
                            }.pickerStyle(.segmented)
                        }
                        if let snapshot {
                            Text(String(format: "RX +%.3f s   frame=%d B   protobuf=%d B   %@", snapshot.elapsed, snapshot.raw.count, snapshot.packet.payload.count, snapshot.assembly))
                                .foregroundStyle(.yellow)
                            Text(snapshot.packet.status).font(.caption).foregroundStyle(.secondary)
                            Divider()
                            if let data = model.activeStream?.telemetry {
                                Text("\(model.selectedScope.title) realtime: position=\(numeric(data.position))  velocity=\(numeric(data.rate))  timestamp=\(numeric(data.senderClock))")
                                    .foregroundStyle(.green).textSelection(.enabled)
                            }
                            LazyVStack(alignment: .leading) {
                            ForEach(snapshot.packet.fields) { field in
                                HStack(alignment: .top, spacing: 12) {
                                    Text(String(repeating: "  ", count: field.depth) + field.name).foregroundStyle(.green).frame(width: 285, alignment: .leading)
                                    Text(field.value).textSelection(.enabled)
                                    Spacer(minLength: 0)
                                    Text(field.wire).foregroundStyle(.secondary).font(.system(size: 10, design: .monospaced))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            }
                            Text("Implicit scalar defaults are labeled. Explicit optional presence remains distinct.")
                                .font(.caption).foregroundStyle(.secondary)
                            preview(snapshot.packet)
                        } else { Text("Connect, then load/play a track; or open a saved traffic.ndjson.").foregroundStyle(.secondary) }
                    }.font(.system(size: 12, design: .monospaced)).padding(10).frame(minWidth: 700, alignment: .leading)
                }.background(.black)
            }
        }.padding(10)
            .onChange(of: model.selectedScope) { scope in
                model.selectedType = scope == .global ? 1 : 51
                page = 0
            }
            .onChange(of: model.state.store.images.keys.sorted()) { indices in
                if !indices.contains(model.selectedImageIndex), let first = indices.first { model.selectedImageIndex = first }
            }
            .onChange(of: model.selectedImageIndex) { _ in page = 0 }
            .onChange(of: unpacked) { _ in page = 0 }
            .onChange(of: bytes.count) { count in page = min(page, max(0, (count - 1) / 256)) }
    }

    private var hexGrid: some View {
        let start = page * 256
        let end = min(bytes.count, start + 256)
        let rows = start < end ? (end - start + 15) / 16 : 0
        return Grid(alignment: .leading, horizontalSpacing: 7, verticalSpacing: 3) {
            GridRow {
                Text("offset").foregroundStyle(.yellow)
                ForEach(0..<16, id: \.self) { column in Text(String(format: "%x", column)).foregroundStyle(.yellow).frame(width: 25) }
            }
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    Text(String(format: "%04x", start + row * 16)).foregroundStyle(.yellow)
                    ForEach(0..<16, id: \.self) { column in
                        let index = start + row * 16 + column
                        if index < end {
                            let age = index < changes.count ? max(0, model.now.timeIntervalSince(changes[index])) : 2
                            Text(String(format: "%02x", bytes[index]))
                                .foregroundStyle(!unpacked && (index < 6 || index == bytes.count - 1) ? .green : .white)
                                .frame(width: 25).background(Color.blue.opacity(max(0, 1 - age)))
                        } else { Text("  ").frame(width: 25) }
                    }
                }
            }
        }.font(.system(size: 15, design: .monospaced)).textSelection(.enabled)
    }

    @ViewBuilder private func preview(_ packet: DebugPacket) -> some View {
        if let data = packet.waveform {
            Divider()
            Text("WAVEFORM CHUNK · \(data.count / 4) samples · offset \(packet.waveformOffset ?? 0) · RGB/height, not PCM").foregroundStyle(.yellow)
            WaveformPlot(bytes: data).frame(height: 140).border(.gray.opacity(0.4))
        }
        if let data = packet.image {
            Divider()
            Text(packet.field == 69 ? "OVERVIEW WAVEFORM IMAGE" : "ALBUM-ART CACHE IMAGE · meaning not inferred").foregroundStyle(.yellow)
            if let image = safeImage(data) {
                Text("\(Int(image.size.width)) × \(Int(image.size.height)) pixels").foregroundStyle(.secondary)
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 760, maxHeight: 260)
            } else { Text("Image could not be decoded or exceeds the preview limit (8 MP maximum).").foregroundStyle(.secondary) }
        }
    }
    private func numeric(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "absent" }
    private func safeImage(_ data: Data) -> NSImage? {
        DecodedImageCache.shared.image(for: data)
    }

}

struct WaveformPlot: View {
    let bytes: [UInt8]
    var body: some View {
        Canvas { context, size in
            let count = bytes.count / 4
            guard count > 0 else { return }
            let columns = min(count, max(1, Int(size.width)))
            for column in 0..<columns {
                let sample = column * count / columns
                let index = sample * 4
                let height = Double(bytes[index + 3]) / 255 * size.height
                let x = Double(column) / Double(columns) * size.width
                let color = Color(red: Double(bytes[index]) / 255, green: Double(bytes[index + 1]) / 255, blue: Double(bytes[index + 2]) / 255)
                context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: max(1, size.width / Double(columns)), height: height)), with: .color(color))
            }
        }
    }
}
