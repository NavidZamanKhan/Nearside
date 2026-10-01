# Nearside Product Specification

## 1. Product Vision

Nearside delivers the native feel of Apple AirDrop or Quick Share across macOS and Android. File and content transfer must feel instantaneous and non-intrusive.

### Core Value Proposition
- Native OS Integration: Nearside operates as a system service and share extension target. Sending files does not require opening an application window.
- Frictionless Direct Transfer: "Share -> Nearside -> Paired Device -> Done."
- Privacy and Local-First: Zero cloud servers, zero telemetry, zero accounts. Direct Wi-Fi / LAN transport encrypted end-to-end.
- Resilient Battery Footprint: Low idle consumption. Honest presence advertisement respecting mobile sleep cycles.

## 2. User Scenarios

### Scenario A: Sharing from macOS to Android
1. User right-clicks a 4 GB video in Finder -> Share -> Nearside (or drops onto Menu Bar icon).
2. Nearside shows available paired devices (e.g. "iQOO Neo9").
3. User clicks device. Staging coordinates file handles and streams chunks directly over TCP.
4. Android device receives chunks in foreground service, saves file to Downloads, and displays completion notification with "Open" action.

### Scenario B: Sharing from Android to macOS
1. User views photos in Gallery -> Share -> Nearside.
2. Android Sharesheet displays paired macOS laptop.
3. User taps laptop. Chunks stream directly over local Wi-Fi.
4. macOS receives file into Downloads folder and displays notification banner.

### Scenario C: Device Pairing
1. User clicks "Pair New Device" on macOS or Android.
2. Device displays QR code containing session identifier and ephemeral public key.
3. Peer scans QR code using in-app camera or enters 8-digit numeric verification code.
4. Mutual public keys are pinned to trusted storage. Future transfers between these devices require zero pairing steps.
