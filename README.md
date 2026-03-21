# djay Pro Bridge

A macOS tool that reads real-time deck state from [Algoriddim djay Pro](https://www.algoriddim.com/djay-pro-mac) using the macOS Accessibility API. This only supports djay Pro on Mac.

## Why

djay Pro doesn't expose deck metadata (key, title, artist, BPM) to external software. There's no MIDI output for these values, no network protocol like Pioneer's Pro DJ Link, or any external software such as ShowKontrol for djay Pro.
The first idea was to read djay Pro's memory directly, but this was quickly scrapped — macOS's System Integrity Protection (SIP) blocks cross-process memory reading, and disabling it would compromise system security. This was not worth it for me.
The next idea was polling djay Pro's song database and tracking MIDI input to reconstruct state externally, but this would get out of sync fast — especially when the DJ shifts keys or loads tracks in ways the external tracker can't anticipate.
The breakthrough (with some help from Claude) was discovering that macOS has Accessibility APIs that let you read text and values directly from any app's UI. djay Pro, being a Mac-native app, exposes a rich accessibility tree with labeled elements for every deck — key, title, artist, and more. The only way to get this data out without compromising system security is through the macOS Accessibility API, which reads the live UI state directly — including any key shifts or changes the DJ makes in real time.

## Setup

1. **Xcode Command Line Tools** must be installed.

2. **Grant Accessibility permission** to whatever is running the Swift script (Terminal, iTerm2, VSCode, etc.).

3. **Run djay Pro.**

4. **Run the reader:**
   ```bash
   swift reader.swift
   ```

The script polls djay Pro and prints deck state whenever the key changes:

```
❯ swift reader.swift
✅ Found djay Pro (PID: 61275)
🎧 Polling djay Pro every 50ms... (Ctrl+C to stop)
[6:36:36 PM]
  Deck 1: What It Sounds Like (AWAIAN Future House Remix) by HUNTR/X, EJAE, AUDREY NUNA, REI AMI & KPop Demon Hunters Cast, AWAIAN | Key: e
  Deck 2: My Way (AWAIAN Remix) by KATSEYE, AWAIAN | Key: e flat
^C
```

## Discovering More Accessibility Elements

> **Note:** This section requires the full Xcode app installed (not just Command Line Tools).

djay Pro exposes a rich accessibility tree — far more than just key and title. To explore what's available:

1. Open **Accessibility Inspector** — in Xcode, go to **Xcode → Open Developer Tool → Accessibility Inspector**.

2. In Accessibility Inspector, select your Mac as the target device from the dropdown in the top left.

3. Click the **crosshair/target button** (or press `⌥Space`) to enable the inspection pointer.

4. Hover over any element in djay Pro's UI. The inspector will show:
   - **Label** (`AXDescription`) — the element's accessible name, e.g., `"Key, Deck 1"`
   - **Value** — the current displayed value, e.g., `"c minor"`
   - **Role** — the element type (`AXButton`, `AXStaticText`, etc.)
   - **Parent/Children** — the full hierarchy

5. Use the **hierarchy view** (the tree icon in the toolbar) to browse the full element tree without hovering. The structure is:
   ```
   djay Pro (ARApplication)
     └─ djay Pro (standard window) [NSWindow]
        └─ Decks (group) [ARMacMetalView]
           ├─ Key, Deck 1 (button)
           ├─ Title, Deck 1 (text)
           ├─ Artist, Deck 1 (text)
           ├─ Waveform, Deck 1 (unknown)
           ├─ Neural Mix Solo (3ch: Vocals), Deck 1 (button)
           ├─ ...
           └─ [Deck 2 elements follow the same pattern]
   ```

Element labels consistently follow the pattern `"PropertyName, Deck N"`, which makes them straightforward to query programmatically.

## License

MIT
