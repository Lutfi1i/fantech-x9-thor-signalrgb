/*
 * SignalRGB device plugin for the Fantech X9 Thor / SONiX gaming mouse
 * (USB 18F8:0FC0, product string "USB GAMING MOUSE ").
 *
 * PROTOCOL SOURCE
 *   Recovered from the open-source Linux driver by GuessWhatBBQ:
 *   https://github.com/GuessWhatBBQ/FantechX9ThorDriver  (driver_backend.py)
 *
 *   That driver targets 18F8:1086; this mouse enumerates as 18F8:0FC0, but the
 *   protocol was verified working on this unit: the vendor collection exposes a
 *   HID *feature* report of exactly 8 bytes (report ID 0x07) and all 8-byte
 *   packets below are accepted.
 *
 * TRANSPORT
 *   USB control transfer: bmRequestType=0x21  bRequest=0x09 (SET_REPORT)
 *                         wValue=0x0307 (Feature, report ID 7)  wIndex=0x0001
 *   Every payload is 8 bytes and begins with 0x07 (the report ID).
 *
 * INSTRUCTIONS
 *   0x14  colour of one of the 6 onboard profiles
 *   0x13  lighting effect mode + which colours the cyclic effect uses
 *   0x11  scroll wheel function (volume)
 *   0x09  DPI for one profile
 *
 * COLOUR ENCODING
 *   4 bit per channel and INVERTED:  internal = floor((255 - value) / 16)
 *   packet: [0x07, 0x14, (profile-1)*2*16 + green, red*16 + blue, activeMask, 0,0,0]
 *
 * LIMITATION - READ THIS
 *   The hardware stores ONE colour for the whole mouse (per profile); there is
 *   no per-zone or per-LED addressing in this protocol. Canvas effects are
 *   therefore reduced to the colour at the single LED position below, and the
 *   colour is quantised to 16 levels per channel by the device.
 *
 *   These packets are configuration writes. They are rate limited and only sent
 *   when the colour actually changes, to avoid hammering the mouse's onboard
 *   configuration memory. Use the "Update Rate" setting if you want to trade
 *   smoothness for fewer onboard writes.
 */

export function Name() { return "Fantech X9 Thor"; }
export function Version() { return "1.0.0"; }
export function VendorId() { return 0x18F8; }
// NOTE: the custom-plugin loader wants a plain number here (it does not resolve
// Object.keys() arrays the way the bundled CDN plugins do). This unit reports
// 0x0FC0. The Fantech-branded variant of this mouse uses 0x1086 instead - if you
// plug that one in, add a second plugin file returning 0x1086.
export function ProductId() { return 0x0FC0; }
export function Publisher() { return "Reverse engineered (community)"; }
export function Documentation() { return "troubleshooting"; }
export function Size() { return [1, 1]; }
export function DeviceType() { return "mouse"; }
export function ImageUrl() { return "https://assets.signalrgb.com/devices/default/misc/usb-drive-render.png"; }

/* global
shutdownColor:readonly
LightingMode:readonly
forcedColor:readonly
updateRate:readonly
*/

// Only the vendor collection of interface 1 carries the 8-byte feature report.
export function Validate(endpoint) {
	return endpoint.interface === 1 && endpoint.usage === 0x0001 && endpoint.usage_page === 0xFF01;
}

export function ControllableParameters() {
	return [
		{"property":"shutdownColor", "group":"lighting", "label":"Shutdown Color", "description":"Colour applied when SignalRGB or the system shuts down", "min":"0", "max":"360", "type":"color", "default":"#000000"},
		{"property":"LightingMode", "group":"lighting", "label":"Lighting Mode", "description":"Canvas follows the active effect; Forced always uses one colour", "type":"combobox", "values":["Canvas", "Forced"], "default":"Canvas"},
		{"property":"forcedColor", "group":"lighting", "label":"Forced Color", "description":"Colour used when Lighting Mode is Forced", "min":"0", "max":"360", "type":"color", "default":"#009bde"},
		{"property":"updateRate", "group":"lighting", "label":"Update Rate", "description":"How often the mouse's onboard configuration is rewritten. Lower is gentler on the mouse's memory.", "type":"combobox", "values":["Eco (2 per second)", "Balanced (5 per second)", "Fast (10 per second)"], "default":"Balanced (5 per second)"}
	];
}

export function Initialize() {
	X9.InitializeX9();
}

export function Render() {
	X9.sendColors();
}

export function Shutdown(SystemSuspending) {
	X9.sendColors(SystemSuspending ? "#000000" : shutdownColor, true);
}

class X9_Thor_Protocol {
	constructor() {
		this.Config = {
			DeviceProductID: 0x0000,
			DeviceName: "Fantech X9 Thor",
			LedNames: ["LED"],
			LedPositions: [[0, 0]],
			Leds: [0]
		};

		// rate limiting / change detection state
		this.lastKey = -1;
		this.lastWrite = 0;
		this.rateMs = 200;
		this.transport = null;
	}

	getDeviceProductId() { return this.Config.DeviceProductID; }
	setDeviceProductId(v) { this.Config.DeviceProductID = v; }
	getDeviceName() { return this.Config.DeviceName; }
	setDeviceName(v) { this.Config.DeviceName = v; }
	getLedNames() { return this.Config.LedNames; }
	getLedPositions() { return this.Config.LedPositions; }

	// ---------------------------------------------------------------- packets

	// ------------------------------------------------------------------ output
	//
	// SignalRGB exposes several ways to push bytes at a vendor collection, and
	// they do NOT all reach the same Windows driver path:
	//
	//   control_transfer -> goes through libusb (winusbx_* in the engine). On
	//       Windows libusb can only talk to a collection bound to WinUSB; ours is
	//       bound to the HID class driver (hidusb), so the call can be accepted
	//       and still deliver nothing.
	//   send_report / write -> go through the engine's HID path (_hid_set_report),
	//       which is the path that was verified working on this mouse from an
	//       external tool (HidD_SetFeature, feature report ID 7, 8 bytes).
	//
	// So we probe once at startup and remember the first API the engine accepts.
	probeTransport(payload) {
		const attempts = [
			["send_report", () => device.send_report(payload, payload.length)],
			["write", () => device.write(payload, payload.length)],
			["control_transfer", () => device.control_transfer(0x21, 0x09, 0x0307, 0x0001, payload, payload.length, 1000)]
		];

		for (const pair of attempts) {
			try {
				pair[1]();
				console.log("X9: transport accepted -> " + pair[0]);
				return pair[0];
			} catch (err) {
				console.log("X9: transport rejected -> " + pair[0] + " : " + err);
			}
		}
		return "none";
	}

	sendPacket(payload) {
		try {
			if (this.transport === "send_report") {
				device.send_report(payload, payload.length);
			} else if (this.transport === "write") {
				device.write(payload, payload.length);
			} else if (this.transport === "control_transfer") {
				device.control_transfer(0x21, 0x09, 0x0307, 0x0001, payload, payload.length, 1000);
			}
		} catch (err) {
			console.log("X9: send failed on " + this.transport + " -> " + err);
		}
	}

	// Surface the chosen transport in the SignalRGB UI, since plugin console
	// output does not reach the SignalRGB log file.
	showStatus(text) {
		try { device.addMessage(text); } catch (err) { /* cosmetic only */ }
		console.log("X9: " + text);
	}

	// instruction 0x13 - lighting effect. 0x86 = static, 0x87 = off.
	setStaticMode() {
		this.sendPacket([0x07, 0x13, 0x7F, 0x86, 0x00, 0x00, 0x00, 0x00]);
	}

	// instruction 0x14 - write one colour into all six onboard profiles, so
	// whichever profile is currently selected shows the colour we want.
	writeColor(red4, green4, blue4) {
		for (let profile = 1; profile <= 6; profile++) {
			const profileNibble = (profile - 1) * 2;
			const byte1 = (profileNibble * 16) + green4;   // profile | green
			const byte2 = (red4 * 16) + blue4;             // red | blue
			this.sendPacket([0x07, 0x14, byte1, byte2, 0x3F, 0x00, 0x00, 0x00]);
		}
	}

	// ------------------------------------------------------------------ setup

	InitializeX9() {
		this.setDeviceProductId(device.productId());
		this.setDeviceName(X9deviceLibrary.PIDLibrary[this.getDeviceProductId()] || "Fantech X9 Thor");

		const props = X9deviceLibrary.LEDLibrary[this.getDeviceName()];
		if (props) {
			this.Config.LedNames = props.LedNames;
			this.Config.LedPositions = props.LedPositions;
			this.Config.Leds = props.Leds;
			device.setSize(props.size);
			device.setImageFromUrl(props.image);
		}

		this.rateMs = X9_RATE_MS[updateRate] || 200;

		device.set_endpoint(1, 0x0001, 0xFF01, 0x0004);
		device.setName("Fantech " + this.getDeviceName());
		device.setControllableLeds(this.getLedNames(), this.getLedPositions());

		console.log("X9 Thor: device model found -> " + this.getDeviceName());

		// Find out which byte-pushing API actually reaches this collection, then
		// take the mouse out of its own animated effect so it stops fighting us.
		this.transport = this.probeTransport([0x07, 0x13, 0x7F, 0x86, 0x00, 0x00, 0x00, 0x00]);
		this.showStatus("X9 LED transport: " + this.transport);

		this.setStaticMode();
		this.lastKey = -1;
	}

	// ----------------------------------------------------------------- output

	sendColors(overrideColor, force) {
		let color;

		if (overrideColor) {
			color = hexToRgb(overrideColor);
		} else if (LightingMode === "Forced") {
			color = hexToRgb(forcedColor);
		} else {
			color = device.color(0, 0);
		}

		if (!color || color.length < 3) { return; }

		// The device takes 4 bit per channel, inverted.
		const red4 = Math.floor((255 - color[0]) / 16);
		const green4 = Math.floor((255 - color[1]) / 16);
		const blue4 = Math.floor((255 - color[2]) / 16);

		const key = (red4 << 8) | (green4 << 4) | blue4;

		if (!force) {
			if (key === this.lastKey) { return; }                 // no change
			const now = Date.now();
			if ((now - this.lastWrite) < this.rateMs) { return; }  // rate limit
			this.lastWrite = now;
		}

		this.lastKey = key;
		this.writeColor(red4, green4, blue4);
	}
}

export class deviceLibrary {
	constructor() {
		this.PIDLibrary = {
			0x0FC0: "X9 Thor",   // this unit ("USB GAMING MOUSE ")
			0x1086: "X9 Thor",   // PID used by the original open-source driver
		};

		this.LEDLibrary = {
			"X9 Thor": {
				size: [1, 1],
				LedNames: ["LED"],
				LedPositions: [[0, 0]],
				Leds: [0],
				image: "https://assets.signalrgb.com/devices/default/misc/usb-drive-render.png"
			},
		};
	}
}

const X9_RATE_MS = {
	"Eco (2 per second)": 500,
	"Balanced (5 per second)": 200,
	"Fast (10 per second)": 100
};

const X9deviceLibrary = new deviceLibrary();
const X9 = new X9_Thor_Protocol();

function hexToRgb(hex) {
	const result = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
	if (!result) { return [0, 0, 0]; }
	return [parseInt(result[1], 16), parseInt(result[2], 16), parseInt(result[3], 16)];
}
