# Discovery Subsystem Diagnostics

## 1. Overview

The Discovery subsystem advertises the local Nearside receiver via mDNS/DNS-SD (`_nearside._tcp`) and browses for nearby peers on the local subnet.

- Apple: [`DiscoveryService.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Discovery/DiscoveryService.swift) using Network.framework `NWListener` and `NWBrowser`.
- Android: [`NsdDiscoveryService.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/discovery/NsdDiscoveryService.kt) using Android `NsdManager`.

## 2. Relevant Error Codes

- `NS-DISC-001`: Discovery service registration / advertisement failed.
- `NS-DISC-002`: Discovery scanner / browser failed to start.
- `NS-DISC-003`: DNS-SD service resolution failed.

## 3. Diagnostic Logging

```
level=INFO subsystem=discovery operation=setupListener state=advertising port=41433 msg="Discovery listener bound"
level=INFO subsystem=discovery operation=setupBrowser state=browsing msg="Starting mDNS browser for _nearside._tcp"
level=ERROR subsystem=discovery operation=setupListener state=failed errorCode=NS-DISC-001 underlying="POSIXError(EADDRINUSE)" msg="Discovery listener failed"
```

## 4. How to Diagnose Discovery Failures

1. If devices cannot find each other:
   - Check if both devices are on the exact same Wi-Fi network and subnet.
   - On iOS / macOS: Ensure Local Network permission is granted in System Settings.
   - On Android: Ensure Wi-Fi multicast lock is acquired and device is not in deep cgroup sleep (`recv=0` advertised).
2. If `NS-DISC-001` occurs:
   - Port 41433 is in use by another instance or stale process.
   - Check `lsof -i :41433` on macOS or restart service on Android.

## Identity aliases and endpoint freshness

Android tracks service registrations separately from persistent `ns1_` device identities.
The newest resolved registration supplies each peer's endpoint. Losing one alias leaves
other registrations active; losing the last alias removes the peer. Late resolution
callbacks after loss or browser restart are discarded. Empty discovery snapshots also
clear the UI and mark absent paired devices unreachable. UI rows deduplicate by identity,
never by display name.

`NS-DISC-003` also identifies a registration without a valid persistent TXT identity,
an NSD resolution failure, or inability to start resolution. Android resolution records
carry a `disc_` correlation ID and safe native error information. DNS-SD host and port
resolution take precedence over advertised TXT IP hints. Stopping/restarting discovery
clears the global endpoint cache. Apple callbacks from superseded browsers are ignored,
and service endpoints remain available for fresh DNS resolution on each connection.

Android also invalidates service aliases and pending resolutions when its default network
or link addresses change. It restarts browsing and refreshes advertisement after a 300 ms
debounce; loss clears the visible/global cache immediately. The network callback is
unregistered when discovery stops. `NS-DISC-002` reports unavailable network monitoring.

Resolution waits are capped at three seconds for the visible cache. Android 14+ cancels
native resolution when stopping or timing out. Older Android versions retain the native
in-flight slot until its terminal callback, while discarding its stale registration data,
to avoid flooding subsequent peers with `ALREADY_ACTIVE` errors. Transfer discovery
refresh still has its own two-second deadline on every supported version.

## Trusted peer presence on Apple platforms

`PeerPresenceSnapshot` reconciles each live discovery snapshot against enrolled identities.
Enrollment starts offline. A valid discovery record must have the same `id` and `ns1_`
fingerprint as the trusted record to bring that identity online. Multiple announcements
collapse by identity, using the latest endpoint hint. Discovery cannot rename an enrolled
peer, establish trust, or merge two identities with the same display name. Losing discovery
marks the existing trusted row offline; its next announcement updates that same row.

The macOS shelf separates **Trusted Devices** from **Available Nearby**. Only trusted,
online, unblocked peers can receive content through shelf buttons, per-device drops, or
the shared recipient picker. The recipient is checked again when the action runs.
`NS-DISC-003`, operation `shelfSend`, with a fresh correlation ID identifies a selected
recipient that disappeared while a file chooser or drop was in progress.

An Android reinstall creates a different enrollment identity. The older entry remains
trusted and offline until the user confirms **Unpair** for that specific fingerprint.
Trust removal is saved before the device list changes. A storage failure retains the
original trust relationship, reports `NS-TRUST-004` with operation `unpairDevice`, and
shows a retry message. No name-based trust cleanup takes place.

Regression verification: `bash scripts/verify_peer_presence.sh` covers initial offline
state, exact identity matching, multiple aliases, same-name identities, disappearance,
reappearance, receiving paused, and durable removal of only the selected peer.
`bash scripts/verify_app_state_presence.sh` exercises the actual AppState integration,
including blocked recipient exclusion and failed unpair rollback. These tests inject
temporary trust files and ephemeral test keys with discovery disabled. Its optional
`--render-shelf` argument produces an offscreen native preview at the shelf's actual
350 by 420 point size under `build/app-state-presence-tests/ShelfPreview.png`.

Manual macOS checks:

1. Launch with a previously enrolled phone unavailable. Its trusted row is gray and
   offline; Clipboard, Send, and per-device drop are disabled.
2. Start that phone on the same Wi-Fi network. The existing identity row becomes green
   and online. Quit or disconnect the phone and verify the row returns to offline.
3. With two enrolled identities sharing a phone name, keep only the current installation
   running. Only its fingerprint becomes online. Cancel Unpair for the older fingerprint
   and verify both pins remain, then confirm removal and restart to verify persistence.
4. Display **Pair Device / Show QR** directly from the shelf. Use the phone's Scan QR
   action to pair, then verify the phone appears under Trusted Devices. A nearby Pair
   action displays a QR session restricted to the selected cryptographic identity.
5. Keep an unpaired nearby phone present. It shows Pair under Available Nearby and is
   excluded from every transfer recipient picker until enrollment succeeds.
6. Turn Receiving off from the shelf, then enable it in Preferences. Confirm discovery
   and the receiver restart, then pair using the newly displayed QR. Repeat with the
   iOS Home and Settings receiving switches.
7. Keep a file transfer active while another device attempts an invalid QR exchange.
   Its progress and busy indicator must remain intact. Regenerate a QR and dismiss an
   older pairing window; the newly displayed session must remain available.
