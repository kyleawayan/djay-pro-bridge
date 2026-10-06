import AppKit
import ImageIO
import SwiftUI
import SystemOneProbeSupport

struct DashboardWindow: View {
    @ObservedObject var model: InspectorModel
    @State private var rawExpanded = false
    private var deckIndices: [UInt32] { Array(Set(model.state.overview.decks.keys).union([0,1])).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(model.connected ? "Disconnect" : "Connect") { model.connected ? model.stop() : model.connect() }
                    .disabled(!model.connected && !model.canConnect)
                Button("Open capture…", action: model.chooseCapture).disabled(model.busy)
                Picker("Listen", selection: $model.duration) {
                    Text("2 min").tag(120); Text("5 min").tag(300); Text("10 min").tag(600)
                }.frame(width: 150).disabled(model.busy)
                Toggle("Freeze", isOn: $model.freezeDisplay).toggleStyle(.checkbox)
                Spacer()
                Text(model.phase).foregroundStyle(model.connected ? .green : .secondary)
                if model.connected { Text("\(model.secondsRemaining)s").monospacedDigit() }
                if let directory = model.logDirectory { Button("Logs") { NSWorkspace.shared.open(directory) } }
            }
            HStack {
                Text(model.startupStatus)
                Spacer()
                Text("\(model.state.messages) SysEx · RX \(ByteCountFormatter.string(fromByteCount: Int64(model.state.bytes), countStyle: .file)) · TX \(model.state.transmittedBytes) B")
            }.font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(deckIndices, id: \.self) { index in
                            DeckPanel(index: index, deck: model.state.overview.decks[index] ?? DeckOverview(), images: model.state.store.images)
                        }
                    }
                    libraryPanel
                    DisclosureGroup("Raw packets and every decoded field", isExpanded: $rawExpanded) {
                        PacketWindow(model: model, embedded: true).frame(height: 580)
                    }.padding(10).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                }.padding(.bottom, 10)
            }
        }.padding(12)
    }

    private var libraryPanel: some View {
        let state = model.state.overview
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Artwork(data: model.state.store.latest[.global]?[94]?.packet.image, size: 24)
                Text("Global / Library").font(.headline)
                Text(state.libraryTitle.isEmpty ? "Waiting for library data" : state.libraryTitle).foregroundStyle(.secondary)
                Spacer()
                Text("djay \(state.appVersion ?? "—") · \(state.libraryRows.count)/\(state.libraryRowCount.map(String.init) ?? "?") rows · \(model.state.store.images.count) cached images").font(.caption)
            }
            if state.libraryRows.isEmpty {
                Text("No library rows received. Connect initializes the native data stream; browsing in djay then updates this view.")
                    .foregroundStyle(.secondary).font(.caption).padding(.vertical, 12)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    GridRow {
                        Text("Row"); Text("Art"); Text("Title / artist"); Text("BPM"); Text("Key"); Text("Length")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(state.libraryRows.values.sorted(by: { $0.id < $1.id })) { row in
                        GridRow {
                            Text("\(UInt64(row.id) + 1)").monospacedDigit()
                            Artwork(data: row.artIndex.flatMap { model.state.store.images[$0]?.packet.image }, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                if !row.artist.isEmpty { Text(row.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.tempo.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                            Text(row.key).font(.caption)
                            Text(timeLabel(row.duration)).monospacedDigit()
                        }.padding(.vertical, 3).background(state.selectedLibraryRow == row.id ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                }.font(.callout)
            }
            DisclosureGroup("All received library-row fields") {
                ForEach(state.libraryRows.values.sorted(by: { $0.id < $1.id })) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Row \(UInt64(row.id) + 1)").bold()
                        ForEach(row.packet.fields) { field in
                            Text("\(field.name): \(field.value)").textSelection(.enabled)
                        }
                    }.font(.caption).padding(.vertical, 4)
                }
            }.font(.caption)
            DisclosureGroup("Other received global values") {
                ForEach((model.state.store.latest[.global] ?? [:]).keys.sorted(), id: \.self) { key in
                    if ![UInt64(85),90,94].contains(key), let packet = model.state.store.latest[.global]?[key]?.packet {
                        VStack(alignment: .leading) {
                            Text(packet.name).bold()
                            ForEach(packet.fields) { field in Text("\(field.name): \(field.value)").textSelection(.enabled) }
                        }.font(.caption).padding(.vertical, 4)
                    }
                }
            }.font(.caption)
            Text("Selection follows djay. This view does not send browsing or playback commands.").font(.caption2).foregroundStyle(.secondary)
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DeckPanel: View {
    let index: UInt32
    let deck: DeckOverview
    let images: [UInt32: PacketSnapshot]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Artwork(data: deck.artIndex.flatMap { images[$0]?.packet.image }, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deck \(UInt64(index) + 1) · index \(index)").font(.caption).foregroundStyle(.secondary)
                    Text(deck.title.isEmpty ? "No track metadata received" : deck.title).font(.headline).lineLimit(2)
                    Text(deck.artist.isEmpty ? "—" : deck.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("BPM \(deck.tempo.map { String(format: "%.2f", $0) } ?? "—")")
                Text("Key \(deck.key.isEmpty ? "—" : deck.key)")
                Spacer()
                Text(deck.keyLock ? "Key lock on" : "Key lock off")
            }.font(.system(.caption, design: .monospaced))
            HStack {
                Text("\(timeLabel(deck.elapsed)) / \(timeLabel(deck.duration))")
                Spacer()
                Text("Rate \(deck.velocity.map { String(format: "%.3f×", $0) } ?? "—")")
                Text(deck.position.map { String(format: "%.2f%%", $0 * 100) } ?? "—")
            }.font(.system(.caption, design: .monospaced))
            if let data = deck.overview, let image = previewImage(data) {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 65)
                    .frame(maxWidth: .infinity).background(.black)
                    .overlay(Canvas { context, size in
                        if let duration = deck.duration, duration > 0, let rate = deck.sampleRate {
                            let lines = WaveformBeatGrid.lines(anchors: deck.beatGrid, sampleRate: rate,
                                                               trackStart: deck.trackStart)
                            var previousX = -Double.infinity
                            for line in lines where line.received && line.downbeat {
                                let x = line.seconds / duration * size.width
                                guard x >= 0, x <= size.width, x - previousX >= 8 else { continue }
                                previousX = x
                                context.stroke(Path { path in
                                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                                }, with: .color(.white.opacity(0.45)), lineWidth: 1)
                            }
                        }
                        if let position = deck.position, position.isFinite {
                            let x = min(1, max(0, position)) * size.width
                            context.stroke(Path { path in
                                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                            }, with: .color(.red), lineWidth: 1)
                        }
                    })
            } else { placeholder("Overview waveform not received", height: 65) }
            if !deck.detailChunks.isEmpty {
                DetailWaveform(deck: deck).frame(height: 65).background(.black)
            } else { placeholder("Detailed waveform not received", height: 65) }
            HStack {
                Text("\(deck.detailSampleCount) detail samples · \(deck.beatAnchors) beat anchors")
                Spacer()
                Text("\(deck.cues.count) cues · \(deck.loops.count) loops")
            }.font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text("Loop \(deck.loopLabel.isEmpty ? "—" : deck.loopLabel)\(deck.loopEnabled ? " · ON" : "")")
                Text("Beat jump \(deck.beatJumpLabel.isEmpty ? "—" : deck.beatJumpLabel)")
                Spacer()
                Text("Pitch range \(deck.speedRange.isEmpty ? "—" : deck.speedRange)")
            }.font(.caption)
            if !deck.cuePackets.isEmpty || !deck.loopPackets.isEmpty {
                DisclosureGroup("Cue and loop values") {
                    ForEach(deck.cuePackets.keys.sorted(), id: \.self) { cue in
                        Text("Cue \(cue): " + fieldsLabel(deck.cuePackets[cue]!)).font(.caption).textSelection(.enabled)
                    }
                    ForEach(deck.loopPackets.keys.sorted(), id: \.self) { loop in
                        Text("Loop \(loop): " + fieldsLabel(deck.loopPackets[loop]!)).font(.caption).textSelection(.enabled)
                    }
                }.font(.caption)
            }
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
    }
    private func fieldsLabel(_ packet: DebugPacket) -> String {
        packet.fields.filter { $0.depth == 0 && !$0.name.hasSuffix(": deckIndex") }.map { "\($0.name)=\($0.value)" }.joined(separator: " · ")
    }
    private func placeholder(_ label: String, height: CGFloat) -> some View {
        Rectangle().fill(.black.opacity(0.35)).frame(height: height)
            .overlay(Text(label).font(.caption).foregroundStyle(.secondary))
    }
}

private struct DetailWaveform: View {
    let deck: DeckOverview
    var body: some View {
        Canvas { context, size in
            let samplesPerSecond = 315.0
            let requested = (deck.elapsed ?? 0) * samplesPerSecond
            let center = requested.isFinite ? min(Double(UInt32.max), max(0, requested)) : 0
            let start = max(0, center - 6 * samplesPerSecond)
            let span = 12 * samplesPerSecond
            let bars = WaveformEnvelope.bars(chunks: deck.detailChunks, viewportStart: start,
                                               span: span, width: size.width)
            for bar in bars {
                let height = bar.height * size.height
                let x = bar.x(viewportStart: start, span: span, width: size.width)
                let width = Double(bar.sampleCount) / span * size.width
                let color = Color(red: bar.red, green: bar.green, blue: bar.blue)
                context.fill(Path(CGRect(x: x, y: (size.height - height) / 2,
                                         width: width, height: height)), with: .color(color))
            }
            if let rate = deck.sampleRate {
                for line in WaveformBeatGrid.lines(anchors: deck.beatGrid, sampleRate: rate,
                                                    trackStart: deck.trackStart) {
                    let x = (line.seconds * samplesPerSecond - start) / span * size.width
                    guard x >= 0, x <= size.width else { continue }
                    context.stroke(Path { path in
                        path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(.white.opacity(line.downbeat ? 0.65 : 0.25)),
                       lineWidth: line.downbeat ? 1.5 : 0.75)
                }
            }
            let cursor = (center - start) / span * size.width
            context.stroke(Path { path in path.move(to: CGPoint(x: cursor, y: 0)); path.addLine(to: CGPoint(x: cursor, y: size.height)) }, with: .color(.red), lineWidth: 1)
        }.clipped()
    }
}

private struct Artwork: View {
    let data: Data?
    let size: CGFloat
    var body: some View {
        Group {
            if let data, let image = previewImage(data) { Image(nsImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(.primary.opacity(0.05)).overlay(Text("—").foregroundStyle(.secondary)) }
        }.frame(width: size, height: size)
    }
}

private func timeLabel(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, abs(seconds) < 1_000_000_000 else { return "—:—" }
    let value = max(0, seconds)
    return String(format: "%02d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
}

@MainActor
private func previewImage(_ data: Data) -> NSImage? {
    DecodedImageCache.shared.image(for: data)
}
