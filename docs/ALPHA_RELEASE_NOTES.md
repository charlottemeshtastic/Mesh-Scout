# MeshScout v1.5.0-alpha

MeshScout is an independent Android application for MeshCore field observations and coverage mapping. This alpha introduces cyan eye/shield launcher branding, adaptive Android icons, and a full-logo startup screen using the supplied MeshScout artwork.

Existing radio, node discovery, messaging, mapping, offline maps, GPS recording, settings, backup and export implementation is retained. MeshMapper attribution and its full MIT notice are available in the app's open-source license viewer. MeshScout is not officially affiliated with MeshMapper or MeshCore.

## Download and installation

Download **MeshScout-alpha-debug.apk** and its SHA-256 checksum from the release assets. This is an **alpha DEBUG APK signed with the existing private test key**, not a production-signed or Play Store release. Back up your data first. The workflow uses the same private test signer as current candidate builds. If an older installation used another signer, Android can reject installation over an existing app. Export a backup before considering uninstalling an existing installation.

## Validation and limitations

The alpha workflow requires dependency resolution, Dart formatting, static analysis, Flutter tests, a debug APK build, and native Android unit tests to pass before publication. Automated checks do not establish physical device compatibility.

Bluetooth connectivity, radio firmware interoperability, GPS accuracy, background recording, launcher masks, splash appearance, offline-map imports, messaging and backup/restore need testing on physical Android devices. Background recovery cannot bypass force-stop or manufacturer restrictions. There is a small message-loss window before phone checkpoint durability. Automatic two-way cloud sync remains unfinished; manual cloud document backup and scheduled one-way encrypted backup remain available.

Report issues with phone model, Android version, radio firmware, steps and expected behavior. Remove private messages, coordinates and credentials from reports. Do not rely on alpha coverage observations for emergency communications.
