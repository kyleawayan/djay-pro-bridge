# djay Pro Bridge

A macOS tool that reads real-time deck state from [Algoriddim djay Pro](https://www.algoriddim.com/djay-pro-mac) using the macOS Accessibility API. This only supports djay Pro on Mac.

![Terminal window showing the djay Pro Bridge TUI overlaid on top of Algoriddim djay Pro's DJ interface. The TUI displays real-time deck state for two decks, showing track title, artist, key, BPM, pitch percentage, and elapsed/remaining time with tilde-approximate tenth-of-a-second precision for each. Behind the terminal, djay Pro's track info confirm the data matches the live UI.](./thumbnail.jpg)

## Table of Contents

- [djay Pro Bridge](#djay-pro-bridge)
  - [Table of Contents](#table-of-contents)
  - [Why](#why)
  - [Setup](#setup)
    - [Dump](#dump)
  - [Discovering More Accessibility Elements](#discovering-more-accessibility-elements)
  - [Time Display](#time-display)
    - [Time availability](#time-availability)
  - [Available Data Per Deck](#available-data-per-deck)
    - [Readable Values](#readable-values)
    - [Action-Only Buttons (WIP)](#action-only-buttons-wip)
    - [Other (not per-deck)](#other-not-per-deck)
  - [License](#license)

## Why

djay Pro doesn't expose deck metadata (key, title, artist, BPM) to external software. There's no MIDI output for these values, no network protocol like Pioneer's Pro DJ Link, or any external software such as ShowKontrol for djay Pro.

The first idea was to read djay Pro's memory directly, but this was quickly scrapped — macOS's System Integrity Protection (SIP) blocks cross-process memory reading, and disabling it would compromise system security. This was not worth it for me.

The next idea was polling djay Pro's song database and tracking MIDI input to reconstruct state externally, but this would get out of sync fast — especially when the DJ shifts keys or loads tracks in ways the external tracker can't anticipate.

The breakthrough (with some help from Claude) was discovering that macOS has Accessibility APIs that let you read text and values directly from any app's UI. djay Pro, being a Mac-native app, exposes a rich accessibility tree with labeled elements for every deck — key, title, artist, and more. The only way to get this data out without compromising system security is through the macOS Accessibility API, which reads the live UI state directly — including any key shifts or changes the DJ makes in real time.

## Setup

1. **Xcode Command Line Tools** must be installed.

2. **Grant Accessibility permission** to whatever runs the tool (Terminal, iTerm2, VSCode, etc.).

3. **Run djay Pro.**

4. **Run the reader:**
   ```bash
   swift run Reader
   ```

The reader shows a live TUI display of deck state:

```
djay Pro Bridge

Deck 1 ▶
  What It Sounds Like (AWAIAN Future House Remix)
  HUNTR/X, EJAE, AUDREY NUNA, REI AMI & KPop Demon Hunters Cast, AWAIAN
  Key: e
  BPM: 124.0 (0.0%) | 01:35.~4 / -05:05.~6

Deck 2 ⏸
  My Way (AWAIAN Remix)
  KATSEYE, AWAIAN
  Key: e flat
  BPM: 128.0 (0.0%) | 00:00.~0 / -02:58.~0
```

Options:

```bash
swift run Reader --interval 100  # render interval in ms (default 33, ~30fps)
swift run Reader --log           # scrolling log output instead of TUI
```

The reader uses two threads: a background thread polls djay Pro's accessibility tree continuously (estimated ~8fps, limited by the cost of the accessibility tree walk), while the main thread renders at the `--interval` rate. The higher render rate allows smooth interpolated deck timestamps, which is important for timecode output that can be added later.

### Dump

The dump tool outputs all discovered accessibility elements as JSON:

```bash
swift run Dump                # prints JSON to stdout
swift run Dump > elements.json  # save to file
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
           ├─ Title, Deck 1 (text)
           ├─ Artist, Deck 1 (text)
           ├─ Key, Deck 1 (button)
           ├─ Remaining time, Deck 1 (button)
           ├─ 124.0, Deck 1 (button)             ← BPM (value-as-label)
           ├─ 0.0%, Deck 1 (button)              ← BPM % (value-as-label)
           ├─ Play / Pause, Deck 1 (button)
           ├─ Waveform, Deck 1 (unknown)
           ├─ ...
           └─ [Deck 2 elements follow the same pattern]
   ```

Element labels follow two patterns:

1. **Standard**: `"PropertyName, Deck N"` — the label names the property, the value holds the data. E.g. `"Key, Deck 1"` has value `"e"`.
2. **Value-as-label**: The label itself IS the data. E.g. `"124.0, Deck 1"` is the BPM number, `"0.0%, Deck 1"` is the BPM percentage. The element's value field holds something else (slider position).

## Time Display

The reader shows elapsed and remaining time with sub-second precision (one decimal place). Since the Accessibility API only provides whole-second `MM:SS` values, the fractional second is **interpolated** between polls using wall-clock time. Interpolated values are shown with a `~` prefix (e.g. `01:35.~4`) to indicate they are approximate.

The interpolator accounts for tempo changes — if BPM% is `+3.2%`, time advances 3.2% faster than wall clock. On every poll, the interpolator **snaps to reality**: if the new AX time differs from the prediction by more than ~1 second (e.g. looping, or track jumps), it resets instantly rather than trying to smooth the difference.

### Time availability

Which time values are visible depends on djay Pro's current view:

| View                                                    | Elapsed | Remaining |
| ------------------------------------------------------- | ------- | --------- |
| Jog view enabled                                        | Yes     | Yes       |
| Timer (next to key value in app) showing remaining time | No      | Yes       |
| Timer (next to key value in app) showing elapsed time   | Yes     | No        |

Note: the timer toggle (next to the key value in the app) to show remaining or elapsed time is per deck — it is not global.

When a time value isn't available, the reader shows `--:--.~-` as a placeholder with a hint to change the view.

## Available Data Per Deck

Everything below is read per deck (Deck 1, 2, etc.) from the accessibility tree.

> **Note:** These may highly vary or depend on the specific view mode that is showing in djay Pro. This is due to the accessibility tree changing based on the view mode. These are the initial ones I found with my current configuration.

### Readable Values

| Element               | Role                  | Example Value                                     | Notes                                                                                                                                                                         |
| --------------------- | --------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Title                 | AXStaticText          | `What It Sounds Like (AWAIAN Future House Remix)` |                                                                                                                                                                               |
| Artist                | AXStaticText          | `HUNTR/X`                                         |                                                                                                                                                                               |
| Key                   | AXButton              | `f minor`                                         |                                                                                                                                                                               |
| BPM                   | AXButton/AXStaticText | `126.0`                                           | Value-as-label pattern                                                                                                                                                        |
| BPM %                 | AXButton/AXStaticText | `0.0%`, `+7.3%`                                   | Value-as-label pattern                                                                                                                                                        |
| Elapsed time          | AXButton/AXStaticText | `01:35`                                           | Availability depends on view (confirmed, see [Time availability section](#time-availability))                                                                                 |
| Remaining time        | AXButton/AXStaticText | `-05:05`                                          | Availability depends on view (confirmed, see [Time availability section](#time-availability))                                                                                 |
| Play / Pause          | AXButton              | `Active` / nil                                    | `Active` = playing                                                                                                                                                            |
| Key Lock on-off       | AXButton              | `Active` / nil                                    |                                                                                                                                                                               |
| Quantize              | AXButton              | `Active` / nil                                    |                                                                                                                                                                               |
| Loop                  | AXButton              | `4 Beats`                                         | Current loop size                                                                                                                                                             |
| DVS                   | AXButton              | `INT`                                             |                                                                                                                                                                               |
| Skip Forward/Backward | AXButton              | `16 Beats`                                        | Current skip size (not confirmed, but this may depend on whether the beat jump buttons are shown — the buttons configurable next to the crossfader in non-hardware mode view) |
| Tempo                 | AXSlider              | `0%`                                              | Slider position, not BPM                                                                                                                                                      |
| Filter                | AXSlider              | `50%`                                             |                                                                                                                                                                               |
| High / Mid / Low EQ   | AXSlider              | `50%`                                             |                                                                                                                                                                               |
| Gain                  | AXSlider              | `42%`                                             |                                                                                                                                                                               |
| Line volume           | AXSlider              | `100%`                                            |                                                                                                                                                                               |
| FX Parameter          | AXSlider              | `80%`                                             | Per FX slot (1-3)                                                                                                                                                             |
| FX Wet/dry            | AXSlider              | `100%`                                            | Per FX slot (1-3)                                                                                                                                                             |
| FX Parameter name     | AXStaticText          | `0 BEAT`                                          | Per FX slot (1-3)                                                                                                                                                             |

### Action-Only Buttons (WIP)

These AXButton elements had no value in our test dumps, but some may expose state (e.g. `Active`) when engaged — needs further testing. For triggering actions, MIDI mapping is recommended.

Sync, CUE, Set start point, Jump to start point, Loop Half, Loop Double, Pitch Bend +/-, Key shift, Mute until cue, Precue, EQ Type, Edit grid, Waveform options, Neural Mix Solo (all channels), Instant FX, Instrumental, Percussive, Acapella, Tonal, FX Enable/Sidechain/Riser/Time Travel, Slice options, Slice repeat, Pitch Cue, Cue Points, Cuepoint Range, Looping, Shows quantize options.

### Other (not per-deck)

| Element        | Role     | Example Value |
| -------------- | -------- | ------------- |
| Crossfader     | AXSlider | `50%`         |
| External Mixer | AXButton | —             |

## License

MIT
