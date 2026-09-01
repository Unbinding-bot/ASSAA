# ASSAA User Guide

**Acoustic Search & Seismic Array Analysis — App UI Reference**

This guide covers every screen in the ASSAA mobile app: what each control does,
what the readouts mean, and how to use each tab effectively in the field.

---

## Table of Contents

1. [App-Wide Controls](#app-wide-controls)
2. [Map Tab](#map-tab)
3. [Navigate Tab](#navigate-tab)
4. [Nodes Tab](#nodes-tab)
5. [Console Tab](#console-tab)
6. [Showcase Tab *(diagnostics)*](#showcase-tab)
7. [Settings Tab](#settings-tab)

---

## App-Wide Controls

### Connection Bar

The thin bar sitting below the app title bar and above every screen is the
**Connection Bar**. It shows the live gateway link state — green when UDP audio
is streaming, amber when the gateway is reachable but not yet streaming, red
when there is no connection. Tap it to manually attempt a reconnect.

### Waypoints button (flag icon, top-right)

Accessible from any tab. Opens the **Waypoints sheet** (described in full under
the Map tab). Useful when you are on the Navigate or Nodes tab and want to
quickly add or check a flag without switching screens.

---

## Map Tab

The Map tab is the primary operational view. It shows a live 3-D acoustic map
of the area under survey, updated in real time as sensor events arrive.

---

### The 3-D Canvas

The main panel is a custom OpenGL-style voxel renderer drawn with Flutter's
`CustomPainter`. Every cell in the volumetric grid is coloured by its
classification state (solid concrete, void, unknown, or survivor signal).

#### Rotating and zooming

| Gesture | Action |
|---|---|
| **One-finger drag** | Orbit the camera (yaw + pitch) |
| **Pinch** | Zoom in / out |

The camera orbits around the centre of the sensor array. There is no panning —
everything stays centred on the grid origin so you always know where North is.

#### 2-D / 3-D toggle (top-right, first button)

Tap the **cube / map icon** to switch between:

- **3-D perspective view** — default, shows depth (z-axis). Best for reading
  void depth and survivor position in rubble.
- **Top-down 2-D view** — flattens to a plan view. Best for communicating
  positions to other responders using a grid reference.

#### Reset Camera (top-right, second button)

Snaps yaw, pitch, and zoom back to the default overview position
(yaw 0.6 rad, pitch 0.35 rad, zoom 1×). Use this any time the view gets
disorienting after free-hand orbiting.

---

### Layers

The **layer chip bar** floats at the bottom of the canvas. Each chip is a
toggle. Active layers are highlighted; inactive ones are dimmed. Tap any chip
to turn that layer on or off without leaving the tab.

| Layer | Icon | What it shows |
|---|---|---|
| **Nodes** | Sensors icon | Sensor node positions as labelled dots in 3-D space. Always useful — leave this on. |
| **Ripples** | Circle / radio icon | Animated ripple rings that emanate from each new acoustic fix. Colour encodes the dominant frequency of the detected event (see Frequency Palette in Settings). Red = high-frequency impact; yellow = low-frequency structural knock; green = ambiguous mid-range. |
| **Heatmap** | Grid icon | Volumetric voxel heatmap. Each voxel's colour shows the NDT classification: green = solid, red = void, grey = unknown. Intensity encodes confidence (bright = high confidence). |
| **Flags** | Flag icon | Placed waypoints overlaid on the 3-D scene. Each flag renders as a coloured pin with its label. Nav-target flags pulse to distinguish them. |
| **Vectors** | Compass icon | Guidance arrows pointing from the rescuer's estimated position toward the active navigation target. Only visible when a fix and a nav target are both set. |

The **Config** shortcut at the right end of the chip bar opens Settings directly.

---

### NDT Result Panel (top-left overlay)

When a Mode 1 active seismic tap cycle completes, an **NDT panel** appears in
the top-left corner of the canvas. It stays until the next result arrives.

**What it shows:**

- **Classification label** — SOLID, VOID, or UNKNOWN, with a matching icon
  (check, cross, question mark) and colour (green, red, grey).
- **Confidence percentage** — how certain the model is. Below 60 % the label
  always shows UNKNOWN regardless of the raw prediction.
- **Triangle: nodes X, Y, Z** — which three sensor nodes formed the active
  triangle for this tap cycle.
- **Probability bars** — three mini bars showing Solid / Void / Unknown
  probabilities side by side. Lets you see at a glance how close the decision
  was (e.g. 55 % Void vs 40 % Solid is a borderline result even if it labels
  VOID).
- **"Re-test recommended"** — appears in amber when the label is UNKNOWN.
  Move the impactor or reposition a listener and run another cycle.

---

### Ripple Colour Meaning

Ripples encode the **dominant frequency** of the detected acoustic event,
mapped through the Frequency Palette (configurable in Settings):

| Colour | Frequency range | Typical source |
|---|---|---|
| Red / orange | 3 000 – 10 000 Hz | Hard impact, metal-on-concrete knock |
| Amber / yellow | 500 – 1 500 Hz | Structural knock, survivor tapping |
| Green | 1 500 – 3 000 Hz | Mid-range, ambiguous or mixed path |
| Custom | User-defined | Any band you add in the palette editor |

When the NDT model is active, the ripple frequency is derived from the
classification result rather than raw FFT:
- SOLID → 5 000 Hz (red)
- VOID → 300 Hz (yellow)
- UNKNOWN → 1 500 Hz (green)

---

### Depth Slicer

The **Depth Slicer** is the range slider at the very bottom of the Map tab,
below the canvas. It controls which z-depth range is rendered in the heatmap
and nodes layers.

- Default range: **-2.5 m to +2.5 m** (full depth)
- Drag the **left handle** inward to clip the bottom (underground layers)
- Drag the **right handle** inward to clip the top (above-surface layers)

**Practical use:** In multi-storey collapse scenarios, slice to a single floor's
depth to isolate survivor signals from that level without the signals from other
floors visually interfering.

---

### Placing Flags (Waypoints)

Flags mark positions of interest — a known void, a confirmed survivor location,
a no-dig zone, a team staging area.

**To place a flag directly on the map:**

1. Tap the **place-flag button** (top-right, third button — pin with a `+`).
   A bright accent banner reading **TAP MAP TO PLACE FLAG** appears at the top.
2. Tap anywhere on the canvas. The app projects your tap through the current
   camera perspective and places the flag at that 2-D position, z = 0.
3. The placement mode cancels automatically after one tap. To cancel without
   placing, tap the button again (it becomes a solid pin icon while active).

**Adjusting flags:** Open the Waypoints sheet (flag icon, top-right of the app
bar) to rename, recolour, delete, or set a flag as the navigation target.

---

### Waypoints Sheet

Tap the **flag icon** in the app bar (top-right, any tab) to open the Waypoints
bottom sheet.

Each waypoint row is an **expansion tile**. Tap a row to expand it.

Collapsed row shows:
- Coloured pin icon (pulses if set as nav target)
- Label and (x, y, z) position in metres
- Eye icon — toggle map visibility
- Navigate icon — set as nav target for the Navigate tab

Expanded row shows:
- **Rename field** — tap to edit the label in-line
- **Checklist items** — for multi-step tasks (e.g. "acoustic confirmed",
  "physical probe done", "extraction started"). Tick items as work progresses.
- **Delete** — removes the flag permanently

**Add flag at origin:** The `+` button in the sheet header drops a new flag at
(0, 0, 0) which you can then drag or rename. Alternatively, place it directly
on the map canvas as described above.

---

## Navigate Tab

The Navigate tab provides a **compass-style bearing display** that points a
rescuer toward the active acoustic fix (or a manually set waypoint target).
It is designed to be glanceable at arm's length with dirty gloves on.

---

### Status Bar

Three chips across the top:

| Chip | Meaning |
|---|---|
| **FIX** | Confidence of the most recent TDOA localization fix. Green ≥ 60 %, amber 30–60 %, red < 30 %, dash if no fix yet. |
| **RESCUER** | Estimated accuracy radius of the rescuer's own position (from the device GPS or manual placement). Shown as `±X.X m`. Dash if not set. |
| **DIST** | Straight-line distance from the rescuer to the active fix or nav target, in metres. |

---

### Bearing Display

The large central area shows:

- **Distance** in metres — large 48 pt font, easy to read at a glance
- **Cardinal label** — N, NE, E, SE, S, SW, W, NW toward the target
- **Compass rose** — animated circle with N tick marks and a direction arrow
  pointing toward the target. The arrow is drawn in the app accent colour and
  pulses gently to confirm it is live.
- **Relative bearing** (degrees) — angle relative to the direction the rescuer
  is currently facing
- **Absolute bearing** (degrees from North) — compass heading to walk

**When there is no fix:** The compass area shows a placeholder with instructions
("Waiting for acoustic fix…" or "No nodes connected"). The placeholder explains
what is missing so you know whether to wait or take action.

---

### Heading Input

A slider at the bottom of the screen sets **your current compass heading**
(0°–360° from North). This is used to compute the *relative* bearing shown in
the compass rose — i.e., "turn left 23°" rather than "face 147°".

Set it to match the bearing shown on a physical compass (or phone compass app)
before you start moving. The label reads the current value in degrees.

> **Note:** Once a magnetometer plugin is wired up, this will be filled
> automatically. For now, set it manually before navigating.

---

## Nodes Tab

The Nodes tab lists every ESP32-C3 node the app is aware of — both the gateway
and all sensor nodes. It updates live as nodes come online or go stale.

---

### Node Card

Each node is shown as a card with:

| Element | Meaning |
|---|---|
| **Green / grey dot** | Green = recently heard from (not stale). Grey = no packet received in the last few seconds — node may be out of range or powered off. |
| **Node ID** | Integer node identifier, assigned in firmware. |
| **Role badge** | GATEWAY (accent colour), TAPPER (amber), or LISTENER (white/grey). |
| **Position** | (x, y, z) in metres relative to the array origin. Set during deployment calibration. |
| **Battery %** | Last reported battery level. Refresh rate depends on the firmware heartbeat interval (default 5 s). |
| **RSSI** | Received signal strength in dBm. Closer to 0 = stronger. Below -80 dBm signal is marginal; below -90 dBm packets will start dropping. |

---

### Reading the Role Badges

- **GATEWAY** — the single node connected via Wi-Fi SoftAP to the mobile app.
  It aggregates all sensor data and forwards it over UDP. There is exactly one
  gateway in a deployment.
- **TAPPER** — a node with a servo-driven mechanical impactor (Mode 1 active
  seismic). Fires on command from the app. Up to 3 tappers can be in the array.
- **LISTENER** — a passive piezo node that only receives and streams audio.
  Most nodes in a deployment are listeners.

---

### Stale Nodes

A node goes **stale** when no heartbeat or data packet has been received within
the timeout window (default ~3 s). The status dot turns grey. Possible causes:

- Node powered off or battery dead
- Node physically moved out of ESP-NOW range (> ~200 m open air, much less
  through rubble)
- Gateway congestion (too many nodes, packet collisions)

A stale node still appears in the list. It disappears only after an explicit
disconnect or app restart.

---

## Console Tab

The Console tab is a **live event log** — a scrolling monospace feed of every
tagged message the app emits internally. It is primarily a diagnostic tool for
developers and technically-trained operators.

---

### Reading Log Lines

Lines follow the format:

```
[HH:MM:SS.mmm] [TAG] message text
```

Common tags:

| Tag | Source |
|---|---|
| `udp` | UDP audio receiver — packet counts, node ID, sample rate |
| `dsp` | DSP pipeline — filter applied, ToF measurements |
| `tdoa` | TDOA solver — Chan estimate, LM iterations, final fix |
| `ndt` | NDT classifier — feature values, ONNX output, confidence |
| `ml` | ML model manager — load success, fallback to heuristic |
| `nav` | Navigation vector — bearing and distance updates |
| `node` | Node registry — connects, disconnects, role changes |

---

### Practical Use

- **Verify the ONNX model loaded:** Look for a line containing
  `"Loaded ONNX NDT model (26-feature, 95 % tuned)"` shortly after startup.
  If you see `"Falling back to heuristic NDT model"` instead, the `.onnx` file
  is missing from `assets/models/`.
- **Check ToF values:** After a tap cycle, the `dsp` lines show the measured
  time-of-flight per path (e.g. `tof=4.23 ms`). Compare against expected
  values for the baseline distance and known wave speed to verify sensor
  placement.
- **Diagnose low confidence:** If NDT results keep returning UNKNOWN, the
  `ndt` lines show the raw probability vector. If Solid and Void are nearly
  equal (e.g. 0.45 / 0.48), the signal is genuinely ambiguous — reposition a
  node or rerun the tap cycle. If all three probabilities are near 0.33, the
  model received bad features (check the `dsp` lines for NaN or zero ToF).
- **TDOA fix quality:** The `tdoa` lines show the LM residual after convergence.
  A residual < 0.01 m is excellent. A residual > 0.1 m means at least one TDOA
  measurement was an outlier (possible multipath reflection — check the Console
  for which sensor pair had the largest error).

The log is not persisted across app restarts. If you need to keep a record,
screenshot the console or use `adb logcat` with the `ASSAA` tag filter.

---

## Showcase Tab

The Showcase tab is a **live signal diagnostics panel**. It is hidden by default
and must be enabled in Settings → Diagnostics → Showcase & Diagnostics tab.
Once enabled it appears between the Console and Settings tabs in the nav bar.

This tab is aimed at operators who need to inspect raw waveforms, verify filter
settings, or manually trigger triangulation on a specific time window.

---

### Summary Bar

The header bar at the top of the tab contains:

**Mode selector — three chips:**

| Mode | What it shows |
|---|---|
| **All Nodes** | Micro-preview cards for every connected sensor node (up to 3). |
| **Average** | A single averaged waveform across all nodes, plus the combined dB level. |
| **Summary** | A general system-health overview (SNR, packet rate, fix history). |

**Stats row:**

- **Avg Peak** — average peak dB level across all nodes. Refreshes on every
  frame. -96 dB = silence; 0 dB = full scale clipping.
- **System SNR** — estimated signal-to-noise ratio (~24 dB is the system design
  target; below ~10 dB triangulation accuracy degrades significantly).

---

### Node Cards (Micro-Preview Grid)

Up to three node cards are shown in a row. Each card displays:

| Element | Meaning |
|---|---|
| **Node ID** | Integer node ID |
| **GPIO pin** | Which ADC channel this node's piezo is on |
| **dB meter** | Colour-coded bar: green = quiet, amber = moderate, red = near clipping |
| **dB value** | Exact RMS level in dBFS |
| **Mini waveform** | The most recently received audio frame, rendered as a thin waveform trace |

**Tap a card** to expand it into the full inspector below. Tap again to
collapse. Only one card can be expanded at a time.

When a card is expanded its border highlights in the accent colour and the
waveform trace turns bright.

---

### Expanded Inspector

Tapping a node card reveals the **Expanded Inspector** panel below the grid.

#### Session Scrubber

A timeline slider spanning the full ring-buffer history for the selected node
(up to ~200 frames, approximately 2 seconds at 10 kHz). Drag left to scrub
back in time; drag right to return to live (rightmost position).

The **waveform view** below the scrubber updates in real time to show the frame
at the current scrub position. This lets you review a transient event that
already passed — for example, to verify that the ToF onset is where the DSP
pipeline detected it.

The elapsed time counter (`MM:SS`) in the top-right of the inspector header
shows how long this session has been running.

#### STFT Spectrogram

A **Short-Time Fourier Transform spectrogram** rendered as a heat map:
- **X-axis** — time (left = oldest, right = most recent), up to 64 time slices
- **Y-axis** — frequency (bottom = 0 Hz, top = 5 kHz)
- **Colour intensity** — energy in that time-frequency bin. Bins inside the
  active bandpass are shown in the accent colour; bins outside are dimmed.

Use the spectrogram to:
- See whether a transient event has energy in the right frequency range for
  concrete stress waves (500 Hz – 4 kHz)
- Identify narrowband interference (a horizontal stripe at a fixed frequency
  = electrical noise from a motor, pump, or generator nearby)
- Verify that the bandpass filter is cutting out the noise band before it
  reaches the TDOA solver

#### Bandpass Slider

Below the spectrogram, a **range slider** adjusts the active bandpass window
(20 Hz – 10 kHz). The label above it reads the current passband in Hz.

- Drag the **left handle** to raise the low-cut frequency (remove low-frequency
  rumble, machinery vibration, or seismic noise)
- Drag the **right handle** to lower the high-cut frequency (remove electrical
  noise or ADC aliasing artefacts above the signal band)

The spectrogram updates immediately — in-band bins brighten, out-of-band bins
dim — giving you visual feedback as you adjust.

**Changes here apply only to this diagnostic session.** To make a bandpass
change permanent (affecting actual TDOA and NDT processing), update the filter
profile in Settings → Triangulation DSP.

#### Action Buttons

Three buttons sit at the bottom of the inspector:

| Button | Action |
|---|---|
| **Reset Filter** | Restores bandpass to the default 100 Hz – 5 000 Hz window. |
| **Auto-Latch Spikes** | Scans the ring buffer and jumps the scrubber to the frame with the highest RMS energy. Use this to quickly find the loudest event in the buffer (e.g., a tap onset or a survivor knock) without scrubbing manually. |
| **Triangulate Crop** | Runs the full Chan → Levenberg-Marquardt TDOA solver on the frame cluster at the current scrub position. The result (estimated source position + confidence) is shown in a snackbar at the bottom of the screen. Requires ≥ 3 sensor nodes. |

---

## Settings Tab

The Settings tab is divided into four sections.

---

### Appearance

#### Colour Mode

A light/dark toggle. Flips between the light and dark variant of the currently
selected theme. Both variants use the same accent palette — dark mode reduces
background brightness and dims secondary text.

#### Theme

A 2×2 grid of theme cards. Tap any card to apply that theme immediately (no
restart needed). Each card shows three colour swatches (accent, red, green) so
you can preview the palette before selecting.

Available themes:

| Theme | Character |
|---|---|
| **Tactical** | Deep navy with teal accent — high contrast for outdoor daylight use |
| **Ember** | Dark charcoal with orange accent — warm, low-glare for night operations |
| **Arctic** | White/light-grey with cyan accent — clinic/indoor environments |
| **Void** | Near-black with violet accent — minimal glare in complete darkness |

---

### Diagnostics

#### Showcase & Diagnostics Tab

Toggle switch. When on, adds the **Showcase** tab to the navigation bar between
Console and Settings. When turned off mid-session the nav bar shrinks back and
the selected tab clamps to the nearest valid index automatically.

Turn this off before handing the device to non-technical personnel — it removes
the diagnostics tab that could be confusing in an operational context.

---

### Triangulation DSP

The **Frequency Palette Editor** controls how acoustic events are coloured on
the map. Each palette entry is a **frequency band** — a named Hz range with an
associated colour. When a TDOA fix arrives, the dominant frequency of the event
is matched against these bands to determine the ripple colour on the map.

#### Band Tiles

Each band tile shows:
- **Colour swatch** (circle) — tap to open the colour picker (12 preset colours)
- **Band name** — the label shown in tooltips and legends
- **Hz range** — the frequency window this band covers
- **Edit button** (tune icon) — opens a dialog to change the label and Hz range
- **Delete button** (bin icon) — removes the band from the palette

#### Adding a Band

Tap **ADD BAND** to create a new custom band starting at 200–1000 Hz with a
purple swatch. Edit name and range immediately after.

#### Revert

Tap **REVERT** to restore the factory default palette (Low / Mid / High / VHF
bands matching the NDT filter profiles).

**Practical use:** In a deployment near heavy machinery generating 60 Hz
electrical hum, add a band for 50–150 Hz and colour it grey. Events in that
band will render grey on the map, immediately distinguishing interference from
genuine structural or survivor signals.

---

### About

Displays the app version, build date, and a one-line description.

### Data

**Reset** — clears all persisted settings (theme, waypoints, frequency palette,
wave speed calibration) and restores factory defaults. A confirmation dialog
appears before anything is deleted. Use this at the start of a new deployment
site so you are not carrying calibration data from the previous site.

---

## Quick Reference — Tab Summary

| Tab | Nav icon | Primary purpose |
|---|---|---|
| **Map** | Map | 3-D acoustic map, NDT results, ripples, waypoints, depth slicer |
| **Navigate** | Compass | Bearing + distance arrow pointing toward the active fix or waypoint |
| **Nodes** | Sensor | Connected node list with battery, RSSI, role, and position |
| **Console** | Terminal | Live tagged event log for diagnostics |
| **Showcase** | Analytics | Raw waveform cards, STFT spectrogram, bandpass editor, manual triangulation |
| **Settings** | Gear | Theme, diagnostics toggle, frequency palette, data reset |

---

*Last updated: August 2026 — ASSAA v0.1.0*
