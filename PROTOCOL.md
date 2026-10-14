# Fantech X9 Thor — LED protocol reference

Everything below was verified against real hardware (USB `18F8:0FC0`), not copied
from the vendor installer. Evidence is recorded at the end.

---

## 1. Device identity

| | |
|---|---|
| VID:PID | `18F8:0FC0` — SONiX vendor ID |
| Manufacturer string | `INSTANT` |
| Product string | `"USB GAMING MOUSE "` (note the trailing space) |
| Interfaces | `MI_00` = mouse, `MI_01` = composite (keyboard, consumer, two vendor collections, system control) |

The vendor installer (`Thor_X9_Software_*.exe`) is a packed InstallShield build whose
internal MSI is not extractable — the strings even say the setup was built with an
evaluation version that "does not support extraction of the internal MSI". It was not
needed and is not used by this project.

---

## 2. Which HID collection carries the LED protocol

`hid-inspect.ps1` reports the following for `MI_01`:

| Collection | Usage page / usage | Report lengths | Role |
|---|---|---|---|
| COL01 | `0x0001 / 0x0006` | 16-byte input | keyboard (NKRO) |
| COL02 | `0x000C / 0x0001` | 3-byte input | consumer control |
| COL03 | `0xFF00 / 0x0001` | 3-byte input | vendor (not the LED channel) |
| **COL04** | **`0xFF01 / 0x0001`** | **8-byte FEATURE, no output report** | **LED / configuration** |
| COL05 | `0x0001 / 0x0080` | 2-byte input | system control |

Two facts matter:

- `COL04` is a **feature-report-only** collection: `inLen=0`, `outLen=0`,
  `featureLen=8`. There is no output report to write to.
- `featureLen` (8) already includes the report-ID byte, so the usable payload is
  **7 data bytes** after the ID — which matches the 8-byte packets below exactly.

---

## 3. Transport

A HID `SET_REPORT` of type **Feature**, report ID `0x07`, on interface 1.

As a raw USB control transfer (this is what the Linux driver does, and what
`tools/x9-ctl.ps1` does through `HidD_SetFeature`):

```
bmRequestType = 0x21     host -> device, class, interface
bRequest      = 0x09     SET_REPORT
wValue        = 0x0307   report type 3 (Feature) << 8 | report ID 0x07
wIndex        = 0x0001   interface 1
wLength       = 8
data          = 8-byte packet
```

Every packet begins with `0x07`, the report ID.

---

## 4. Packet format

| Offset | Meaning |
|---|---|
| 0 | report ID — always `0x07` |
| 1 | instruction code |
| 2..7 | instruction payload (6 bytes) |

Instructions found in the reference driver:

| Code | Purpose | Payload |
|---|---|---|
| `0x14` | colour of one onboard profile | `[profileNibble<<4 \| green, red<<4 \| blue, activeMask, 0, 0, 0]` |
| `0x13` | lighting effect mode | `[cyclicMask, effect, 0, 0, 0, 0]` |
| `0x11` | scroll wheel function | `[0x01 = volume, else 0x00, 0, 0, 0, 0]` |
| `0x09` | DPI for one profile | `[0x40 - 1 + activeProfile, dpi<<4 \| profile+7, activeMask, 0, 0, 0]` |

Only `0x13` and `0x14` are used for LED control by this project; `0x11` and `0x09`
are documented for completeness and are **not** sent by the plugin.

### Effect byte (instruction `0x13`)

| Mode | Byte |
|---|---|
| Static | `0x86` |
| Off | `0x87` |
| Fixed | `0x86 - duration` |
| Cyclic | `0x96 - duration` |

`duration` is 1..6. `cyclicMask` selects which colours the cyclic effect uses, one
bit per colour: bit0 Yellow, bit1 Blue, bit2 Violet, bit3 Green, bit4 Red, bit5 Cyan,
bit6 White (`0x7F` = all).

---

## 5. Colour encoding

Per channel, **4 bits, inverted**:

```
internal = floor((255 - value) / 16)      // 0 = channel fully on, 15 = off
```

For profile `p` (1..6):

```
byte1 = ((p - 1) * 2) * 16 + internal_green      // profile nibble | green
byte2 = internal_red * 16 + internal_blue        // red | blue
```

Worked examples (all six profiles, `activeMask = 0x3F`):

| Colour | R/G/B internal | Profile 1 packet |
|---|---|---|
| Red `#FF0000` | 0 / 15 / 15 | `07 14 0F 0F 3F 00 00 00` |
| Green `#00FF00` | 15 / 0 / 15 | `07 14 00 FF 3F 00 00 00` |
| Blue `#0000FF` | 15 / 15 / 0 | `07 14 1F F0 3F 00 00 00` |
| White `#FFFFFF` | 0 / 0 / 0 | `07 14 00 00 3F 00 00 00` |
| Off `#000000` | 15 / 15 / 15 | `07 14 1F FF 3F 00 00 00` |

Claiming `#00FF00` produces `byte1 = 0x00` (green nibble 0 = green fully on) looks
inverted — that is correct, and it is the part that most easily trips an
implementation.

Settings written this way **persist** across replug; the mouse stores them.

---

## 6. Verification evidence

**Step 1 — the collection exists and is the right shape.** `hid-inspect.ps1`:

```
HID\VID_18F8&PID_0FC0&MI_01&COL04
  usagePage=0xFF01  usage=0x0001
  inLen=0  outLen=0  featureLen=8
  caps: featVal=1
```

An 8-byte feature report — exactly the size of the reference driver's packets.

**Step 2 — the protocol works on this unit.** Seven packets (six profile colours plus
the effect mode) were written with `HidD_SetFeature`:

```
hasil : 7 paket terkirim, 0 gagal
        mode payload = 07 13 7F 86 00 00 00 00
```

The mouse LED turned **red**, confirming the protocol applies to `18F8:0FC0` even
though the reference driver targets `18F8:1086`. The PID differs; the protocol does
not.

**Step 3 — the SignalRGB side.** The plugin loads, `Initialize()` runs, and the device
card takes the name set by the plugin (`Fantech X9 Thor`). Which SignalRGB API reaches
the feature report is the remaining open question — see below.

---

## 7. Open questions

- **Which SignalRGB API reaches a feature-only collection?** `device.control_transfer()`
  runs through libusb, which on Windows needs a WinUSB-bound interface; `COL04` is
  HID-bound, so the call can be accepted and deliver nothing. `device.send_report()`
  and `device.write()` use the engine's HID path and are the better candidates. The
  plugin probes all three at startup and reports the result in the UI.
- **The `0x1086` variant** is expected to behave identically, but that has not been
  tested.
- **Do these writes go to flash?** They persist across replug, which suggests
  non-volatile storage. That is why the plugin rate-limits writes and only sends on
  change. Treat the write count as a resource.

---

## Reference

Protocol originally documented in
[GuessWhatBBQ/FantechX9ThorDriver](https://github.com/GuessWhatBBQ/FantechX9ThorDriver)
(GPL-3.0), an open-source Linux driver targeting `18F8:1086`.
