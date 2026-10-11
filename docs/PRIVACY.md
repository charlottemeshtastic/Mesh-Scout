# MeshScout privacy information

MeshScout is an independent Android MeshCore application. It has no MeshScout account, advertising SDK or analytics SDK and shares no data or accounts with BackCountrySignal.

## Stored on the phone

App-private storage contains precise GPS routes and reception times, received signal observations, message text and conversation state, public radio contacts, preferred radio identifiers, preferences, waypoints/notes and saved map tiles. Recovery checkpoints temporarily hold an unfinished route or fetched message. Restore can retain old private profiles until Settings → Storage cleanup removes unreferenced profiles. Android system backup is disabled in the manifest.

Radio channel keys, repeater passwords and outgoing CLI commands are not included in history or portable backups. If you enable scheduled encrypted backup, its passphrase is protected by Android Keystore on that phone and removed when scheduling is disabled. An exported encrypted backup requires its passphrase; MeshScout cannot recover it.

## Network and recipients

Online OpenStreetMap tile requests disclose your network address and the viewed tile coordinates to that service. USGS receives requested offline tile areas. Offline mode makes no basemap requests. MeshScout does not send GPS tracks or messages to an application server. A selected Android cloud document provider handles uploads/downloads, its account and network connections according to that provider's policy. Bluetooth operations and mesh messages go to the radio you select.

## Permissions and choices

Bluetooth supports scanning and connection; precise location supports recording. Optional notifications alert you to waiting messages. Optional location foreground service continues a recording you start while visible. Android document dialogs grant access to selected files. Preferences do not grant permissions. Manage permissions in Android settings.

Delete sessions, messages, notes and maps individually, or use confirmed storage cleanup. Export or back up first if needed. Uninstall removes app-private files. Exports, shared files and provider documents remain at their destinations and must be deleted there. Revoke cloud document access by removing its target or through the provider/system settings.

## Reporting issues

Use the repository issue tracker: https://github.com/charlottemeshtastic/Mesh-Scout/issues. Remove private message text, exact coordinates, passwords, channel keys and signing material from public reports. This document describes the repository's implemented behavior; device and provider behavior still needs field validation.

## Shared-folder sync and discovery

Opt-in sync uploads encrypted saved sessions, messages, waypoints and user-entered repeater details to the chosen document-provider folder. The shared passphrase is protected by Android Keystore on this phone and excluded from portable backups. Other devices with folder access and the passphrase can read those records. Deletions propagate as permanent markers; older retained snapshots, conflict alternatives and private restore profiles can still contain prior values. Deleting a record does not securely erase every copy. Maps, radio secrets, device preferences and in-progress recordings are excluded from sync. Sync runs only while the app is foreground, idle and disconnected. Cloud provider permissions and behavior remain provider-dependent.

Opt-in smart discovery sends zero-hop advertisements with the radio's current advertised identity and location policy. It does not set or hide the radio's advertised location, and does not claim confirmed reception or measured coverage.
