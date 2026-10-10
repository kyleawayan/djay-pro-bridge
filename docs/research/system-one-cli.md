# CLI capture and export

Requires macOS 13+, Swift 6.2+, and an installed djay Pro app for full decoding. The tools read the installed executable to load its protobuf schema. Run commands from the checkout.

## Capture live data

**Connecting can unload decks and change audio routing. Connect first, then load tracks.** Do not run another probe or debugger using the same endpoint names.

```sh
swift run SystemOneProbe --identity system-one-display \
  --accept-deck-changes --startup-keepalive --seconds 120
```

The probe creates temporary MIDI endpoints, waits for djay identification, sends one peer-identification keepalive, and records incoming traffic. It prints the capture directory. Omit `--startup-keepalive` for passive capture. No playback or browsing commands are sent.

Ctrl-C or the duration limit ends capture and removes the endpoints. Logs include `traffic.ndjson` and `summary.json`. Capture runs until stopped unless an explicit duration is supplied. Pending-work queues stay bounded; lifetime byte and packet limits are removed. Logs can contain library listings and artwork; keep them local.

## Export images from a capture

```sh
swift run SystemOneCapture /path/to/capture/traffic.ndjson
```

Output goes to a new temporary directory. It includes received images, rendered detail waveforms, image contact sheets and a manifest. Gray waveform regions mean samples were not captured.

Use `--app /path/to/djay.app` to select an installed bundle or `--output /private/tmp/new-export-folder` to choose a new output directory. Existing exports are not overwritten, and output inside Git is rejected. This command creates no MIDI endpoints.

## Export protobufs

```sh
python3 scripts/research/extract_system_one_proto.py '/Applications/djay Pro.app'
```

This reads the specified djay app and prints a new temporary directory containing its descriptor, descriptor set, reconstructed `.proto` and extraction metadata. Without an app argument, it checks standard Applications directories and requires one matching app.

Add `--swift` to generate Swift types using already-installed `protoc` and `protoc-gen-swift`. No tools are installed automatically. These exports are optional: the debugger loads the schema directly from djay.
