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
