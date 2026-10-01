# Nearside Architecture Specification

## 1. System Overview

Nearside is organized into native client implementations for macOS (`apps/apple/macOS`), iOS (`apps/apple/iOS`), and Android (`apps/android`), unified by a shared protocol specification (`protocol/`).

```
+-------------------------------------------------------------+
|                      User Interactions                      |
|  - macOS Share Extension        - Android Sharesheet Target |
|  - Menu Bar Quick Shelf Popover - Jetpack Compose Home App  |
+-------------------------------------------------------------+
                              |
+-------------------------------------------------------------+
|                    Nearside Native Core                     |
|  - Device Identity & P-256 Keypair                          |
|  - Pinned Device Trust Store                                |
|  - Discovery Coordinator (mDNS / DNS-SD)                    |
|  - Transfer Engine & Stream Coordinator                     |
+-------------------------------------------------------------+
                              |
+-------------------------------------------------------------+
|                     Local Network (TCP)                     |
|  - Direct Peer-to-Peer Wi-Fi / Local Area Network           |
|  - Framed binary / JSON protocol (Magic: NS)                |
+-------------------------------------------------------------+
```

## 2. Platform Architecture: macOS

### 2.1 Host Application (`Nearside.app`)
- Menu Bar item (`NSStatusItem`) managing resident status and quick shelf popover.
- SwiftUI interface providing device status, paired peers list, transfer history, and preferences.
- Foreground TCP listener server accepting incoming stream connections.
- Persistent trust store stored in macOS Keychain.

### 2.2 Share Extension (`NearsideShare.appex`)
- Sandboxed App Extension target loaded into macOS sharing services.
- Eager Staging Coordinator: copies or stages security-scoped URLs before host system invalidates `NSItemProvider` callbacks.
- Communicates with resident host application via App Group container or local socket handoff.

## 3. Platform Architecture: Android

### 3.1 Main Application (`com.nearside.app`)
- Single Activity architecture using Jetpack Compose and Material 3 design tokens.
- Displays device identity (fingerprint `ns1_...`), trust management, and receiving controls.

### 3.2 Foreground Service (`NearsideReceiverService`)
- Runs foreground service with `connectedDevice` / `dataSync` type.
- Maintains ongoing status notification with interactive Pause and Resume actions.
- Binds TCP server socket to receive inbound transfers.
- Honors Android cgroup power-saving characteristics by honestly advertising receiving readiness.

### 3.3 Share Receiver Activity (`ShareTargetActivity`)
- Registered with `ACTION_SEND` and `ACTION_SEND_MULTIPLE` intent filters.
- Presents a fast bottom-sheet picker of nearby paired peers.
- Streams content directly or hands off to background transfer engine.
