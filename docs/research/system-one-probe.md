# Passive SYSTEM ONE recognition probe

The passive probe creates temporary MIDI endpoints and records traffic sent to them. It sends no startup reply. For metadata and waveform capture, use [the initialized CLI workflow](system-one-cli.md#capture-live-data).

Requires macOS 13+ and Swift 6.2+. Swift Package Manager resolves SwiftProtobuf 1.38.1 on the first build.

**Even a passive connection can unload decks or change audio routing. Use an idle djay session with empty decks.**

1. Build the probe:
   ```sh
   swift build --product SystemOneProbe
   ```
2. Capture with generic endpoint names:
   ```sh
   swift run --skip-build SystemOneProbe --identity generic
   ```
3. After that process exits, compare the SYSTEM ONE display identity:
   ```sh
   swift run --skip-build SystemOneProbe --identity system-one-display --accept-deck-changes
   ```

Each run prints its temporary capture directory. Ctrl-C stops capture and removes its endpoints. Do not run multiple probes using the same endpoint names.

Appearing as a MIDI device is not proof of protocol initialization. Passive traffic may include identification, generic images or playhead updates without full metadata. Silence is inconclusive. The initialized workflow sends the one-time identification needed for the tested full stream.
