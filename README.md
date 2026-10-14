# Fantech X9 Thor — SignalRGB plugin

Unofficial [SignalRGB](https://signalrgb.com) device plugin for the **Fantech X9 Thor**
RGB gaming mouse (USB `18F8:0FC0`, product string `"USB GAMING MOUSE "`), plus a
standalone PowerShell tool that drives the mouse LED without SignalRGB.

The mouse is a SONiX-based device and ships with a heavy Windows installer. This
project skips that installer entirely: the LED protocol was recovered from an
open-source Linux driver and then **verified on real hardware**.

---

## Status

| Item | State |
|---|---|
| LED protocol recovered | ✅ verified on hardware |
| Standalone LED control (no vendor software) | ✅ works |
| SignalRGB plugin loads and `Initialize()` runs | ✅ confirmed (device card shows `Fantech X9 Thor`) |
| SignalRGB LED sync | ⚠️ transport API under test — see [Troubleshooting](#troubleshooting) |

This is an honest status table. The protocol itself is proven; what is still being
pinned down is which SignalRGB plugin API actually reaches an 8-byte HID **feature**
report on a collection that has no output report.

---

## Install (SignalRGB)

1. Copy `Fantech_X9_Thor.js` into your SignalRGB user-plugin folder:

   ```
   %USERPROFILE%\Documents\WhirlwindFX\Plugins\
   ```

2. Restart SignalRGB completely (tray icon → Exit, then start again).

3. The mouse should appear as a device named **Fantech X9 Thor**.

That folder is not touched by SignalRGB updates, unlike the CDN plugin cache.

---

## Standalone tool

`tools/x9-ctl.ps1` talks to the mouse directly. Useful for testing the protocol and
for setting a colour without SignalRGB.

```powershell
# dry run: show the exact packets without sending anything
.\tools\x9-ctl.ps1 -ColorHex 00FF00 -Mode Static -DryRun

# set the LED to red, static (no animation)
.\tools\x9-ctl.ps1 -ColorHex FF0000 -Mode Static

# cycle through colours, changing every 2 units
.\tools\x9-ctl.ps1 -ColorHex 0000FF -Mode Cyclic -Duration 2

# turn the LED off
.\tools\x9-ctl.ps1 -Mode Off
```

`tools/hid-inspect.ps1` dumps the HID collections of the device — report lengths,
usages and the parsed report descriptor. Handy for checking which collection carries
the feature report:

```powershell
.\tools\hid-inspect.ps1 -Vid 18F8 -ProdId 0FC0
```

Both scripts need PowerShell 5.1+ (or PowerShell 7) and no external modules. They
write straight to the mouse's configuration memory, so the setting persists across
replugs.

---

## Protocol in one paragraph

Everything goes through **one HID feature report**: report ID `0x07`, **8 bytes**,
on the vendor collection of interface 1 (usage page `0xFF01`, usage `0x0001`). Each
packet starts with the report ID followed by an instruction byte:

```
[0x07, 0x14, profile|green, red|blue, activeMask, 0, 0, 0]   ← colour of one profile
[0x07, 0x13, cyclicMask, effect, 0, 0, 0, 0]                 ← lighting effect mode
```

Colour is **4 bits per channel and inverted** (`internal = (255 - value) / 16`).
Full details, including the other instructions and the verification evidence, are in
[PROTOCOL.md](PROTOCOL.md).

---

## Limitations

- **One colour for the whole mouse.** The protocol has no per-zone or per-LED
  addressing, so the logo and the scroll wheel cannot differ, and an effect canvas
  collapses to a single colour.
- **16 levels per channel.** Colour is quantised to 4 bits and inverted.
- **These are configuration writes**, not a streaming datastream. They appear to land
  in the mouse's onboard memory, so the plugin rate-limits them (default 5 per second)
  and only sends when the colour actually changes. Rapidly animated effects mean more
  onboard writes — use the `Update Rate` setting if you want to be gentler on it.
- Only tested on the `0FC0` variant. The Fantech-branded unit reports `0x1086`; the
  same protocol is expected but has not been verified.

---

## Troubleshooting

**The device card does not appear at all.**
Check that the file is in `Documents\WhirlwindFX\Plugins\`, then restart SignalRGB
fully. SignalRGB builds its plugin list at startup.

**The card appears but the LED never changes.**
SignalRGB offers several APIs for pushing bytes at a vendor collection, and they do
not all reach the same Windows driver path:

| API | Path | Works when |
|---|---|---|
| `device.send_report()` / `device.write()` | engine's HID path (`_hid_set_report`) | collection is HID-bound |
| `device.control_transfer()` | libusb (`winusbx_*`) | collection is bound to WinUSB |

`COL04` on this mouse is bound to the **HID class driver**, so `control_transfer`
can be accepted without an error and still deliver nothing. That is why the plugin
probes at startup and reports which API the engine accepted. Open the device's
settings in SignalRGB and look for a message like:

```
X9 LED transport: send_report
```

`send_report` is the expected result. If it says `write`, `control_transfer` or
`none`, please open an issue with that line — it is the single most useful
diagnostic.

Note that plugin `console.log()` output does **not** reach SignalRGB's log files,
which is why the transport is surfaced in the UI instead.

---

## How the protocol was recovered

1. The Windows vendor installer turned out to be a packed InstallShield build whose
   internal MSI could not be extracted, so it was set aside.
2. Searching by USB ID identified the device as a **Fantech X9 Thor** and surfaced an
   open-source Linux driver for it:
   [GuessWhatBBQ/FantechX9ThorDriver](https://github.com/GuessWhatBBQ/FantechX9ThorDriver).
3. The driver's packet layout was checked against the real device with
   `tools/hid-inspect.ps1`: the vendor collection exposes a HID feature report of
   **exactly 8 bytes** — matching the driver's 8-byte payloads precisely.
4. A first colour packet was sent with `HidD_SetFeature` and the mouse LED turned
   red, confirming the protocol on this exact unit even though the PID differs
   (`0FC0` here vs `1086` in the driver).

No vendor software is required, and nothing here was copied from the installer.

---

## Credits and licence

- Protocol originally documented by
  [GuessWhatBBQ/FantechX9ThorDriver](https://github.com/GuessWhatBBQ/FantechX9ThorDriver)
  (GPL-3.0). The colour quantisation and packet layout in this project derive from it,
  so this project is licensed **GPL-3.0** as well — see [LICENSE](LICENSE).
- Not affiliated with Fantech, SONiX or SignalRGB. Use at your own risk.

---

## Panduan singkat (Bahasa Indonesia)

1. Salin `Fantech_X9_Thor.js` ke `%USERPROFILE%\Documents\WhirlwindFX\Plugins\`.
2. Tutup SignalRGB sepenuhnya (ikon tray → Exit), lalu jalankan lagi.
3. Mouse akan muncul sebagai device **Fantech X9 Thor**.
4. Untuk tes tanpa SignalRGB: `.\tools\x9-ctl.ps1 -ColorHex FF0000 -Mode Static`.
5. Kalau LED tidak berubah, buka pengaturan device-nya dan laporkan baris
   `X9 LED transport: ...` yang muncul di sana.
