# MeshScout 1.0

Independent Android MeshCore field-mapping app. MeshScout has no BackCountrySignal integration, shared data, account or application code. Android APKs are test builds; real-device acceptance remains necessary.

## What is implemented

Bottom navigation exposes Map, Radios, Nodes, Coverage, History and Settings. Explicit BLE scanning allows immediate selection of an advertised UART candidate. Connection validates characteristics, negotiates MTU and identifies the MeshCore companion before enabling commands. Identification changes no radio configuration. A connected-device foreground service and bounded reconnect attempts support app switching; Android/OEM process termination can still end the link. Reconnect targets are not restored after process death.

Nodes refresh validates the complete contact stream before publishing it. Advertised positions are separate from actual GPS-tagged LoRa reception observations. Nodes → Manage contacts, channels and diagnostics adds:

- Contact add/edit/delete, JSON export and reviewed import (up to 5,000 contacts per import). Edits retain path/flags/location; public keys identify contacts and cannot be edited. Import updates matching keys and retains other contacts. Radio mutations can partially complete if the link fails; no automatic rollback or retry.
- A bounded list of newly heard candidates from firmware NEW_ADVERT pushes, with optional explicit Import. Firmware may auto-store advertisements itself; refresh the radio table to see those. No background probe scanning or silent table import.
- Explicit path discovery, status/reachability requests, telemetry requests, repeater login and CLI commands. Companion acceptance does not prove remote success. Replies are matched to the requested public-key prefix, live connection generation and a 60-second display window. Missing replies leave reachability unknown. Paths show repeater hashes, which are not unique identities. Standard/extended Cayenne sensor values are decoded; unknown types and status fields remain raw.
- Channel creation/replacement by reported slot index, 31-byte name and a supplied/generated 128-bit key. Keys are shown for explicit provisioning, never read from existing channels, stored in history, or included in backups. Preserve a newly generated key securely before closing the dialog.
- Frequency, bandwidth, spreading factor, coding rate and explicit client-repeat selection, in addition to name, power and clock controls on Radios. Firmware validates radio parameters; user-selected frequency/region and mesh compatibility remain the user's configuration. Client repeat needs firmware support. Changing settings can interrupt mesh communication.

All companion commands share the existing operation lock. Commands exceeding negotiated MTU are rejected before writing. Uncertain writes/replies require reconnecting and are never automatically repeated. Repeater passwords and outgoing CLI commands are not saved. Queued CLI responses are manually fetched in Messages and clearly labeled.

Messages supports direct/channel text, manual queue retrieval, local atomic persistence and JSON/CSV export. A live matching ACK confirms direct delivery; companion OK only confirms channel acceptance. No automatic sends or queue drain. Fetch removes each message from the companion before the app persists it; process failure in that interval can lose a message. Notification alerts are opt-in. Histories contain private text/location data in Android app-private storage.

## Mapping and field tools

GPS recording, completed sessions, names, GeoJSON/CSV export and fresh GPS-associated raw LoRa reception observations remain available. Background GPS is optional, starts while visible, uses a location foreground service and checkpoints GPS fixes. Process interruption recovers GPS geometry, not unsaved LoRa observations.

Coverage → Summaries, comparisons, waypoints and route import provides side-by-side summaries of two sessions, route distance, mean/range RSSI, mean SNR and sample counts. Measured signal bars group observations in 0.001° cells; cell size varies with latitude. Cells without observations have no inferred coverage. Raw LoRa metrics are last-hop reception, not verified sender identity or proof of two-way coverage.

Waypoints and notes persist privately, appear as cyan flags on Map and can be deleted with confirmation. Up to 1,000 waypoints; names up to 80 characters, notes up to 2,000. GeoJSON route import accepts a WGS84 LineString or exactly one LineString in a FeatureCollection, 2–10,000 points. Imported geometry is labeled as a planned route with no reception observations; imported timestamps/accuracy are unknown. Exports mark planned points explicitly and omit their measurement timestamps/accuracy. GPX import is not included.

## Offline maps

Up to five separate named areas can be selected, renamed or deleted. USGS downloads support contiguous-U.S. 4/8/12 km areas at zoom 12–16 and 24/48 km areas at zoom 10–14. Downloads are capped at 5,000 tiles / 150 MB per area, bounded and throttled; online OpenStreetMap tiles are never bulk downloaded.

Pause or a failed download retains private staging. Resume verifies completed image signatures and reuses those tiles. Starting a different area discards the paused staging after validation. Completed areas publish only after all tiles and metadata are saved; older areas remain available.

Import raster MBTiles supports worldwide and larger regions from user-provided PNG/JPEG packs, up to 500 MB, 50,000 tiles, zoom 0–22. Native SQLite reads TMS rows and converts them to XYZ file tiles. Raster bounds are checked before publication. Vector/PBF MBTiles and global automatic tile downloads are unsupported. Use map packs whose provider permits download and use. Map attribution/license information should be retained with the source pack. Offline mode makes no basemap network requests; outside a saved pack the basemap is absent.

## Backup, merge and cloud document

Legacy JSON backup/restore remains compatible. Settings → Full backup supports a version-2 ZIP bundle containing completed routes, observations, message history, waypoints/notes and reconnect/background-GPS preferences. Saved raster maps are optional (maximum 500 MB / 50,000 entries and five areas). Radio secrets, notification grants, cloud-provider permissions, scheduling secrets and in-progress recordings are excluded.

Encryption uses PBKDF2-HMAC-SHA256 (150,000 iterations, random 128-bit salt) and AES-256-GCM authenticated 64 KiB records, distinct indexed nonces and an authenticated terminal record. A 12-character minimum passphrase is required for encryption. Missing/tampered/reordered records, trailing bytes and wrong passwords reject the entire file before extraction or restore. Keep the passphrase: the app cannot recover it.

Restore first stages bounded entries in private storage, rejects unexpected paths and validates the data, waypoint/map limits and raster images. A preview offers Cancel, Merge or Replace. Merge keeps current session/waypoint IDs and preferences, deduplicates messages by radio/peer/time/direction/body and adds map areas up to the five-area limit. ID collisions keep the current record. Replace restores included history/preferences/maps. Data and included maps publish through one atomic private profile pointer. Maps omitted from a backup remain referenced by the restored profile. Old profiles remain private to preserve referenced maps; repeated restores may use additional disk space.

Stop recording/downloads, wait for saves and disconnect the radio before backup/restore. Reconnect/background-GPS preferences persist and are applied after restore. Restored notification permissions are never silently granted.

Cloud backup uses Android's Storage Access Framework. Choose a **dedicated backup document** in an installed cloud provider (or local storage). Explicit Upload overwrites that document; Download previews before merge/replace. Document-provider access is user-granted and provider-dependent. Provider failure during overwrite can leave the remote file incomplete, so keep a separate local backup. This is manual document synchronization, not automatic two-way merge or a MeshScout account.

Daily encrypted backups are explicitly enabled after choosing a target. Android JobScheduler runs them while charging and online, approximately daily and potentially delayed. GPS recording defers the job. The scheduling passphrase is protected by Android Keystore on this phone, excluded from portable backups, and removed when scheduling is disabled. Settings displays the latest job status. Re-enable scheduling on a restored/new phone; no provider URI is restored from a bundle.

## Build verification and limits

CI pins Flutter 3.47.7, compile SDK 37, AGP 9.2.1, Gradle 9.4.1 and Java 17. It preserves owned Android sources, enforces the lockfile, formatting and strict analysis, runs Dart tests with coverage, builds a debug APK with the stable private test signer, then runs JVM backup-authentication tests. No private signing key is committed. Updates over 0.2.1+ retain data; production signing/store release is separate work.

Tests cover protocol validation, stream sequencing, reconnect cancellation, GPS association/persistence, backup validation/merge, diagnostic decoding, failed-download retention and reuse on resume, plus native encryption roundtrip, wrong password, truncation and tampering. CI success establishes software checks and APK compilation; it does not establish real BLE firmware interoperability, Android document dialogs, Keystore behavior on every OEM, large MBTiles imports, background service survival or cloud-provider/job timing. These require physical phone/radio testing.

## Sources

- [MeshCore companion firmware](https://github.com/meshcore-dev/MeshCore/blob/main/examples/companion_radio/MyMesh.cpp)
- [Official companion protocol](https://github.com/meshcore-dev/MeshCore/blob/main/docs/companion_protocol.md)
- [Cayenne telemetry data types](https://github.com/ElectronicCats/CayenneLPP/blob/1.6.1/src/CayenneLPP.h)
- [MBTiles 1.3 specification](https://github.com/mapbox/mbtiles-spec/blob/master/1.3/spec.md)
- [Android document access](https://developer.android.com/training/data-storage/shared/documents-files)
- [Android JobScheduler](https://developer.android.com/reference/android/app/job/JobScheduler)
- [Android background BLE](https://developer.android.com/develop/connectivity/bluetooth/ble/background)
