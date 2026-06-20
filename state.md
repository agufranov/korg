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
- Wireshark CLI tools are installed under `/opt/homebrew/bin` and should be used for future capture analysis instead of ad-hoc parsers:
  - `tshark` — Wireshark `4.6.6`
  - `capinfos` — Wireshark `4.6.6`
  - `editcap`
  - `mergecap`
  - `rawshark`
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

## Windows nRF capture `wireshark.pcapng` analysis, 2026-06-20

User provided `wireshark.pcapng` captured on Windows with `nRF Sniffer for Bluetooth LE COM5`.

Local tools available on macOS:

- `tshark`/`capinfos` are not installed.
- `tcpdump` can read pcapng but reports Nordic BLE link type as `UNSUPPORTED`, so a small Python pcapng/Nordic parser was used.

Capture metadata/facts:

```text
file: wireshark.pcapng
size: ~1.1 MB
pcapng linktype: 272 / LINKTYPE_NORDIC_BLE
capture OS string: 64-bit Windows 10 (22H2), build 19045
sniffer: nRF Sniffer for Bluetooth LE COM5
duration: ~51.056875 s
packets: 13458
```

Advertising facts extracted:

```text
nanoKEY advertiser address: 10:98:C3:53:6B:1B
advertised name: nanoKEY Studio
advertised service: 03B80E5A-EDE8-4B33-A751-6CE34EC4C700
```

Windows central/init address seen in CONNECT_IND:

```text
E8:48:B8:C8:20:00
```

Two connection requests were captured:

```text
packet 1779, +1.074413s:
  initA: E8:48:B8:C8:20:00
  advA:  10:98:C3:53:6B:1B
  access address: b45fa108
  interval: 6 * 1.25ms = 7.5ms
  latency: 0
  supervision timeout: 200 * 10ms = 2s

packet 10917, +38.138287s:
  initA: E8:48:B8:C8:20:00
  advA:  10:98:C3:53:6B:1B
  access address: 5e421abb
  interval: 6 * 1.25ms = 7.5ms
  latency: 0
  supervision timeout: 200 * 10ms = 2s
```

Critical limitation of this capture:

```text
The pcapng contains CONNECT_IND packets, but no packets using either connection access address beyond the CONNECT_IND itself.
Occurrences in raw file:
  b45fa108: 1
  5e421abb: 1
  advertising access address d6be898e: 13458
```

Interpretation: the nRF sniffer did not follow the data-channel connection. The capture is useful for advertisement/connection-request facts, but it does not include SMP pairing, LL encryption, ATT/GATT writes, CCCD subscription, or MIDI notifications.

Next capture must ensure Wireshark/nRF Sniffer follows the selected `nanoKEY Studio` connection. In Wireshark, select the device in the nRF Sniffer device list before/while connecting and verify packets with the new connection access address appear after CONNECT_IND.

## Windows nRF capture `2.pcapng` analysis, 2026-06-20

User provided `2.pcapng` captured on Windows. Local quick parser results:

```text
file: 2.pcapng
size: 18,372 bytes
packets: 207
nanoKEY advertiser address: 10:98:C3:53:6B:1B
advertised name: nanoKEY Studio
advertised BLE-MIDI service: 03B80E5A-EDE8-4B33-A751-6CE34EC4C700
Windows central/init address: E8:48:B8:C8:20:00
```

This capture did catch two real CONNECT_IND packets to nanoKEY:

```text
packet 11:
  initA: E8:48:B8:C8:20:00
  advA:  10:98:C3:53:6B:1B
  access address: adc0948a (display) / 8a94c0ad (little-endian in file)

packet 206:
  initA: E8:48:B8:C8:20:00
  advA:  10:98:C3:53:6B:1B
  access address: 4b28a60b (display) / 0ba6284b (little-endian in file)
```

Critical limitation remains:

```text
8a94c0ad occurrences: 1 packet only (the CONNECT_IND itself)
0ba6284b occurrences: 1 packet only (the CONNECT_IND itself)
```

Interpretation: `2.pcapng` is better than `1.pcapng` because it proves Windows attempted two connections to the correct nanoKEY address, but the nRF sniffer still did not follow either data-channel connection. It still does not include SMP pairing, LL encryption, ATT/GATT, CCCD subscription, vendor writes, or BLE-MIDI notifications.

## Windows nRF capture `3.pcapng` analysis, 2026-06-20

User found the nRF Sniffer toolbar in Wireshark and configured:

```text
Interface: COM5-4.6
Device: All advertising devices
Key: Follow LE address
Value: 10:98:c3:53:6b:1b public
Adv Hop: 37,38,39
```

This finally made the sniffer follow the connection. Quick parser results:

```text
file: 3.pcapng
size: 3,520 bytes
packets: 39
nanoKEY advertiser address: 10:98:C3:53:6B:1B
Windows central/init address: E8:48:B8:C8:20:00
CONNECT_IND packet: 17
connection access address: cae0689a (display) / 9a68e0ca (little-endian in file)
connection access address occurrences: 9 packets total
```

Interpretation: `3.pcapng` is the first capture that actually includes data-channel packets after CONNECT_IND. It is still very short: only 8 post-CONNECT_IND data-channel packets were captured. The visible post-CONNECT_IND payloads look like early LL data/control traffic, not yet enough to analyze the full Windows success path. Need a longer capture with the same toolbar settings, keeping capture running through successful Windows connection plus key/pad/knob input.

## Windows nRF capture `4.pcapng` analysis, 2026-06-20

User provided a longer capture after finding the toolbar.

```text
file: 4.pcapng
size: 671,748 bytes
duration: ~87.823 s
packets: 7,985
encapsulation: nRF Sniffer for Bluetooth LE / LINKTYPE_NORDIC_BLE
```

This capture contains a valid CONNECT_IND to nanoKEY:

```text
frame 3432 / parser index 3431, +32.441904s:
  initA: E8:48:B8:C8:20:00
  advA:  10:98:C3:53:6B:1B
  access address: 694af5c9 (display) / c9f54a69 (little-endian in file)
  interval: 48 * 1.25ms = 60ms
  latency: 0
  supervision timeout: 960 * 10ms = 9.6s
  channel map: ff ff ff ff 1f
```

Critical limitation: `c9f54a69` occurs only once, in the CONNECT_IND itself. Wireshark/tshark protocol hierarchy shows only `btle` advertising-layer traffic and no `btsmp`, `btatt`, or `btgatt`. So `4.pcapng` is a long capture, but it did not follow the data-channel connection. `3.pcapng` remains the only capture so far that proved data-channel follow worked.

Practical implication: the toolbar settings can work, but the long capture likely started without the follow address being actively applied, or the sniffer failed to synchronize after this specific CONNECT_IND. Before the next long capture, click/apply the toolbar control next to `Value` after setting `Key = Follow LE address` and `Value = 10:98:c3:53:6b:1b public`, then verify immediately after CONNECT_IND that packets with the new connection access address continue appearing.

## Windows nRF capture `5.pcapng` analysis, 2026-06-20

This is the first useful long Windows success-path capture.

```text
file: 5.pcapng
size: 596,772 bytes
packets: 9,894
nanoKEY advertiser address: 10:98:C3:53:6B:1B
Windows central/init address: E8:48:B8:C8:20:00
CONNECT_IND frame: 58
connection access address: dbf30e2a (display) / 2a0ef3db (little-endian in file)
connection access address occurrences: 9,837 packets
connection interval: 7.5ms
latency: 0
supervision timeout: 2s
channel map: 3e fe ff ff 1f
```

Wireshark protocol hierarchy confirms actual data-channel content:

```text
btl2cap: 96 frames
btatt:   88 frames
btsmp:    8 frames
```

Important sequence:

```text
26.139s ATT Exchange MTU Request, Client Rx MTU 527
26.154s ATT Exchange MTU Response, Server Rx MTU 23
26.236s ATT Write Request to handle 0x000f (Service Changed CCCD)

30.001s SMP Pairing Request: Bonding, MITM; initiator keys IRK/CSRK; responder keys LTK/IRK/CSRK
30.009s SMP Pairing Response: Bonding; responder key LTK only
30.069s SMP Pairing Confirm
30.091s SMP Pairing Random
30.145s SMP Encryption Information + Central Identification

30.106s LL_ENC_REQ
30.114s LL_ENC_RSP
30.129s LL_START_ENC_REQ
30.136s/30.144s LL_START_ENC_RSP
```

After pairing/encryption, Windows performs full GATT discovery. Handles discovered:

```text
0x0001..0x000b GAP
0x000c..0x000f GATT / Service Changed
0x0010..0x0014 Device Information
0x0015..0x0018 KORG/vendor service D0611E78-BBB4-4591-A5F8-487910AE4366
  characteristic value handle 0x0017: 8667556C-9A37-4C91-84ED-54EE27D90049
  CCCD handle 0x0018
0x0019..0x001c BLE-MIDI service 03B80E5A-EDE8-4B33-A751-6CE34EC4C700
  characteristic value handle 0x001b: 7772E5DB-3868-4112-A1A9-F2669D106BF3
  CCCD handle 0x001c
```

Limitations of `5.pcapng`:

- The capture contains pairing/encryption and GATT discovery, which is the key missing evidence so far.
- It does **not** show writes to the KORG vendor CCCD `0x0018` or BLE-MIDI CCCD `0x001c`; the only ATT Write Request decoded is to Service Changed CCCD `0x000f` before pairing.
- It does **not** show BLE-MIDI Handle Value Notifications (`btatt.opcode == 0x1b`). Either Windows did not open/use the MIDI endpoint during this capture, notifications were not generated, or the capture ended/filtered before DAW/MIDI use.

Key new conclusion: Windows succeeds by doing SMP pairing and LL encryption after initial GATT probing. The relevant security flow is visible in `5.pcapng` and can now be compared with macOS/CoreBluetooth behavior, where reads/notifies fail with `Authentication is insufficient` / `Encryption is insufficient`.

## Windows nRF capture `6.pcapng` analysis, 2026-06-20

This is the first capture containing the full useful flow: pairing/encryption, BLE-MIDI CCCD subscription, and actual BLE-MIDI notifications.

```text
file: 6.pcapng
size: 305,600 bytes
packets: 5,050
CONNECT_IND frame: 7
initA: E8:48:B8:C8:20:00
advA:  10:98:C3:53:6B:1B
connection access address: 8acbdbaf (display) / afdbcb8a (little-endian in file)
connection access address occurrences: 5,044 packets
connection interval: 7.5ms
latency: 0
supervision timeout: 2s
```

Protocol hierarchy:

```text
btl2cap: 171 frames
btatt:   161 frames
btsmp:     8 frames
```

Security sequence is the same Windows success pattern as `5.pcapng`, but earlier in the capture:

```text
5.804s SMP Pairing Request: Bonding, MITM; initiator keys IRK/CSRK; responder keys LTK/IRK/CSRK
5.811s SMP Pairing Response: Bonding; responder key LTK only
5.871s SMP Pairing Confirm
5.886s SMP Pairing Random
5.901s LL_ENC_REQ
5.909s LL_ENC_RSP
5.924s LL_START_ENC_REQ
5.931s/5.939s LL_START_ENC_RSP
5.939s SMP Encryption Information + Central Identification
```

BLE-MIDI subscription and traffic:

```text
6.096s ATT Read Request, Handle 0x001b (BLE-MIDI characteristic value)
6.111s ATT Read Response, Handle 0x001b, value 00
6.156s ATT Read Request, Handle 0x001c (BLE-MIDI CCCD)
6.186s ATT Read Response, Handle 0x001c

9.224s ATT Write Request, Handle 0x001c (BLE-MIDI CCCD)
       Service UUID: 03B80E5A-EDE8-4B33-A751-6CE34EC4C700
       Characteristic UUID: 7772E5DB-3868-4112-A1A9-F2669D106BF3
       CCCD value: 0x0001 Notification = True
9.231s ATT Write Response, Handle 0x001c

10.221s onward: many ATT Handle Value Notifications from handle 0x001b
```

Example BLE-MIDI notification payloads from handle `0x001b`:

```text
95 ed 90 47 4d
97 c3 80 47 40
9e 9f 90 47 3d
9f db 80 47 40
a0 ae 90 47 2d
a1 d0 80 47 40
```

These look like standard BLE-MIDI packets: timestamp bytes followed by MIDI channel messages (`0x90` note on, `0x80` note off) with note/velocity bytes.

No write to KORG vendor CCCD `0x0018` or vendor characteristic `0x0017` was observed in the extracted traffic. Windows appears to use the standard BLE-MIDI characteristic after pairing/encryption, not a vendor-specific handshake, at least in this successful MIDI-use capture.

Key conclusion from `6.pcapng`: the complete Windows working path is:

1. Connect to nanoKEY.
2. Do SMP pairing with Bonding + MITM requested by central.
3. Start LL encryption.
4. Discover GATT.
5. Subscribe to BLE-MIDI CCCD handle `0x001c` with value `0x0001`.
6. Receive BLE-MIDI notifications from value handle `0x001b`.

This is the concrete behavior the macOS workaround/bridge must reproduce or cause CoreBluetooth to initiate.

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
   - First provided nRF capture only caught advertising + CONNECT_IND, not data-channel traffic. Need recapture with connection following enabled/verified.

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
