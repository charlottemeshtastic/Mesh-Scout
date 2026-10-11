# Device acceptance checklist

Status: **pending physical testing**. Automated tests verify code behavior with fakes and JVM helpers. Do not mark a row passed until it is exercised on the named device/radio.

Record build/version, phone model, Android version, radio model/firmware, date and tester. Use a backed-up test dataset. Record pass/fail, observed result and issue link for every row.

| Check | Procedure and expected result | Status |
|---|---|---|
| Immediate connection | Scan and select the first advertised radio without waiting for scan timeout; connected state appears after identity validation. | Pending |
| App switching | Connect, switch apps for 10 minutes, return; show actual live connection or visible bounded recovery. | Pending |
| Reconnect | Move radio out of range and back; retry up to five times, no duplicate sends. Manual disconnect cancels retries. | Pending |
| Process interruption | Interrupt the app through Android/system conditions; reopen, recover latest durable route/message once and reconnect only with saved preference. Force-stop recovery is not promised. | Pending |
| Locked-screen GPS | Start outdoors with background GPS enabled; lock for 30 minutes, stop/save; route and associated observations are present. Repeat battery saver and OEM settings. | Pending |
| Message delivery | Direct ACK and channel acceptance are distinct. Fetch, read, delete, restart and verify unread/history. Fill history and verify clear limit feedback. | Pending |
| Alerts | Opt in/out, receive waiting-message event, open notification with an existing draft and ensure one Messages screen without losing the draft. | Pending |
| Radio controls | On a compatible test radio, verify contacts, channels, name/power/clock, advanced settings and repeater replies. Restore original configuration. | Pending |
| Offline maps | Download two areas, pause/resume, switch, delete and import licensed raster and OpenMapTiles vector packs. Rename/switch both, restart, and restore an encrypted full backup with both formats. Disable connectivity and verify roads, water and place names; outside pack no basemap. | Pending |
| Backup and restore | Encrypted roundtrip and merge/replace; cancel preview, reject wrong password/corruption; recover after app restart. Verify maps and preferred radio. | Pending |
| Cloud provider | Use a dedicated test document, upload, download/preview; test denied access and offline/provider failures without damaging local history. | Pending |
| Shared-folder sync | On two phones, use a dedicated supported folder and common passphrase. Create/edit/delete on each; review conflicts, reconnect a stale phone without resurrecting deletions, and test offline/denied/rename failures. Background sync must defer. | Pending |
| Smart discovery | Verify opt-in zero-hop advertisements, interval limit, recent measured-cell/preset holds, fresh GPS requirement, stop/background cancellation and reconnect after an uncertain failure. Acceptance must not create measured coverage. | Pending |
| Repeater details | Save distinct full-key entries sharing a short prefix; restart, sync, encrypted backup/restore and verify details. They must be labeled user-entered. | Pending |
| Scheduled backup | Enable while charging/online; inspect actual job status and decrypt resulting file. Disable and verify no later job. Timing is approximate. | Pending |
| Storage | Back up first; prune, delete paused staging and retired profiles; active/referenced maps remain usable after restart. | Pending |
| Heavy traffic | Long route with frequent LoRa reception, large history and large maps; check responsiveness, saved counts, memory, storage and battery. | Pending |
| Accessibility | TalkBack traversal/labels, 200% text, smallest supported screen, landscape, large keyboard and all dialogs; reachable actions without clipping. | Pending |
| Update | Install candidate over prior test-signed version; saved data remains and no permissions are granted silently. | Pending |

A field-test pass is specific to the recorded hardware and configuration. Include unresolved failures in the release notes; do not label unknown behavior as working.
