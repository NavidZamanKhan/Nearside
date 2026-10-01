# Nearside Roadmap

## Overview

Nearside is an open-source, local-first cross-platform file and content sharing utility for macOS and Android (iOS subsequent). Nearside focuses on instantaneous, low-friction transfers without requiring users to navigate heavyweight application windows or establish cloud intermediaries.

## Milestones

### Milestone 0: Feasibility Probes (Completed)
- [x] E1: Android Receiver Feasibility on physical iQOO Neo9 (Android 16, SDK 36). Verified foreground service, mDNS/DNS-SD advertisement, TCP socket listener (latency: 36.9 ms to 51.7 ms), interactive notification Pause/Resume, and OriginOS cgroup sleep behavior.
- [x] E2: macOS Native Share Extension & Staging. Proved NSItemProvider sandbox lifetime boundary, eager staging coordinator, 64 KiB bounded chunk streaming (1326 MiB/s), resident app queue claiming, and offline fallback.
- [x] E3: Native Identity & Pairing Cryptography. Proved P-256 key generation, canonical ns1_<hex> SPKI hashing, pinned public-key trust store, QR transcript-bound pairing with constant-time HMAC-SHA256, and 8-digit short code PAKE with rate-limiting lockout.

### Milestone 1: Native Application Foundations (Current)
- [x] Protocol definitions and JSON test fixtures (framing, discovery, pairing, transfer, security).
- [ ] macOS native menu bar app shell with SwiftUI shelf popover, settings window, and Share extension target.
- [ ] Android native app shell with Jetpack Compose UI (device status, paired devices, history), resident receiver service, and native Sharesheet target activity.
- [ ] Verification on macOS host and connected physical iQOO Neo9 device.

### Milestone 2: Discovery and Pairing Subsystems
- [ ] Cross-platform mDNS/DNS-SD discovery engine (Apple Network.framework NWBrowser/NWListener and Android NsdManager).
- [ ] Visual QR code pairing workflow between macOS and Android.
- [ ] Numeric 8-digit short-code pairing with mutual key agreement and rate-limiting.
- [ ] Persistent device trust store on Keychain and Android Keystore.

### Milestone 3: Transfer Engine and Protocol Integration
- [ ] High-throughput TCP transfer engine with TLS/Noise session encryption.
- [ ] Bounded 64 KiB streaming with backpressure and resume support.
- [ ] Direct Sharesheet to Receiver pipe (zero-click handoff to trusted peers).
- [ ] macOS Finder Drag-and-Drop and Android Sharesheet end-to-end transfers.

### Milestone 4: Polish, Robustness, and Production Readiness
- [ ] Network interruption recovery and auto-reconnect.
- [ ] Power management optimization for background Android receivers.
- [ ] Final security audit, packaging, and release automation.
