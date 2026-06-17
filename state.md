# KORG nanoKEY Studio BLE reverse-engineering state

This file is the canonical handoff state for future LLM/agent sessions. Keep it updated after every meaningful discovery or implementation step.

## Goal

Make a KORG nanoKEY Studio work over Bluetooth on macOS/Apple Silicon despite the official KORG/Apple BLE-MIDI connection flow failing.

The user reports:

- The device connects on Windows.
- On macOS, both official paths fail:
  - Audio MIDI Setup -> MIDI Studio -> Bluetooth Configuration
  - KORG Bluetooth MIDI Connect app
- Community/forum reports suggest Apple Silicon/macOS compatibility problems.

We are doing diagnostics/reverse engineering, not just following the official instructions.

## Environment facts

- Workspace: `/Users/gufranov_a/src/korg`
- User's Mac from screenshot:
  - MacBook Pro 14-inch, November 2023
  - Apple M3 Pro
  - 36 GB RAM
  - macOS Sonoma 14.6
- Shell: `/bin/zsh`
- Node: `v24.15.0`
- npm: `11.12.1`
- Swift exists but local CommandLineTools Swift/SDK are mismatched and cannot build CoreBluetooth Swift code.
- Objective-C + clang CoreBluetooth build works.

## Repository files

- `scan-ble.js` — Node/noble BLE scanner. Confirms the device advertises BLE-MIDI service.
- `connect-midi.js` — Node/noble BLE-MIDI connector/parser attempt. Connects and discovers characteristic, but notifications do not deliver data.
- `dump-ble.js` — Node/noble low-level GATT dumper. Discovers services/characteristics and attempts read/notify.
- `dump-ble.m` — native Objective-C/CoreBluetooth dumper. This is currently the most trustworthy diagnostic tool.
- `dump-ble.swift` — Swift version attempted, but unusable until Swift/SDK toolchain mismatch is fixed.
- `package.json` scripts:
  - `npm run scan`
  - `npm run midi`
  - `npm run dump`
  - `npm run dump:objc`

## Important dependency warning

`@abandonware/noble` was installed and npm reported `7 high severity vulnerabilities`. It is acceptable for local diagnostics, but should not be treated as production-safe.

Also note: `node_modules` appears to be tracked by git in this repository. Do not casually remove it without user approval; it may be accidental legacy state.

## BLE scan results

`scan-ble.js` found `nanoKEY Studio`.

Observed advertisement:

```text
name: nanoKEY Studio
service UUIDs: 03b80e5aede84b33a7516ce34ec4c700
connectable: true
rssi: roughly -69 to -79 in tests
```

`03B80E5A-EDE8-4B33-A751-6CE34EC4C700` is the standard Bluetooth LE MIDI service UUID.

Conclusion: macOS/CoreBluetooth can see the device at BLE advertisement level. The problem is not radio visibility.

## GATT services/characteristics discovered on nanoKEY Studio

Native CoreBluetooth and noble both discovered:

```text
Services (3):
  180A                                      Device Information
  D0611E78-BBB4-4591-A5F8-487910AE4366     vendor/KORG-specific service
  03B80E5A-EDE8-4B33-A751-6CE34EC4C700     standard BLE-MIDI service
```

Characteristics:

```text
service 180A:
  2A29 properties=read     -> "Korg Inc."
  2A24 properties=read     -> "nanoKEY Studio"

service D0611E78-BBB4-4591-A5F8-487910AE4366:
  8667556C-9A37-4C91-84ED-54EE27D90049 properties=write,notify
  descriptor 2902 Client Characteristic Configuration

service 03B80E5A-EDE8-4B33-A751-6CE34EC4C700:
  7772E5DB-3868-4112-A1A9-F2669D106BF3 properties=read,writeWithoutResponse,notify
  descriptor 2902 Client Characteristic Configuration
```

The vendor service may be relevant for updater/proprietary setup, but the installed KORG Bluetooth MIDI Connect app does not appear to reference its UUID strings.

## Node/noble findings

`connect-midi.js` can:

- find `nanoKEY Studio`
- connect
- discover BLE-MIDI service
- discover BLE-MIDI characteristic `7772e5db38684112a1a9f2669d106bf3`
- subscribe without throwing

But noble reports notify state as `false` and no MIDI bytes arrive when keys/pads/knobs are used.

Polling reads on the MIDI characteristic produced empty buffers.

Conclusion: noble is not reliable enough here. It hides the real CoreBluetooth errors.

## Native CoreBluetooth findings

`npm run dump:objc` compiles and runs `dump-ble.m` via:

```bash
clang -fobjc-arc -framework Foundation -framework CoreBluetooth dump-ble.m -o /tmp/korg-dump-ble && /tmp/korg-dump-ble
```

The native dumper found the same services/characteristics and, critically, exposed real security errors:

```text
Notify failed D0611E78-BBB4-4591-A5F8-487910AE4366/8667556C-9A37-4C91-84ED-54EE27D90049:
Encryption is insufficient.

Value update failed for 7772E5DB-3868-4112-A1A9-F2669D106BF3:
Authentication is insufficient.

Notify failed 03B80E5A-EDE8-4B33-A751-6CE34EC4C700/7772E5DB-3868-4112-A1A9-F2669D106BF3:
Authentication is insufficient.
```

This is the key discovery so far.

Conclusion: the device requires an encrypted/authenticated BLE link before it will allow BLE-MIDI read/notify or vendor notify. The failure is at BLE security/pairing/bonding level, not at MIDI parsing level.

## KORG Bluetooth MIDI Connect app findings

Installed app path:

```text
/Applications/Bluetooth MIDI Connect.app
```

Bundle info:

```text
CFBundleIdentifier: jp.co.korg.KontrolBleMidiSupportTool
CFBundleShortVersionString: 1.0.1
CFBundleVersion: 11
LSMinimumSystemVersion: 11.0
NSBluetoothAlwaysUsageDescription: Used to connect Korg Bluetooth devices.
```

Binary:

```text
Mach-O universal binary: x86_64 + arm64
```

Linked frameworks:

```text
CoreBluetooth
CoreMIDI
CoreAudioKit
Foundation
Cocoa
CoreFoundation
AppKit
ServiceManagement
```

Strings/symbols show:

```text
CABTLEMIDIWindowController
BleMidiWatcher
CBCentralManager
03B80E5A-EDE8-4B33-A751-6CE34EC4C700
```

No obvious references to the vendor UUIDs:

```text
D0611E78-BBB4-4591-A5F8-487910AE4366
8667556C-9A37-4C91-84ED-54EE27D90049
```

Unified logs show KORG/CoreAudioKit behavior:

```text
(CoreAudioKit) Scanning for MIDI service 03B80E5A-EDE8-4B33-A751-6CE34EC4C700
(CoreAudioKit) Discovered a new MIDI peripheral: nanoKEY Studio (UUID: 4846897C-1A96-F808-B7C9-F087F6385C8E)
```

Conclusion: KORG Bluetooth MIDI Connect appears to be a thin wrapper around Apple CoreAudioKit's BLE-MIDI UI/stack, especially `CABTLEMIDIWindowController`. Reverse engineering the KORG app may not reveal a proprietary connection protocol. The failure likely occurs below it in Apple's CoreAudioKit/CoreBluetooth BLE-MIDI flow, or in device security compatibility with that flow.

## Hypotheses

### Most likely

The nanoKEY Studio requires encrypted/authenticated GATT access. On this macOS/Apple Silicon setup, the Apple BLE-MIDI/CoreBluetooth flow reaches protected characteristics but fails to initiate or complete pairing/bonding, returning `Authentication is insufficient` / `Encryption is insufficient` instead of successfully creating a secure link.

KORG's app fails because it delegates to the same Apple BLE-MIDI stack.

### Possible

The vendor-specific service requires a KORG handshake used by Windows driver or firmware updater, not by the macOS BLE-MIDI app. If Windows works, the Windows KORG BLE-MIDI driver may implement a workaround or security flow macOS lacks.

### Also possible

Firmware version matters. A KORG updater was observed in logs/paths (`nanoKEY Studio Updater 1.08.app`). The current device firmware version is not yet known.

## Useful commands

```bash
npm run scan
npm run midi
npm run dump
npm run dump:objc
```

Inspect KORG app:

```bash
plutil -p '/Applications/Bluetooth MIDI Connect.app/Contents/Info.plist'
file '/Applications/Bluetooth MIDI Connect.app/Contents/MacOS/'*
otool -L '/Applications/Bluetooth MIDI Connect.app/Contents/MacOS/Bluetooth MIDI Connect'
strings -a '/Applications/Bluetooth MIDI Connect.app/Contents/MacOS/Bluetooth MIDI Connect' | grep -Ei '03B80E5A|7772E5DB|D0611E78|8667556C|Bluetooth|MIDI|KORG|connect|notify|pair|auth|encrypt|CBPeripheral|CBCentral|CoreMIDI|CABTLEMIDI'
nm -m '/Applications/Bluetooth MIDI Connect.app/Contents/MacOS/Bluetooth MIDI Connect' | grep -Ei 'Bluetooth|MIDI|KORG|CB|Core|BLE|connect|notify|pair|auth|encrypt'
```

Useful logs:

```bash
/usr/bin/log show --last 3h --style compact --predicate 'process == "Bluetooth MIDI Connect" AND (eventMessage CONTAINS[c] "MIDI" OR eventMessage CONTAINS[c] "Bluetooth" OR eventMessage CONTAINS[c] "connect" OR eventMessage CONTAINS[c] "peripheral" OR eventMessage CONTAINS[c] "error" OR eventMessage CONTAINS[c] "auth" OR eventMessage CONTAINS[c] "encrypt")'
```

Note: plain `log` can conflict with zsh behavior; use `/usr/bin/log`.

## Current recommended next steps

1. Improve `dump-ble.m` into a repeatable security diagnostic:
   - log every relevant CoreBluetooth delegate callback;
   - log `CBPeripheral.state` transitions;
   - add optional repeated notify/read attempts;
   - avoid arbitrary writes to vendor characteristic unless explicitly approved.

2. Create an LLDB tracing script for `Bluetooth MIDI Connect.app`:
   - break on `-[CBCentralManager scanForPeripheralsWithServices:options:]`;
   - break on `-[CBCentralManager connectPeripheral:options:]`;
   - break on `-[CBPeripheral setNotifyValue:forCharacteristic:]`;
   - break on delegate methods for fail/connect/notify/value;
   - print NSError details and characteristic UUIDs.

3. Investigate `nanoKEY Studio Updater 1.08.app` if available/mounted:
   - inspect binary strings/symbols for vendor UUIDs;
   - determine current firmware version if possible;
   - check whether updater uses `D061.../8667...` vendor service.

4. If software-level tracing is inconclusive, use BLE packet capture:
   - Apple PacketLogger if available via Additional Tools for Xcode;
   - preferably nRF52840 BLE sniffer + Wireshark;
   - compare macOS failure vs Windows success.

5. Longer-term workaround target:
   - custom CoreBluetooth/CoreMIDI bridge that connects to nanoKEY Studio, obtains a secure BLE link, reads BLE-MIDI notifications, and exposes a virtual MIDI source.
   - The blocker is initiating/completing pairing/authentication from macOS.

6. Windows investigation is now requested/available because the user has a Windows machine where the keyboard connects successfully. See `windows-investigation.md`.
   - Highest-value artifact: a BLE trace of successful Windows connection.
   - If no external sniffer exists, collect Windows ETW Bluetooth logs and driver/app metadata first.
   - If an nRF52840 dongle can be acquired, capture over-the-air pairing/security and ATT flow with Wireshark.

## Things not to assume

- Do not assume MIDI parsing is the current blocker. It is not; bytes do not arrive because GATT access is rejected by security.
- Do not assume KORG app has secret logic; current evidence says it mostly wraps Apple's BLE-MIDI CoreAudioKit UI.
- Do not write random bytes to vendor characteristic without explicit approval; it may alter device state or firmware/update mode.
- Do not rely only on noble for security errors; use native CoreBluetooth where possible.

## Git workflow requested by user

The user explicitly requested:

- Keep `state.md` and `readme.md` updated throughout the work.
- Commit after every meaningful step.

Do this going forward.
