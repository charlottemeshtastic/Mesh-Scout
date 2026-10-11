# MeshScout 1.5.0

Independent Android MeshCore field-mapping app. MeshScout has no BackCountrySignal integration, shared data, account or application code. Android APKs are test builds; real-device acceptance remains necessary.

## What is implemented

Bottom navigation exposes Map, Radios, Nodes, Coverage, History and Settings. Explicit BLE scanning allows immediate selection of an advertised UART candidate. Connection validates characteristics, negotiates MTU and identifies the MeshCore companion before enabling commands. Identification changes no radio configuration. A connected-device foreground service and bounded reconnect attempts support app switching; Android/OEM process termination can still end the link. The preferred identified radio and reconnect preference persist. Previously active monitoring reconnects on reopening. A sticky service also attempts read-only native monitoring after a system-requested service restart; it hands the connection back to Flutter when the app connects. Recovery remains best effort and does not override force-stop, revoked permissions, unavailable Bluetooth or OEM restrictions.

Nodes refresh validates the complete contact stream before publishing it. Advertised positions are separate from actual GPS-tagged LoRa reception observations. Nodes → Manage contacts, channels and diagnostics adds:

- Contact add/edit/delete, JSON export and reviewed import (up to 5,000 contacts per import). Edits retain path/flags/location; public keys identify contacts and cannot be edited. Import updates matching keys and retains other contacts. Radio mutations can partially complete if the link fails; no automatic rollback or retry.
- A bounded list of newly heard candidates from firmware NEW_ADVERT pushes, with optional explicit Import. Firmware may auto-store advertisements itself; refresh the radio table to see those. No background probe scanning or silent table import.
- Explicit path discovery, status/reachability requests, telemetry requests, repeater login and CLI commands. Companion acceptance does not prove remote success. Replies are matched to the requested public-key prefix, live connection generation and a 60-second display window. Missing replies leave reachability unknown. Paths show repeater hashes, which are not unique identities. Standard/extended Cayenne sensor values are decoded; unknown types and status fields remain raw.
- Channel creation/replacement by reported slot index, 31-byte name and a supplied/generated 128-bit key. Keys are shown for explicit provisioning, never read from existing channels, stored in history, or included in backups. Preserve a newly generated key securely before closing the dialog.
- Frequency, bandwidth, spreading factor, coding rate and explicit client-repeat selection, in addition to name, power and clock controls on Radios. Firmware validates radio parameters; user-selected frequency/region and mesh compatibility remain the user's configuration. Client repeat needs firmware support. Changing settings can interrupt mesh communication.

All companion commands share the existing operation lock. Commands exceeding negotiated MTU are rejected before writing. Uncertain writes/replies require reconnecting and are never automatically repeated. Repeater passwords and outgoing CLI commands are not saved. Queued CLI responses are manually fetched in Messages and clearly labeled.

Messages supports direct/channel text, manual queue retrieval, local atomic persistence and JSON/CSV export. A live matching ACK confirms direct delivery; companion OK only confirms channel acceptance. Automatic sends are never performed. Inbox retrieval can be explicitly enabled at 30-second intervals while connected and idle; failures pause it until manual retrieval. Received frames are atomically checkpointed before completing retrieval, then decoded and saved to history before the next queue request. Restart recovers the checkpoint, deduplicating by a unique checkpoint ID if history was already published. Unsupported frames remain as labeled raw messages. Power loss before the checkpoint is durable can still lose a removed queue item; the radio protocol has no transactional dequeue acknowledgement. Conversations are grouped by companion radio and recipient/channel, with persistent unread counts, explicit Mark read and confirmed individual deletion. Notification alerts are opt-in. Histories contain private text/location data in Android app-private storage.

## Mapping and field tools

GPS recording, completed sessions, names, GeoJSON/CSV export and fresh GPS-associated raw LoRa reception observations remain available. Background GPS is optional, starts while visible, uses a location foreground service and checkpoints GPS fixes. Foreground and background recordings checkpoint geometry and associated LoRa observations. Process interruption recovers the latest durable route and observations on reopening; checkpoints do not continue collecting after the GPS process stops.

Coverage → Summaries, comparisons, waypoints and route import provides side-by-side summaries of two sessions, route distance, mean/range RSSI, mean SNR and sample counts. Measured signal bars group observations in 0.001° cells; cell size varies with latitude. Cells without observations have no inferred coverage. Raw LoRa metrics are last-hop reception, not verified sender identity or proof of two-way coverage.

Waypoints and notes persist privately, appear as cyan flags on Map and can be deleted with confirmation. Up to 1,000 waypoints; names up to 80 characters, notes up to 2,000. GeoJSON route import accepts a WGS84 LineString or exactly one LineString in a FeatureCollection, 2–10,000 points. Imported geometry is labeled as a planned route with no reception observations; imported timestamps/accuracy are unknown. Exports mark planned points explicitly and omit their measurement timestamps/accuracy. GPX 1.0/1.1 import accepts exactly one continuous route or track segment with 2–10,000 points, as planned geometry. Separate segments must be split before import; timestamps, elevation, waypoints and extension measurements are not imported. DTD/entity declarations are rejected.

## Field safety and map tools (1.3)

- **Auto-stop when parked:** a recording stops and saves after the phone stays within 30 m of one spot for 10 minutes (5/10/15/30 configurable, on by default). The check runs on each fix, each reception and every 30 seconds.
- **Flight check:** fixes above 6,000 m altitude or faster than 250 km/h (reported speed, or derived from fixes at least 10 s apart) are never recorded; two in a row end the session so airborne receptions do not mix with ground coverage.
- **Altitude:** GPS points keep altitude and speed when Android reports them. CSV and GeoJSON exports add `altitude_m`.
- **Disconnect alert:** when an identified radio drops (ready → reconnecting/failed) MeshScout posts a high-priority notification whose channel sound follows silent mode and Do Not Disturb. Manual disconnects never alert. Without notification permission a tone plays only in normal ringer mode. Reconnecting clears it.
- **Radio presets:** frequency, bandwidth, SF and CR are read while identifying the companion (and after a status refresh) and saved with each new session. Settings → Map → Match the connected radio preset filters History and saved coverage to that preset.
- **Saved coverage and gaps:** Map → All saved coverage draws measured 0.001° cells from every saved session (strongest RSSI colour). "Last N days only" hides older cells so areas that need mapping again stand out.
- **Node markers:** neutral markers with an edge colour by advert age (green ≤24 h, amber ≤7 d, grey older). Nodes within ~11 m share one marker with a count; tapping zooms in, and tapping again lists them by full public key.
- **Quick guide and settings folders:** a 12-page guide appears once after preferences load and reopens from Settings → About and support. Settings are grouped into Radio and alerts, Recording, Map, Backup and storage, and About and support.

Not included because MeshScout has no server or iOS build: MeshMapper server ping protocol, server sessions/keepalives, Anonymous Mode, Custom API forwarding, regional CARpeater lists, server device catalog, Flood Off regions, administrator-verified site info, Siri, CarPlay, Live Activities and Apple Watch.

## Offline maps

Up to five separate named areas can be selected, renamed or deleted. USGS downloads support contiguous-U.S. 4/8/12 km areas at zoom 12–16 and 24/48 km areas at zoom 10–14. Downloads are capped at 5,000 tiles / 150 MB per area, bounded and throttled; online OpenStreetMap tiles are never bulk downloaded.

Pause or a failed download retains private staging. Resume verifies completed image signatures and reuses those tiles. Starting a different area discards the paused staging after validation. Completed areas publish only after all tiles and metadata are saved; older areas remain available.

Import MBTiles supports worldwide user-provided PNG/JPEG raster and OpenMapTiles-schema PBF vector packs, up to 500 MB, 50,000 tiles, zoom 0–22. Native SQLite converts TMS rows to XYZ files. Raster bounds and vector framing are checked before publication; gzip vector tiles expand to at most 4 MB each, with a 500 MB total extracted limit. Vector rendering uses a bundled basic style for water, waterways, landuse/landcover, buildings, transportation, boundaries and place names. Other schemas, custom styles, icons, terrain and global automatic downloads are unsupported. Use licensed packs; source attribution is retained as plain text on the map and in backups. Offline mode makes no basemap network requests; outside a saved pack the basemap is absent. Raster and vector areas can coexist, switch, rename, delete and travel in encrypted full backups. Large real-world packs still require phone testing.

## Backup, merge and cloud document

Legacy JSON backup/restore remains compatible. Settings → Full backup supports a version-2 ZIP bundle containing completed routes, observations, message history, waypoints/notes, user-entered repeater details and preferred-radio/reconnect/background-GPS/automatic-inbox preferences. Saved raster/vector maps are optional (maximum 500 MB / 50,000 entries and five areas). Radio secrets, notification grants, cloud-provider permissions, scheduling secrets and in-progress recordings are excluded.

Encryption uses PBKDF2-HMAC-SHA256 (150,000 iterations, random 128-bit salt) and AES-256-GCM authenticated 64 KiB records, distinct indexed nonces and an authenticated terminal record. A 12-character minimum passphrase is required for encryption. Missing/tampered/reordered records, trailing bytes and wrong passwords reject the entire file before extraction or restore. Keep the passphrase: the app cannot recover it.

Restore first stages bounded entries in private storage, rejects unexpected paths and validates the data, waypoint/map limits and raster images. A preview offers Cancel, Merge or Replace. Merge keeps current session/waypoint IDs and preferences, deduplicates messages by radio/peer/time/direction/body and adds map areas up to the five-area limit. ID collisions keep the current record. Replace restores included history/preferences/maps. Data and included maps publish through one atomic private profile pointer. Maps omitted from a backup remain referenced by the restored profile. Old profiles remain private to preserve referenced maps. Settings → Storage can remove unused restore profiles, protecting both the active profile and any profile containing its referenced maps.

Stop recording/downloads, wait for saves and disconnect the radio before backup/restore. Reconnect/background-GPS preferences persist and are applied after restore. Restored notification permissions are never silently granted.

Cloud backup uses Android's Storage Access Framework. Choose a **dedicated backup document** in an installed cloud provider (or local storage). Explicit Upload overwrites that document; Download previews before merge/replace. Document-provider access is user-granted and provider-dependent. Provider failure during overwrite can leave the remote file incomplete, so keep a separate local backup. This document backup remains available separately from the shared-folder synchronization below.

Daily encrypted backups are explicitly enabled after choosing a target. Android JobScheduler runs them while charging and online, approximately daily and potentially delayed. GPS recording defers the job. The scheduling passphrase is protected by Android Keystore on this phone, excluded from portable backups, and removed when scheduling is disabled. Settings displays the latest job status. Re-enable scheduling on a restored/new phone; no provider URI is restored from a bundle.

## Build verification and limits

CI pins Flutter 3.47.7, compile SDK 37, AGP 9.2.1, Gradle 9.4.1 and Java 17. It preserves owned Android sources, enforces the lockfile, formatting and strict analysis, runs Dart tests with coverage, builds an optimized release-mode candidate APK with the stable private test signer, then runs JVM backup-authentication tests. No private signing key is committed. Updates over 0.2.1+ retain data; production signing/store release is separate work.

Settings → Storage displays history limits, saved-map size and total private file/cache usage. Confirmed cleanup can keep the latest 200 messages, keep the latest 20 sessions, discard paused map-download staging, or remove unused restore profiles. No history is automatically deleted. Export or back up before cleanup; stop recording and disconnect first. Individual route/map deletion remains available in History/Map.

Tests cover protocol validation, stream sequencing, reconnect cancellation, GPS association/persistence, backup validation/merge, diagnostic decoding, failed-download retention and reuse on resume, plus native encryption roundtrip, wrong password, truncation and tampering. CI success establishes software checks and APK compilation; it does not establish real BLE firmware interoperability, Android document dialogs, Keystore behavior on every OEM, large MBTiles imports, background service survival or cloud-provider/job timing. These require physical phone/radio testing.

## Sources

- [MeshCore companion firmware](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp)
- [Official companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md)
- [Cayenne telemetry data types](https://github.com/ElectronicCats/CayenneLPP/blob/1.6.1/src/CayenneLPP.h)
- [GPX 1.1 specification](https://www.topografix.com/GPX/1/1/)
- [MBTiles 1.3 specification](https://github.com/mapbox/mbtiles-spec/blob/master/1.3/spec.md)
- [Android document access](https://developer.android.com/training/data-storage/shared/documents-files)
- [Android JobScheduler](https://developer.android.com/reference/android/app/job/JobScheduler)
- [Android background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background)

## Release readiness

Settings → Getting started and privacy contains a reusable setup guide, permission/data explanations and troubleshooting. See [privacy](docs/PRIVACY.md), [device acceptance checklist](docs/FIELD_TESTING.md) and [release/distribution guide](docs/RELEASE.md). GPS/LoRa checkpoint writes coalesce waiting snapshots when storage is slow; stop drains the latest snapshot before saving. Message history buttons wrap on narrow screens and enlarged text.

CI now produces an optimized release-mode **test-signed candidate**, preserving updates over existing test installations. Production APK/App Bundle generation is separately opt-in and fails without owner-controlled signing secrets. Physical field acceptance, production key provisioning, store publication and merge after acceptance are pending; automated checks alone do not complete them.

## Live reception metadata

Radios → Start collecting provides an opt-in foreground live view of up to 200 reception reports (latest 20 shown), with UTC phone arrival time, signed RSSI, quarter-dB SNR, packet type and bounded routing metadata. Raw payloads, message contents and hashes are discarded. App switching stops this live list while preserving the connected radio and separately opted-in GPS recording. Start Mapping saves valid receptions associated with a recent GPS fix. Malformed/truncated reports are rejected before coverage association. Complete RF reports require MTU at least 179; the native adapter requests 185. This is framing validation, not authenticated sender identity or proof of delivery.

## Smart discovery and repeater details (1.5)

Recording settings offer opt-in smart discovery pinging: MeshCore command 7 with zero-hop advertisements, every 2/5/10 minutes at most, only while recording with the app open, a fresh accurate GPS fix, an identified idle radio and a known preset. Recently measured cells on that same preset are skipped using a configurable 7/14/30/90-day window. Planned routes and advertisements alone never count as measured coverage. A manual ping bypasses the coverage hold but retains the interval limit. The command uses the radio's existing advertised name/location policy; it does not update that location. Companion acceptance does not confirm another radio received it. Failures pause automatic pinging until reconnecting, and a command already written cannot be withdrawn.

Tap a repeater in Nodes to view its advertised identity/location and save site, hardware, antenna, transmit power, preset and notes by full public key. These details are user-entered, not verified administrator claims or radio configuration. They travel in encrypted backups and shared-folder sync. Diagnostics remain explicit radio commands.

## Automatic shared-folder synchronization (1.5)

Settings → Backup and storage offers a dedicated shared folder and a shared passphrase of at least 12 characters. Each phone publishes immutable encrypted snapshots of saved sessions, messages, waypoints and repeater details. Maps, device preferences, credentials and in-progress recordings stay local. Sync runs approximately once a minute while the app is open, idle and disconnected from the radio. It does not run in the background. The Android document provider must support persistent folder access, file creation and rename; provider support has not been physically verified. Some cloud apps do not expose usable folders in Android's picker.

Logical revisions and permanent deletion markers merge devices without resurrecting stale records. Concurrent changes pause automatic sync for review; applying the proposed merge requires an explicit choice and retains conflict alternatives locally for export. A failed publication never applies the incoming data locally. Edits and restores are blocked during maintenance. Each device retains its latest two successful snapshots; other devices' files are never removed. Use a dedicated folder, at most eight devices and 8,000 records including deletion markers. Each snapshot has a 20 MB plaintext limit. Changing a group's passphrase requires a fresh folder because old snapshots cannot be decrypted with the new passphrase.

Automated checks cover stale-device deletion, deterministic conflict merging, provider failure, background deferral, unchanged-data write avoidance, smart-ping pacing/cancellation and narrow screens at 200% text. Physical acceptance for two phones, document providers, background GPS, BLE, real-world vector packs, TalkBack, battery and performance remains pending. See the device checklist before treating a candidate as field-verified.
