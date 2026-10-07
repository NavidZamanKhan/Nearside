# Nearside Diagnostic Foundation

## 1. Overview

Nearside includes a unified diagnosability architecture across macOS, iOS, and Android. The goal of this architecture is to make every failure immediately understandable without reverse-engineering the codebase.

When a failure occurs, the diagnostic logs and records provide:
- **Subsystem**: Which component encountered the issue (`transfer`, `discovery`, `pairing`, `trust`, `connection`, `protocol`, `verification`, `storage`).
- **Operation**: The exact operation being performed (e.g. `performSendAttempt`, `handleInboundConnection`, `setupListener`).
- **State**: The state of the state machine at the moment of failure (`connecting`, `negotiating`, `transferring`, `verifying`, `retrying`).
- **Nearside Error Code**: A stable canonical identifier from the [Error Code Registry](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/ERROR_CODES.md) (e.g. `NS-TRANSFER-001`, `NS-VERIFY-002`).
- **Correlation ID**: A stable identifier (`transferId`, `pairingSessionId`, `connectionId`) linking all logs across the operation's lifecycle.
- **Underlying Cause**: The wrapped native OS/framework error (`NWError`, `POSIXError`, `SocketException`, `IOException`).
- **Retry Diagnostics**: Clear records of attempt counts and backoff delays.

---

## 2. Core Diagnostic Components

### 2.1 NearsideErrorCode
An authoritative enum representing all known failure conditions. Each error code follows the stable format:
```
NS-[SUBSYSTEM]-[NUMBER]
```
Codes are defined in:
- Swift: [`NearsideDiagnostics.swift`](file:///Users/navidzamankhan/Code/Nearside/apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift)
- Kotlin: [`NearsideDiagnostics.kt`](file:///Users/navidzamankhan/Code/Nearside/apps/android/app/src/main/java/com/nearside/app/diagnostics/NearsideDiagnostics.kt)

### 2.2 NearsideError
A structured error type preserving both the high-level Nearside classification and the low-level native error:
```swift
NearsideError(
    code: .transferRetryExhausted,
    operation: "executeAttempt",
    message: "Transfer failed after 3 attempts",
    underlyingError: nwError,
    correlationId: "tx_8f912a",
    retryCount: 3
)
```

### 2.3 NearsideLogger
Structured, leveled logging (`DEBUG`, `INFO`, `WARN`, `ERROR`):
```swift
NearsideLogger.shared.info(
    "transfer",
    "sendFiles",
    "Initiating outbound transfer with 2 items",
    state: "starting",
    correlationId: "tx_8f912a",
    metadata: ["totalBytes": "1048576"]
)
```

### 2.4 Privacy Redaction (`NearsideRedactor`)
Strict privacy rules protect user data:
- Private keys, session secrets, and passwords are never logged.
- Full filesystem paths are sanitized to file basenames (`NearsideRedactor.sanitizePath`).
- Device fingerprints are truncated (`NearsideRedactor.sanitizeIdentity`).
- Secrets and raw payloads are replaced with length placeholders (`[REDACTED:32 chars]`).

---

## 3. Subsystem Diagnostic Guides

- [Error Code Registry](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/ERROR_CODES.md)
- [Discovery Diagnostics](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/DISCOVERY.md)
- [Pairing and Trust Diagnostics](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/PAIRING.md)
- [Transfer and Connection Diagnostics](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/TRANSFER.md)
- [Integrity Verification Diagnostics](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/VERIFICATION.md)
- [Storage Diagnostics](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/STORAGE.md)
- [Diagnostic Retrofit Plan](file:///Users/navidzamankhan/Code/Nearside/docs/diagnostics/RETROFIT_PLAN.md)
