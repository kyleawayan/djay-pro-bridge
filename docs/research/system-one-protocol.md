# How the SYSTEM ONE proof of concept works

Tested with djay Pro 5.6.9 on macOS. This is experimental; future versions may require changes. The production Accessibility reader is separate.

## Connection and decoding

1. The debugger reads the installed djay executable on disk and locates its embedded protobuf descriptor. It searches for a recognizable schema rather than a fixed byte offset.
2. It creates temporary MIDI input/output endpoints with the SYSTEM ONE display-port name.
3. After djay identifies itself, the debugger sends one peer-identification keepalive to start the metadata stream.
4. Incoming MIDI SysEx fragments are reassembled and unpacked into protobuf messages. The local schema supplies field names and types; handwritten views interpret the supported data.

**Connecting can unload decks and change audio routing. Connect before loading tracks.** Disconnecting does not restore prior djay state. The debugger sends no playback or browsing commands.

## Available data

The tested connection delivered track metadata, playhead updates, artwork, library rows and selection, waveforms, beat grids, cues and loop data. The packet view exposes additional received fields.

Overview waveforms are encoded images. Detailed waveforms contain RGB/height display samples, not audio. Missing detail regions remain blank; the debugger does not reconstruct samples it has not received. Initial image-cache entries can be generic icons rather than track artwork.

The library view shows received rows, not a complete library export. No controller hardware is required for the tested Mac connection. Mobile compatibility and other djay versions are unverified.

## Version changes

Moving the same descriptor within the executable need not break discovery. Changes to its format or location, MIDI framing, startup exchange or field meanings can require code updates. Exporting new types does not automatically update the handwritten decoder or views.

For usage, see [the debugger guide](system-one-inspector.md) and [CLI capture and protobuf export](system-one-cli.md).
