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
