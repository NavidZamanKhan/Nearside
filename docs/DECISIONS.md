# Nearside Architectural Decision Records (ADR)

## ADR-001: Local Wi-Fi Direct Architecture vs Cloud Relay
- Status: Accepted
- Context: Third-party transfer utilities often route metadata or content through cloud servers, increasing latency, compromising privacy, and creating service dependencies.
- Decision: Nearside operates purely local-first over mDNS (`_nearside._tcp`) and direct TCP socket streams. Zero cloud servers or accounts are required.
- Consequences: Transfers are fast and private, but sender and receiver must be on the same local subnet.

## ADR-002: Eager Staging in macOS Share Extension
- Status: Accepted (Milestone 0 Probe E2)
- Context: Apple `NSItemProvider.loadItem(forTypeIdentifier:options:)` delivers URLs in temporary sandbox directories that are pruned by the host application upon callback completion.
- Decision: Nearside Share Extension immediately duplicates or stages incoming file handles to durable app group storage before completing extension callbacks.
- Consequences: Memory consumption is bounded and file handles remain valid for transfer streaming.

## ADR-003: Transparent Handling of Android Cgroup Freeze
- Status: Accepted (Milestone 0 Probe E1)
- Context: Vendor Android firmware (such as OriginOS on Vivo/iQOO) places background worker threads into `do_freezer_trap` when the screen locks, delaying TCP socket accepts.
- Decision: Nearside presents receiving readiness honestly. When receiving is paused or sleeping, mDNS advertising updates `recv=0` to notify peers rather than pretending to be active.
- Consequences: Eliminates sender timeout errors and avoids fighting vendor battery optimization heuristics.

## ADR-004: Trust Pinning via SPKI SHA-256 Fingerprints
- Status: Accepted (Milestone 0 Probe E3)
- Context: Need unambiguous peer authentication resistant to MITM attacks without PKI certificate authority infrastructure.
- Decision: Nearside uses NIST P-256 keypairs. Device identity is designated by `ns1_<hex_digest>` computed from public key SPKI bytes. Trust is permanently pinned on first pairing.
- Consequences: Mutual authentication is cryptographic and self-contained.
