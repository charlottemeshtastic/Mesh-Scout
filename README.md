# MeshScout

**Explore MeshCore radio activity. Understand what your companion radio can hear.**

MeshScout is an independent, Android-first, open-source Flutter app being developed to help MeshCore users observe radio receptions and, in future releases, map real-world network coverage.

> **Project status: early development (v0.1.0).** MeshScout is not yet a completed coverage mapper. The map is currently a base map, not a measured coverage visualization. Hardware compatibility still needs field validation.

## What MeshScout does today

- Displays an interactive map powered by OpenStreetMap.
- Scans for nearby Bluetooth Low Energy (BLE) UART candidates and attempts a MeshCore companion-protocol handshake before reporting a compatible connection.
- Lets you manually connect and disconnect a compatible companion radio.
- Passively collects live LoRa reception metadata **when supported by companion firmware**, including received signal strength (RSSI), signal-to-noise ratio (SNR), and packet/path metadata.
- Shows recent reception activity in a temporary, in-memory observation panel with start, stop, and clear controls.

**Important:** BLE signal strength measures the *phone-to-radio Bluetooth link*, not MeshCore LoRa coverage. Received LoRa RSSI/SNR reflects what the companion radio heard; it does not by itself establish end-to-end delivery or sender location.

## What is planned (not available yet)

- Opt-in GPS-tagged field observations and map overlays.
- Saving and exporting observations.
- More useful coverage visualizations and field-testing workflows.
- Expanded device and firmware validation.

No coverage heatmap, GPS recording, persistent observation database, message sync, or public data sharing is implemented at present.

## Getting started

1. Install a development build on an Android phone with BLE support.
2. Power on a compatible MeshCore companion radio and enable Bluetooth.
3. Open MeshScout and tap the Bluetooth icon on the map.
4. Grant the requested Android permissions, scan for radios, and select a candidate.
5. After the companion-protocol check succeeds, tap **Start collecting** to inspect live receptions.

Scanning takes up to ten seconds. Android 12+ requests Nearby Devices permission; Android 11 and earlier require foreground location permission and location services for BLE discovery. Collection requires compatible firmware that emits RF reception logs. If none appear, that alone does **not** prove a coverage gap.

## Privacy and radio safety

MeshScout's current observation flow is **read-only**. It does not change radio settings, channels, keys, messages, or the radio clock. Raw packet contents, message bodies, sender keys, and path hashes are not saved in the observation history. Recent reception metadata stays in memory and is cleared by app restart. The current app does not collect GPS coordinates or upload coverage observations.

## Project identity

MeshScout is an **independent community project**, not an official MeshCore application or an endorsement by MeshCore maintainers. MeshCore is referenced to describe protocol compatibility.

## Development and validation

Built with Flutter and Dart, with Riverpod state management, flutter_map, and Android BLE integration. CI runs static analysis, tests, and a debug APK build. Automated tests do **not** replace real-device testing; field hardware acceptance remains outstanding.

For setup, BLE protocol details, technical limitations, validation scope, and upstream references, see the engineering notes below.

---

## Engineering notes

## Phase 2 Bluetooth foundation

Open the Bluetooth button on the map. Scan requests Nearby Devices on Android 12+; Android 11 and earlier request foreground location access and require location services. Permanent denial offers app settings. Enable Bluetooth before retrying.

A scan is bounded to ten seconds and filters the Nordic UART service. Results are deduplicated by device ID and update BLE RSSI. Stop scanning before selecting a candidate. This UUID is shared by unrelated products: candidates are **not** identified as MeshCore by their name or UUID alone.

Connection uses a bounded prescan and connection timeout, discovers RX/TX and checks write-with-response and notify properties, requests MTU 512 (requires at least 179 for complete 176-byte reception reports), subscribes to TX, then performs sequential APP_START / SELF_INFO and DEVICE_QUERY / DEVICE_INFO exchanges. Short, empty, and unrelated push packets cannot satisfy the handshake. Only protocol-compatible replies reach ready. This is compatibility detection, not cryptographic authentication. Commands are short enough for the default 20-byte ATT payload. Initialization may retry the same read-only query once to tolerate notification setup; all setup is bounded by a 20-second deadline. No radio settings, channels, messages, keys, or clock are changed. No raw replies (which can include BLE PINs) are displayed, logged or persisted.

Cancellation, errors, connection loss, route exit, backgrounding, and disposal release owned streams and timers. Reconnection is explicit: scan and select again. Background BLE and automatic reconnect are deferred until hardware behavior is measured.

BLE RSSI measures the phone-to-companion link, **not LoRa coverage**. GPS collection, saved observations, coverage overlays, message sync, protocol version feature negotiation and public sharing remain future work.

## Live LoRa observations

After connecting, tap **Start collecting**. MeshScout passively parses live `PUSH_CODE_LOG_RX_DATA` (0x88) notifications: UTC phone receipt time, signed LoRa RSSI (dBm), quarter-dB SNR, route type, packet type/version, encoded path hash count/size, and packet byte length. Advertisements are included when their raw reception is reported. Contact/advertisement notifications without RF measurements are ignored; no invented RSSI or association with nearby packets.

The newest 200 receptions are kept in memory, with the latest 20 shown. Repeated receptions are retained: they may be real relays/retransmissions, and metadata alone cannot identify duplicates. Stop pauses collection; clear resets data and counters. Disconnect, backgrounding, and screen exit stop collection but retain results until a new scan or app restart. Malformed RF reports are counted and skipped. Unknown unrelated notifications are ignored.

No additional radio commands are sent for collection. No queue is drained, messages are not fetched, and radio configuration is unchanged. Raw packet bytes, message contents, sender keys and path hashes are discarded after extracting metadata. No GPS, disk storage, export, coverage score or map pins are generated. Receipt time is the phone arrival time, not an on-air timestamp; RSSI/SNR describe the reception at the companion, not necessarily a direct link to the originating sender. Path hash count is route metadata, not a guaranteed observed hop count. Raw logs establish RF activity, not authenticated sender identity or successful delivery.

Firmware must emit RF reception logs over the connected companion interface. Silence cannot establish lack of coverage, and firmware may omit packets that exceed its frame limit. The native adapter requires MTU >=179 to carry the current maximum 176-byte companion frame; no fragmentation/reassembly is assumed.

The parser follows official `MyMesh::logRxRaw`, `Packet::writeTo/readFrom`, and encoded-path rules, including four transport-code bytes and 1–3 byte path hashes with a 64-byte path limit. Wire fixtures test these layouts; they are not captured hardware evidence.

## Validation

CI pins Flutter 3.47.7, restores the owned Android manifest, app build settings, and lockfile after generating the native scaffold, enforces the dependency lockfile, checks Dart formatting and analysis, runs unit/widget tests with coverage, builds an Android debug APK, and uploads both artifacts.

The app currently owns its Android manifest and app Gradle settings (compile SDK 37); the rest of the Android scaffold is generated by `flutter create --platforms=android --org org.meshscout --project-name mesh_scout .` (preserve the manifest, app build settings, and lockfile). Run `flutter pub get`, `flutter analyze`, and `flutter test` locally.

### Hardware acceptance pass — not yet performed

- Android 11: grant/deny location, location services off, Bluetooth off, scan timeout and repeated scans.
- Android 12+: Nearby Devices grant/deny/permanent denial and return from settings.
- Live observation pass: generate known RF traffic including adverts, verify signed RSSI/SNR against companion logs, max-sized and transport/multi-byte-path packets, start/stop/clear, bounded history, link loss and background cleanup; verify no message contents appear.
- Real MeshCore companion: advertised UUID, pairing/PIN flow, GATT properties, negotiated MTU, notification setup, handshake responses, connection timeout, range loss, reconnect, screen exit/background/resume.
- UART device with unrelated firmware: fails identification; no LoRa coverage data invented.
- Two Android OEMs and at least two companion firmware/hardware variants; confirm neverForLocation does not hide the companion advertisements.

Tests use injected BLE fakes. They establish state behavior and wire sequencing, not OS dialogs, plugin/native round trips, BLE encryption/pairing, RF reception, or firmware interoperability. Native Android build success alone does not establish hardware compatibility.

## Sources

- [Official MeshCore companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md)
- [Official packet framing](https://github.com/meshcore-dev/MeshCore/blob/main/src/Packet.cpp)
- [Official companion firmware implementation](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp)
- [Flutter reactive BLE guidance](https://pub.dev/packages/flutter_reactive_ble)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Flutter platform integration guidance](https://docs.flutter.dev/platform-integration/platform-channels)

`neverForLocation` applies only to companion discovery in this phase. Future GPS coverage capture requires its own consent and permission design; do not infer physical location from BLE scans without revisiting this declaration.
