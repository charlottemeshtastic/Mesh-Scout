# MeshScout 0.6

Independent Android-first MeshCore field-mapping application. No BackCountrySignal, Bastion, or Meshtastic integration or shared application code.

## Interface and radio connection

Map, Radios, Nodes, Coverage, History and Settings are available from bottom navigation. Radio status is shown on every tab. Bluetooth scanning starts only on user action, requests the Android-version-appropriate permissions, and searches for up to ten seconds. Connect is enabled immediately when a UART candidate appears; selection cancels scanning. A UART UUID or name alone never proves MeshCore compatibility.

Connection validates GATT RX/TX properties, negotiates MTU, subscribes to TX, and performs sequential APP_START / SELF_INFO and DEVICE_QUERY / DEVICE_INFO exchanges. Setup has bounded deadlines and a single query retry for notification readiness. Identification changes no configuration, messages, keys, or radio clock. Messages are transmitted only through the explicit Send action. Raw identity replies, including any BLE PIN, are not displayed or persisted.

An Android connectedDevice foreground service supports radio retention while switching apps. After an identified link drops, automatic reconnect retries the same companion at delays of 3, 6, 12, 24 and 30 seconds, at most five attempts. Each attempt repeats identification. The service stays active during retry delays. Settings can disable automatic reconnect; Disconnect/cancel stops pending retries and releases the service. Initial connection or protocol failures require manual recovery. The target and preference are in-memory for this app run; there is no reconnection after process death, and Android/OEM termination can still end a connection.

## Nodes

Refresh from radio fetches the companion's stored contacts via GET_CONTACTS. The complete start/count/contact/end stream is validated before replacing the list. Names/public keys are searchable, repeaters can be filtered, and details show contact type, public key, last advertisement timestamp and advertised coordinates when present.

A stored contact or advertised location does not prove current presence, reachability or signal strength. This phase does not transmit discovery probes, modify the contact table, or automatically import newly heard advertisements. Refresh is explicit; the list is kept in memory. Partial/failed sync preserves the prior complete list and requires reconnect before retrying. Contact frames require negotiated MTU of at least 151.

The map can show stored contacts with advertised coordinates as purple markers. Tap a marker for name/type/key and advertisement time; hide them with the Advertised nodes checkbox. Contacts without coordinates are omitted, and neither a marker nor its location establishes current reachability.

## Messaging

Nodes → Messages opens a private on-phone inbox and composer. Refresh contacts first, then select a chat node to send plain direct text. Recipient prefixes must uniquely match the companion's contact table. Sends are bounded to 133 UTF-8 bytes and the negotiated MTU, have a single outstanding command, and are never automatically repeated. Radio acceptance is shown as delivery unconfirmed; only a matching SEND_CONFIRMED acknowledgement for an accepted send in this live app process establishes delivery. Ambiguous acknowledgement tags remain unconfirmed. Uncertain commands require reconnect before another request. Configured channels can be loaded from the companion and selected for plain channel sending. Only channel index/name are retained; the key portion of GET_CHANNEL is discarded before returning the response to the UI. Discovery uses the reported slot count, bounded to 64, and expected missing slots do not invalidate the connection. Channel sends are limited to 99 UTF-8 bytes to reserve space for the firmware sender-name prefix and prevent silent truncation. Radio OK confirms acceptance only; channel messages have no direct delivery ACK and remain unconfirmed. Channel configuration/key editing, CLI commands and radio clock changes remain unimplemented.

Fetch messages explicitly drains at most 100 queued messages per tap, stopping at 1,000 stored messages. Every supported contact/channel message is persisted before requesting the next. Queued-message retrieval removes it from the companion immediately; a process crash between retrieval and persistence can lose it. Unsupported queued types stop retrieval with a notice after the radio has already removed that item. Forwarded messages have unverified original origin. Fetch requires MTU ≥175. Incoming notifications only indicate waiting mail; there is no automatic queue draining or push notification service.

Local history is written atomically to private, unencrypted app storage. Failed writes retain pending data in memory, block further sends/fetches, and offer Retry saving. Restarting the app does not resend messages or infer delivery from old acceptance. Clear history requires confirmation. There is no message backup/export or guaranteed lossless recovery from phone termination.

## Export and sharing

History's Export session button offers Save or Share in GeoJSON or CSV. Android's document picker chooses a save destination; the share chooser grants temporary read access to the selected receiving application. Opening the chooser does not prove delivery. Exports include precise locations and UTC times; GPS accuracy and LoRa RSSI/SNR are preserved. GeoJSON uses longitude/latitude ordering and includes route geometry plus measurement features; a single GPS point never becomes an invalid one-point LineString. Export does not delete the local session. Temporary shared files are limited to 20 cached exports.

## Offline topo maps

Map's Download area saves a roughly 4 × 4, 8 × 8 or 12 × 12 km square centered on the current map view. No provider account is needed. Downloads use the public-domain USGS Topo tile service, restricted in this release to the contiguous U.S. and zoom levels 12–16, with at most 5,000 tiles / 150 MB. This is one replaceable area, not a whole-state or global download.

Downloads show progress and support cancellation. A complete new area is published only after all tile responses are saved; failure/cancellation retains the prior complete area. Interrupted publication can recover the backup on next launch. The Offline switch uses only local files with no online tile fallback. Outside saved bounds, the basemap is unavailable; GPS, route and node overlays still operate. The area persists, but Offline mode is selected manually each fresh app launch. Delete offline area removes only the map pack. Below zoom 12 the offline basemap is hidden; zooming above 16 enlarges saved tiles. Enabling Offline centers the map on the saved area.

Online mode continues to use OpenStreetMap. Its standard tile server is never bulk-downloaded. Map services and data available from U.S. Geological Survey, National Geospatial Program.

## GPS routes and LoRa observations

Start Mapping requests precise foreground location and requires enabled GPS. Accepted fixes have valid coordinates, accuracy no worse than 100 m, and non-stale/non-duplicate timestamps. The GPS listener requests updates at 5 seconds / 5 metres. The map draws the route and current accepted position. No GPS is collected on launch.

While recording with an identified radio, RX log pushes (0x88) provide signed LoRa RSSI and quarter-dB SNR. Only receptions paired with a GPS fix from the preceding 15 seconds are recorded. Firmware emits these logs before packet validation: they describe **raw last-hop reception**, not authenticated sender identity, successful delivery, source-node coverage, or two-way reachability. Raw packet payloads are never stored. BLE signal strength remains separate.

Coverage lists recent measured observations. Map shows individual measured dots, colored by RSSI: green at or above −90 dBm, orange at or above −110 dBm, red below −110 dBm. These are illustrative bins; there is no interpolation or invented signal between points. Observations without recent GPS are not mapped. Lack of observations does not prove lack of coverage.

Stop and save writes a session atomically to private app files. History reopens the GPS route and its measurements, supports editable session names (80 characters), and offers confirmed deletion. Names are saved atomically and included in GeoJSON; older unnamed sessions remain readable. Older GPS-only sessions still load. Failed saves retain points/observations for Retry save and block starting another route over them. Each session is limited to 10,000 GPS fixes and 10,000 observations.

GPS recording stops and saves on background; radio connection/retry can continue independently. There is no background GPS permission or automatic GPS restart. Data remains local unencrypted app storage; backup is disabled. Uninstalling or clearing app data removes sessions. Online map tiles require internet; a previously downloaded topo area can be used in Offline mode. Session export is available from History.

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
- Export an older GPS-only route and a route with measurements to GeoJSON/CSV. Save through Android, reopen in a GIS/spreadsheet, and verify timestamps, longitude/latitude, RSSI/SNR and accuracy. Share to another app; verify the attachment arrives.
- Refresh contacts and locate purple advertised markers; tap details and hide/show markers.
- Pan to your contiguous-U.S. test area, download it and enable Offline. Disable internet while keeping Bluetooth active, pan/zoom within the saved area, and restart/toggle Offline again. Verify outside-area missing basemap, cancellation, failure retaining old area, replacement and deletion.
- Refresh contacts, open Messages, send to a known chat companion, distinguish acceptance from delivery confirmation, retrieve known direct/channel messages, restart to verify persistence, and test disconnection without duplicate transmission. Rename a saved route and reopen it; verify 4, 8 and 12 km download choices.
- Repeat across Android/OEM and firmware/hardware variants. Do not share PINs, private keys or sensitive location data when reporting results.

## Sources

- [Official companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md)
- [Companion firmware contact/RX frame implementation](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp)
- [Radio dispatcher: RX log before packet validation](https://github.com/meshcore-dev/MeshCore/blob/main/src/Dispatcher.cpp)
- [Android background BLE guidance](https://developer.android.com/develop/connectivity/bluetooth/ble/background)
- [Android Bluetooth permissions](https://developer.android.com/develop/connectivity/bluetooth/bt-permissions)
- [Flutter reactive BLE](https://pub.dev/packages/flutter_reactive_ble)

- [USGS map-service usage terms](https://www.usgs.gov/faqs/what-are-terms-uselicensing-map-services-and-data-national-map)
- [USGS Topo tile service](https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer)
- [OpenStreetMap tile usage policy](https://operations.osmfoundation.org/policies/tiles/)
