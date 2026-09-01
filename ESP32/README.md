# ASSAA — ESP32-C3 Super Mini Node Firmware

## Network topology

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  Phone (Flutter app)                                                │
  │    Wi-Fi STA  →  joins "AcousticArray_AP"                           │
  │    WebSocket  →  ws://192.168.4.1:81                                │
  └──────────────────────────┬──────────────────────────────────────────┘
                             │ WebSocket (commands ↓ / data ↑)
                    ┌────────▼────────┐
                    │    Node 0        │  IS_GATEWAY = 1
                    │    GATEWAY       │  SoftAP  192.168.4.1
                    │                  │  WebSocket server :81
                    │                  │  ESP-NOW relay hub
                    └────────┬─────────┘
           ┌─────────────────┼──────────────────┐
     ESP-NOW│           ESP-NOW│           ESP-NOW│
     (cmds/data)        (cmds/data)        (cmds/data)
    ┌───────▼──────┐  ┌───────▼──────┐  ┌───────▼──────┐
    │   Node 1     │  │   Node 2     │  │  Nodes 3–7   │
    │   SENSOR     │  │   SENSOR     │  │  SENSOR      │
    │ IS_GATEWAY=0 │  │ IS_GATEWAY=0 │  │ IS_GATEWAY=0 │
    └───────┬──────┘  └───────┬──────┘  └───────┬──────┘
            │                 │                  │
            └─────────────────┴──────────────────┘
              UDP :9000 — piezo frames → phone directly
                        (bypasses gateway)
```

### Why two separate paths?

- **ESP-NOW** carries commands (downlink) and structured data — tap_data,
  telemetry, FTM results (uplink). These are small JSON messages, so the
  gateway easily relays them over WebSocket to the phone.

- **UDP broadcast** carries the continuous piezo ADC stream in Mode 2.
  At 10 kHz × 100 samples/frame × 7 nodes that's ~700 packets/second total.
  Routing all of that through the gateway would overwhelm its WebSocket.
  Instead, sensor nodes UDP-broadcast directly to `255.255.255.255:9000`
  and the phone receives them directly since it's on the same AP subnet.
  The Flutter `UdpAudioReceiver` in `services/udp_audio_receiver.dart`
  handles this.

---

## File structure

```
ESP32/
├── assaa_node/
│   └── assaa_node.ino   Main sketch — IS_GATEWAY + NODE_ID flags
├── pins.h               GPIO assignments + ADC/sampling constants
├── wifi_setup.h         Shared: SSID/password, FTM ranging, RSSI fallback
├── esp_now_mesh.h       ESP-NOW init, chunked send/receive, peer management
├── gateway.h            Node 0: SoftAP + WebSocket + ESP-NOW relay
├── sensor_node.h        Nodes 1–7: STA + ESP-NOW + piezo streaming
├── piezo_adc.h          Piezo ADC driver — 10 kHz polling + UDP broadcast
├── mpu6050.h            MPU-6050 supplemental accel (Mode 1 only)
├── impactor.h           Servo tap-capture, piezo ISR, impactor/listener logic
└── README.md            This file
```

---

## Hardware

Every node uses identical hardware. Role is set in firmware, not hardware.

### Pin wiring

| GPIO | Component | Function |
|------|-----------|----------|
| 0 | SG90 servo | PWM signal |
| 1 | TL072 Ch A output | **Node A sensor** — ADC1_CH1, ISR trigger (spec §2.1) |
| 2 | TL072 Ch B output | **Node B sensor** — ADC1_CH2 |
| 3 | TL072 Ch C output | **Node C sensor** — ADC1_CH3 |
| 8 | MPU-6050 SDA | I²C data (400 kHz) — Mode 1 supplemental only |
| 9 | MPU-6050 SCL | I²C clock (400 kHz) — Mode 1 supplemental only |
| 10 | Status LED | Active HIGH |

All three piezo channels use **ADC1** — Wi-Fi remains fully active.
ADC2 is not used (blocked by Wi-Fi on ESP32-C3).

Each channel runs at ~30 kHz in a round-robin loop (aggregate ≈ 90 kHz, spec §1.2).

### Piezo signal chain

```
Piezo disc
  ├── 1 MΩ to GND           (load resistor)
  └──→ TL072 pin 3 (+in)
          ├── DC bias: resistor divider to 1.65 V  ← keeps signal in ADC midrange
          └──→ TL072 pin 1 (output)
                  ├── 3.3 V Zener to GND            ← MANDATORY over-voltage clamp
                  └──→ GPIO 1 (ADC1_CH1)
```

> **The Zener clamp is not optional.** Raw piezo spikes exceed 50 V on a
> hard strike and will destroy the ESP32 without it.

### Power

| Rail | Voltage | Consumers |
|------|---------|-----------|
| Main | 5 V | SG90 servo + LDO input |
| Sensor | 3.3 V (LDO) | TL072, MPU-6050 |

100 nF ceramic cap on 3.3 V LDO output to GND to isolate the analog rail
from servo PWM switching noise.

---

## Arduino IDE setup

1. **File → Preferences** → Additional boards manager URLs:
   ```
   https://raw.githubusercontent.com/espressif/arduino-esp32/gh-pages/package_esp32_index.json
   ```
2. **Boards Manager** → install **"esp32 by Espressif Systems" >= 2.0.14**
3. **Board** → `ESP32C3 Dev Module`
4. **Library Manager** → install:
   - `ESP32Servo` by Kevin Harrington
   - `WebSockets` by Markus Sattler

---

## Flashing

Edit the two lines at the top of `assaa_node.ino` before each flash:

```cpp
#define IS_GATEWAY  0   // 1 for the gateway board, 0 for all sensor boards
#define NODE_ID     1   // 0 = gateway, 1–7 = sensor nodes
```

### Flash order matters

1. **Flash and power on the gateway first** (IS_GATEWAY=1, NODE_ID=0).
   The gateway must have its SoftAP running before sensors try to connect.

2. **Flash sensor nodes** (IS_GATEWAY=0, NODE_ID=1…7) one at a time.
   Sensors block in `sensorNodeSetup()` waiting to join the AP — they
   will retry every 10 s, so you can power them up before the gateway
   if needed and they'll auto-connect once it appears.

---

## Boot sequence

### Gateway (Node 0)

1. Start SoftAP `AcousticArray_AP` on channel 6 → Wi-Fi channel locked
2. Init ESP-NOW on the same channel
3. Add broadcast peer (`ff:ff:ff:ff:ff:ff`)
4. Broadcast `{"type":"gateway_mac","mac":"XX:XX:..."}` so sensors learn
   the gateway's MAC for unicast uplink
5. Start WebSocket server on port 81
6. LED solid ON → gateway ready

### Sensor node (Nodes 1–7)

1. Connect to `AcousticArray_AP` as STA → channel locked to 6
2. Init ESP-NOW
3. Broadcast `{"type":"hello","node":N}` → gateway captures MAC, registers
   this sensor as a unicast peer
4. Receive `gateway_mac` reply → register gateway as unicast peer
5. LED blinks in Mode 2 → streaming

---

## Operating modes

All nodes start in **Mode 2** by default.

### Mode 2 — Passive acoustic triangulation

Each sensor polls the piezo ADC at **10 kHz**, packages 100 samples (10 ms)
into a binary `PiezoPacket`, and UDP-broadcasts it to `255.255.255.255:9000`.

The phone receives these as `AudioFrame`s, runs IIR bandpass filtering,
GCC-PHAT cross-correlation, and the Levenberg-Marquardt TDOA solver to
locate the acoustic source.

Switch command: `{"type":"SET_MODE_2"}`

### Mode 1 — Active NDT

Switch command: `{"type":"SET_MODE_1"}`

Trigger a tap:
```json
{"type":"TRIGGER_TAP","tapper":3}
```

**Node 3 (impactor):**
- Fires servo (GPIO 0)
- Piezo interrupt on GPIO 1 captures T0 with µs precision
- Records 500 piezo ADC samples @ 10 kHz (50 ms) — primary waveform
- Records 150 MPU-6050 Z samples @ 500 Hz (300 ms) — supplemental
- Sends `tap_data` via ESP-NOW → gateway → phone WebSocket

**All other nodes (listeners):**
- Arm from WS sync timestamp as T0
- Record 500 piezo ADC samples @ 10 kHz
- Send `tap_data` via ESP-NOW → gateway → phone WebSocket

Send `"tapper":5` next time and node 5 becomes the impactor. No reflashing.

---

## tap_data JSON

```json
{
  "type":     "tap_data",
  "node":     2,
  "tapper":   3,
  "piezo_t0": 1234567,
  "piezo":    [12, -45, 210, ...],
  "accel":    [0, 80, 220, ...]
}
```

| Field | Description |
|-------|-------------|
| `node` | ID of the node that sent this frame |
| `tapper` | ID of the node that fired the servo |
| `piezo_t0` | µs hardware timestamp. Impactor: piezo ISR time. Listener: WS sync arrival time |
| `piezo` | 500 × int16, 10 kHz, 50 ms window |
| `accel` | 150 × int16, 500 Hz, 300 ms. Impactor only — empty `[]` on listeners |

---

## ESP-NOW message framing

ESP-NOW has a 250-byte payload limit. Short messages (telemetry, FTM, commands)
fit in one packet. Large messages (tap_data ≈ 3–5 KB) are automatically split
into 220-byte chunks by `espnowSend()` in `esp_now_mesh.h` and reassembled by
the gateway's receive callback before forwarding to the phone.

---

## Wi-Fi / ESP-NOW channel

All nodes must use **channel 6**. This is set by `ESPNOW_CHANNEL` in
`esp_now_mesh.h`. The gateway's SoftAP runs on channel 6, and sensors
inherit it when they associate. Never change this without updating all nodes.

---

## Status LED guide

| Pattern | Meaning |
|---------|---------|
| Solid ON | Gateway up and running |
| 1 Hz blink | Sensor in Mode 2 (streaming) |
| Slow blink during boot | Sensor connecting to gateway AP |
| Solid ON (sensor) | Sensor in Mode 1 (NDT ready) |
| 3 quick blinks | Tap capture completed (impactor or listener) |
| 3-flash boot sequence | Successful boot on any node |
