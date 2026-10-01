# Nearside Protocol Specification: Discovery & Presence

This document defines peer discovery using multicast DNS (mDNS) and DNS Service Discovery (DNS-SD).

## 1. Service Type

Nearside peers advertise their presence on the local link using:

- Service Type: `_nearside._tcp`
- Domain: `local.`
- Transport: TCP

## 2. TXT Record Key-Value Parameters

The DNS-SD TXT record conveys essential identity and presence metadata without requiring an active connection:

| Key  | Format               | Description                                                        |
|------|----------------------|--------------------------------------------------------------------|
| v    | Integer (e.g. "1")   | Protocol version number                                            |
| id   | Hex string (32-64c)  | Public fingerprint of device identity (ns1_<prefix>)               |
| name | UTF-8 String (<=64c) | Human-readable device display name (e.g. "MacBook Pro", "iQOO Neo") |
| os   | String               | Platform identifier ("macos", "android", "ios", "windows", "linux")|
| pair | "0" or "1"           | Whether device is currently accepting new pairings                 |
| recv | "0" or "1"           | Whether device is currently receptive to incoming transfers        |

## 3. Instance Naming Convention

Service instance names follow the pattern:
`Nearside-<DeviceName>-<ShortFingerprint>`

Example: `Nearside-MacBookPro-7A3F`

## 4. Privacy & Power Considerations

- Fingerprints in TXT records allow paired devices to recognize known peers immediately.
- Receivers in paused or sleep modes advertise `recv=0` or unregister the service completely.
- Mobile platforms (Android) unregister or throttle advertisements when locked in deep sleep to conserve battery.
