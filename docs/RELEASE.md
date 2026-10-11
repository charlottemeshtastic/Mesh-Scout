# Release and distribution

## Candidate versus production

CI builds an optimized, non-debug release APK candidate with the **existing private test signer** so it can update installed MeshScout test builds without deleting data. A release-mode candidate is not a production-signing approval or store publication. CI publishes downloadable build artifacts, not a public store listing.

Production release builds require owner-controlled PKCS12 signing material in encrypted repository secrets:

- MESHSCOUT_RELEASE_KEYSTORE_BASE64
- MESHSCOUT_RELEASE_STORE_PASSWORD
- MESHSCOUT_RELEASE_KEY_ALIAS
- MESHSCOUT_RELEASE_KEY_PASSWORD

Run Android CI manually with `production` enabled after reviewing the exact commit and completing the field checklist. It produces an APK and Android App Bundle. Missing signing configuration fails the release rather than silently using a test key. No signing material belongs in source, issues, email or this guide. Protect and back up the production key before publication. A different signer cannot install over the current test-signed app; export a full encrypted backup, uninstall the test app and restore into the production app if switching identities. App-store signing and first publication require owner review and store credentials.

## Required acceptance

Record the APK version, signer, SHA-256, source commit and passing CI URL. Run FIELD_TESTING.md on supported phones/radio firmware. Fix reproducible failures and repeat affected checks. Review privacy/help content and licenses. Review PR #3, complete field acceptance and merge only once the release is ready. A passing automated build cannot substitute for BLE, battery/OEM, document-provider or device accessibility testing.

## Install and update

Download the APK only from the project's verified build or supplied Drive link. On Android, open it and permit installation for that source when prompted. Candidate updates use the same test signer; install over the prior version to retain app data. Back up before updating. Do not uninstall to solve a signature mismatch until you have exported data. The owner may distribute the reviewed APK directly or use a store-signed App Bundle; neither distribution is automatically performed by CI.

## Known residual limitations

Android background recovery is best effort and cannot bypass force-stop or OEM restrictions. A fetched queue item can be lost before its phone checkpoint is durable. Vector map rendering and automatic two-way cloud sync are separate unfinished feature extensions; GeoJSON planned routes, raster MBTiles and manual cloud document backup remain available.
