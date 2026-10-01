# Nearside

Nearside is an open-source, local-first cross-platform file and content sharing utility for macOS and Android (iOS subsequent). Nearside delivers the fast, seamless experience of AirDrop without cloud intermediaries, accounts, or telemetry.

## Features

- Native OS Integration: Sharesheet receiver on Android and Share Extension on macOS.
- Frictionless Handoff: Share directly from Finder or Android apps to paired peers.
- Local-First: Pure peer-to-peer TCP streaming over local Wi-Fi / LAN with mDNS discovery.
- Secure by Default: NIST P-256 cryptographic identity, SPKI SHA-256 fingerprint pinning, and QR/PAKE mutual authentication.
- Bounded Resource Footprint: 64 KiB streaming chunk pipeline with zero high-memory buffering.

## Repository Layout

```
Nearside/
  ├── apps/
  │   ├── android/       # Native Android application (Compose + Foreground Service)
  │   └── apple/         # Native Apple applications (macOS menu bar, Share Extension, iOS)
  ├── docs/              # Architecture, roadmap, product, and testing documentation
  ├── probes/            # Completed feasibility probes (E1 Android, E2 macOS, E3 Crypto)
  ├── protocol/          # Protocol specifications and JSON test fixtures
  └── scripts/           # Build and verification scripts
```

## Building and Running

### macOS Application
Build the macOS Menu Bar app and Share Extension:
```bash
./scripts/build_macos.sh
```

### Android Application
Build the debug APK:
```bash
cd apps/android
./gradlew assembleDebug
```
Install on a connected device:
```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Security

Nearside generates local P-256 keypairs and identifies devices by public key fingerprint (`ns1_<hex>`). Devices pair visually via QR code or an 8-digit numeric verification code. Once paired, trust anchors are pinned in hardware-backed storage.
