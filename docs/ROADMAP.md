# Nearside Roadmap

## Overview

Nearside is an open-source, local-first cross-platform file and content sharing utility for macOS and Android (iOS subsequent). Nearside focuses on instantaneous, low-friction transfers without requiring users to navigate heavyweight application windows or establish cloud intermediaries.

## Milestones

### Milestone 0: Feasibility Probes (Completed)
- [x] E1: Android Receiver Feasibility on physical iQOO Neo9 (Android 16, SDK 36). Verified foreground service, mDNS/DNS-SD advertisement, TCP socket listener (latency: 36.9 ms to 51.7 ms), interactive notification Pause/Resume, and OriginOS cgroup sleep behavior.
- [x] E2: macOS Native Share Extension & Staging. Proved NSItemProvider sandbox lifetime boundary, eager staging coordinator, 64 KiB bounded chunk streaming (1326 MiB/s), resident app queue claiming, and offline fallback.
- [x] E3: Native Identity & Pairing Cryptography. Proved P-256 key generation, canonical ns1_<hex> SPKI hashing, pinned public-key trust store, QR transcript-bound pairing with constant-time HMAC-SHA256, and 8-digit short code PAKE with rate-limiting lockout.

### Milestone 1: Native Application Foundations (Completed)
- [x] Protocol definitions and JSON test fixtures (framing, discovery, pairing, transfer, security).
- [x] macOS native menu bar app shell with SwiftUI shelf popover, native AppKit preferences window, and Share extension target.
- [x] Android native app shell with Jetpack Compose UI (device status, paired devices, history), resident receiver service, and native Sharesheet target activity.
- [x] Automated end-to-end verification across platforms.

### Milestone 2: Discovery and Pairing Subsystems (Completed)
- [x] Cross-platform mDNS/DNS-SD discovery engine (Apple Network.framework NWBrowser/NWListener and Android NsdManager).
- [x] Visual QR code pairing workflow between macOS and Android (nearside://pair URI format, CoreImage CIQRCodeGenerator, HKDF-SHA256 transcript derivation, and constant-time HMAC-SHA256 verification).
- [x] Numeric 8-digit short-code pairing with mutual P-256 ECDH key agreement and 5-attempt rate-limiting lockout.
- [x] Persistent device trust store with atomic disk persistence, canonical ns1_<hex> SPKI hashing, and peer blocking.

### Milestone 3: Transfer Engine and Protocol Integration (Completed)
- [x] High-throughput TCP transfer engine with encrypted sessions and JSON manifest/ack exchange.
- [x] Bounded 64 KiB chunk streaming with flow control backpressure, resume support, and SHA-256 chunk validation.
- [x] Direct Sharesheet to Receiver pipe (zero-click handoff to trusted peers).
- [x] macOS Finder Drag-and-Drop and Android Sharesheet end-to-end transfers.

### Milestone 4: Polish, Robustness, and Production Readiness (Completed)
- [x] Network interruption recovery, chunk-level resume protocol, and exponential backoff retry.
- [x] Power management optimization for background Android receivers (reference-counted wake/wifi locks, live notifications).
- [x] Path traversal security defense and zero-leak security audit.
- [x] Production release packaging automation (macOS DMG and optimized Android release APK).

### Milestone 5: Native iOS Platform Port & Share Extension (Completed)
- [x] Multiplatform shared core alignment across macOS and iOS (`UIDevice` device naming, sandbox Documents storage).
- [x] Native iOS SwiftUI application shell (`NearsideHomeView`, `NearsideSettingsView`, and `NearsideIOSApp`).
- [x] Native AVFoundation camera QR scanner (`QRPairingScannerView`) with 8-digit numeric PAKE short code fallback.
- [x] Native iOS Share Extension target (`ShareViewController` + `IOSShareRecipientPickerView`) with eager attachment staging.
- [x] Automated iOS build pipeline (`scripts/build_ios.sh`), test harness (`Milestone5Tests.swift`), and full multiplatform verification (`scripts/verify_milestone5.sh`).


