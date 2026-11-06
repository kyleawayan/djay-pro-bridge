# SYSTEM ONE packet debugger

A debug window for live controller telemetry and saved captures. Tested with djay Pro 5.6.9 on macOS; future compatibility is not guaranteed.

## Before running

Requires macOS 13+, Swift 6.2+, and an installed djay Pro app for full decoding. Swift Package Manager resolves SwiftProtobuf 1.38.1. At startup, the debugger reads the installed djay executable on disk to load its protobuf schema. Exporting schemas or generating Swift types is optional.

**Connecting can unload decks and change audio routing. Connect before loading tracks.** Disconnecting does not restore prior djay state.

## Use

1. Start djay and run `swift run SystemOneInspector` from the checkout.
2. Press **Connect**, then load and play tracks in djay. All decks and Global/Library remain visible together.
3. Expand **Raw packets and every decoded field** to inspect received message families, bytes and field values.
4. Use **Freeze** to hold the display while capture continues, or **Open capture…** to inspect a saved `traffic.ndjson` offline.
5. Press **Disconnect** to stop capture and remove the temporary MIDI endpoints.

Connect and capture import wait for schema loading to finish. If loading fails, the UI reports the limitation and offers limited numeric decoding.

## Reading the display

Deck panels show metadata, artwork, playhead position, overview/detail waveforms, beat grids, cues and loops when received. Global/Library shows received library rows and selection. Image-cache slots may contain generic icons; deck covers use the received artwork references.

Waveform gaps mean no samples have arrived for that region. Beat lines use received anchors and interpolate only between valid neighbors. Unverified nonzero grid-start offsets suppress the overlay. UI redraws are coalesced to at most 30 per second; recording follows incoming data independently.

The startup exchange sends one peer-identification keepalive. No playback or browsing commands are sent. Logs can contain library listings and artwork; keep them local.

## Build and test

```sh
swift build --product SystemOneInspector
swift test --filter 'SystemOne.*Tests'
python3 scripts/research/package_inspector.py \
  "$(swift build --show-bin-path)/SystemOneInspector" \
  '.build/System One Packet Debugger.app' \
  --name 'System One Packet Debugger' \
  --bundle-id com.example.system-one-packet-debugger
```

The packaging helper creates a new local app bundle and refuses to overwrite an existing one. It does not install or launch it.

See [how it works](system-one-protocol.md), [CLI capture and export](system-one-cli.md), and [credits](../../README.md#credits).

## Sync with OBS on another computer

The debugger can align recordings with OBS running on a separate computer, such as a Windows PC, over the local network. Nothing is installed on the OBS computer; OBS 28 and later include the WebSocket server.

1. In OBS, open **Tools → WebSocket Server Settings**, enable the server, and note the port and password.
2. In the debugger's **OBS** row, enter the OBS computer's IP address, port and password, then press **Connect OBS**.
3. Start telemetry recording as usual. Sync data is saved only while telemetry recording is active.
4. Record in OBS, or press **Record in OBS** in the debugger. With **Start and stop OBS too** checked, Start Recording also starts OBS, and Stop Recording stops OBS first so its file path is saved in the session. The status line shows the recording position, round-trip time and fit quality.

Once per second, the debugger asks OBS for its recording position and stamps the request and reply with the Mac's clock. The OBS computer's clock is never used. Slow round trips are discarded when fitting, so Wi-Fi works; venue networks that block device-to-device traffic do not. Use a hotspot from the OBS computer in that case. Dropped connections retry every 2 seconds until **Disconnect OBS**.

The password is stored in the macOS Keychain. macOS may ask for Local Network permission on first connect.

### OBS sync format

`obs-sync.ndjson` sits beside `events.ndjson` and is named by `obs_sync` in `session.json`. `t` uses the same clock origin as events; values can be slightly negative for a request sent just before recording started.

- `{"kind":"sample","t","rtt_ms","video_ms","active","paused"}` — `t` is the midpoint between request and reply. `video_ms` is OBS's `outputDuration`, which steps once per video frame.
- `{"kind":"state","t","state","active","path"}` — a `RecordStateChanged` event, timed on arrival. `path` is the recording file on the OBS computer once recording stops.

To map telemetry to video, fit `video_ms = a + b·t` per recording, keeping samples whose `rtt_ms` is within max(1.5 × best, best + 2 ms). `OBSSyncFit` implements this. The slope absorbs clock-rate differences between the two computers. Two limits remain unverified with live equipment: whether `outputDuration` stops advancing during an OBS pause, and the fixed delay between OBS's frame count and what the camera saw. Check both with a clap or flash test and use the editor's sync offset for any constant remainder.

## Session recording format

Start/Stop Recording writes a general-purpose telemetry session independently of display refresh. Each session contains `session.json`, `events.ndjson` and content-addressed assets. The manifest uses `monotonic-ns` with `CLOCK_UPTIME_RAW`; event `t` values are seconds since `clock_origin_ns`. `created_at` is the recording start time.

Deck snapshots include `loopEnabled` and `loopRegions`. Each region retains its protocol `index`, `start`, `end` and numeric `status`; status values are not interpreted as a playback flag. Boundaries preserve the received values, including omitted proto3 zero defaults. Their units and real-device loop behavior remain unverified. Region removal and deck clearing produce updated snapshots.

A `deck-artwork` event with `asset: null` removes a cover. Final transport drops and writer failures mark the manifest incomplete. Long-duration live recording remains unverified; synthetic tests cover loop lifecycle, snapshots, creation time, artwork removal and terminal transport loss.
