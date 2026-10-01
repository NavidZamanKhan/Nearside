# Nearside Testing & Verification Strategy

## 1. Automated Test Suites

### 1.1 macOS Feasibility & Unit Harnesses
- Probe E2 Harness: Validates NSItemProvider staging, bounded streaming (64 KiB), offline queue claiming, and manifest creation. Run with `./scripts/test_macos_e2.sh` or Swift test harness.
- Probe E3 Harness: Validates NIST P-256 identity generation, SPKI fingerprinting, trust store persistence, QR transcript authentication, and PAKE short-code rate-limiting. Run with `./scripts/test_crypto_e3.sh`.

### 1.2 Android Automated Checks
- Unit and instrumented tests run with `./gradlew test` and `./gradlew connectedCheck` from `apps/android/`.

## 2. Hardware Test Protocol

- Test Hardware:
  - macOS arm64 host (development workstation)
  - Physical Android device (iQOO Neo9, Android 16 / SDK 36, connected over USB adb)
- Verification Checklist:
  1. Menu bar icon displays receiving state pill on macOS.
  2. Main window on macOS displays local identity fingerprint and paired devices list.
  3. Share Extension opens recipient picker sheet when invoked from Finder.
  4. Android app launches with Material 3 Jetpack Compose layout.
  5. Android foreground service displays persistent notification with interactive Pause and Resume controls.
  6. Android Sharesheet displays Nearside when sharing images or documents from external apps.
