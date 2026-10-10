# MeshScout 0.3

Independent Android-first MeshCore field-mapping application. No BackCountrySignal, Bastion, or Meshtastic integration or shared application code.

## Interface and radio connection

Map, Radios, Nodes, Coverage, History and Settings are available from bottom navigation. Radio status is shown on every tab. Bluetooth scanning starts only on user action, requests the Android-version-appropriate permissions, and searches for up to ten seconds. Connect is enabled immediately when a UART candidate appears; selection cancels scanning. A UART UUID or name alone never proves MeshCore compatibility.

Connection validates GATT RX/TX properties, negotiates MTU, subscribes to TX, and performs sequential APP_START / SELF_INFO and DEVICE_QUERY / DEVICE_INFO exchanges. Setup has bounded deadlines and a single query retry for notification readiness. No configuration, messages, keys, or radio clock are changed. Raw identity replies, including any BLE PIN, are not displayed or persisted.

An Android connectedDevice foreground service supports radio retention while switching apps. After an identified link drops, automatic reconnect retries the same companion at delays of 3, 6, 12, 24 and 30 seconds, at most five attempts. Each attempt repeats identification. The service stays active during retry delays. Settings can disable automatic reconnect; Disconnect/cancel stops pending retries and releases the service. Initial connection or protocol failures require manual recovery. The target and preference are in-memory for this app run; there is no reconnection after process death, and Android/OEM termination can still end a connection.

## Nodes

Refresh from radio fetches the companion's stored contacts via GET_CONTACTS. The complete start/count/contact/end stream is validated before replacing the list. Names/public keys are searchable, repeaters can be filtered, and details show contact type, public key, last advertisement timestamp and advertised coordinates when present.

A stored contact or advertised location does not prove current presence, reachability or signal strength. This phase does not transmit discovery probes, modify the contact table, or automatically import newly heard advertisements. Refresh is explicit; the list is kept in memory. Partial/failed sync preserves the prior complete list and requires reconnect before retrying. Contact frames require negotiated MTU of at least 151.

## GPS routes and LoRa observations

Start Mapping requests precise foreground location and requires enabled GPS. Accepted fixes have valid coordinates, accuracy no worse than 100 m, and non-stale/non-duplicate timestamps. The GPS listener requests updates at 5 seconds / 5 metres. The map draws the route and current accepted position. No GPS is collected on launch.

While recording with an identified radio, RX log pushes (0x88) provide signed LoRa RSSI and quarter-dB SNR. Only receptions paired with a GPS fix from the preceding 15 seconds are recorded. Firmware emits these logs before packet validation: they describe **raw last-hop reception**, not authenticated sender identity, successful delivery, source-node coverage, or two-way reachability. Raw packet payloads are never stored. BLE signal strength remains separate.

Coverage lists recent measured observations. Map shows individual measured dots, colored by RSSI: green at or above −90 dBm, orange at or above −110 dBm, red below −110 dBm. These are illustrative bins; there is no interpolation or invented signal between points. Observations without recent GPS are not mapped. Lack of observations does not prove lack of coverage.

Stop and save writes a session atomically to private app files. History reopens the GPS route and its measurements and offers confirmed deletion. Older GPS-only sessions still load. Failed saves retain points/observations for Retry save and block starting another route over them. Each session is limited to 10,000 GPS fixes and 10,000 observations.

GPS recording stops and saves on background; radio connection/retry can continue independently. There is no background GPS permission or automatic GPS restart. Data remains local unencrypted app storage; backup is disabled. Uninstalling or clearing app data removes sessions. Map tiles require internet and are requested from OpenStreetMap; offline maps and route export are not implemented.

## Build and validation

CI pins Flutter 3.47.7, preserves owned Android Kotlin/manifest/Gradle sources while generating scaffolding, enforces the dependency lockfile, checks formatting/strict analysis, runs injected-service unit/widget tests with coverage, and builds a debug APK. Android uses compile SDK 37, AGP 9.2.1, Gradle 9.4.1 and Java 17.

Debug APKs use a stable private test signer supplied through encrypted repository secrets, allowing updates over 0.2.1 and newer while retaining saved routes. No private signing key is committed. The older 0.2 APK used an ephemeral signer and may require a one-time uninstall. Production releases require separate production signing configuration.

Tests verify parsing, sequencing, state transitions, contact-stream integrity, reconnect limits/cancellation, fresh GPS association and session persistence using fakes. They do not establish real Android dialogs, location reception, service behavior, BLE pairing/encryption or firmware interoperability. Physical Android/radio testing remains necessary.

## Hardware acceptance

- Scan and select a candidate before the ten-second scan ends; grant/deny Bluetooth access and test Bluetooth off.
- Connect your actual companion, switch apps/lock the screen, return, and disconnect explicitly. Check the Android active-service notification.
- Refresh Nodes with known contacts, verify names/types/coordinates against the companion, test repeater filtering/search and empty tables.
- Record outdoors with recent GPS while real LoRa traffic is received. Verify observed RSSI/SNR and map dots; silence must produce no fake observations.
- Stop/save, restart/reopen History, and verify older routes still load. Test background auto-save and confirmed deletion.
- Turn off or move the radio out of range, bring it back during retry, verify re-identification and continued recording where GPS is fresh. Test manual cancellation and disabled reconnect. Five failed attempts must stop the service/retry sequence.
- Repeat across Android/OEM and firmware/hardware variants. Do not share PINs, private keys or sensitive location data when reporting results.

## Sources

- [Official companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md)
- [Companion firmware contact/RX frame implementation](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp)
- [Radio dispatcher: RX log before packet validation](https://github.com/meshcore-dev/MeshCore/blob/main/src/Dispatcher.cpp)
- [Android background BLE guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Flutter reactive BLE](https://pub.dev/packages/flutter_reactive_ble)
