# macOS Share Extension handoff

The macOS extension stages provider files in its private sandbox, then opens a
`.nearshare` document in the containing Nearside host application. The host imports
its own private copies and acknowledges the import before extension cleanup. A
separate host window lists the shared filenames and requires the user to choose
a currently paired, unblocked recipient. Opening a document never sends files.

Only the host uses its enrolled Keychain identity and trust store. The extension
does not generate a signing key, read or copy trust records, or open network
connections. Its App Sandbox remains enabled. Provider file representations are
copied during their callbacks; security-scoped URL access is balanced around
copying. A failed copy cannot fall back to an inaccessible original URL.

Request paths reject traversal, control characters, and symbolic links. Requests
expire after 24 hours. Files imported by an active host share window are excluded
from expiration cleanup. Copies remain available through transfer completion,
and remain available for retry after failure. Closing the host window removes
its files; in-flight transfers keep their window and files alive.

Diagnostics reuse these stable codes:

- `NS-STORAGE-001`: Provider staging or host import cannot read the shared files.
- `NS-STORAGE-002`: Private staging storage cannot be created or written.
- `NS-PROTO-003`: The handoff is malformed, expired, or uses an unsupported version.
- `NS-PROTO-004`: An unsafe filename or symbolic link was rejected.
- `NS-CONN-001`: The host did not acknowledge its imported copies within 20 seconds.
- `NS-CONN-002`: The host could not be launched; open Nearside and retry sharing.
- `NS-TRUST-004`: Keychain identity could not be read or durably created. Existing
  keys are preserved on denied access, locked Keychain, invalid data, and concurrent
  creation. Unlock Keychain and restart Nearside; no ephemeral identity is returned.

Handoff logs use the request UUID as their correlation ID; transfer errors retain
the engine's transfer ID. Shared content, private keys, pairing payloads, and private
file paths are omitted. File-system errors retain their native domain and code.

`scripts/build_macos.sh` builds/signs in `build/macos` by default. Installing and
registering the extension is an explicit `--install` action; builds and tests do
not replace `/Applications/Nearside.app` or change extension settings.
`scripts/verify_macos_share.sh` covers staging lifetime, duplicate provider filenames,
import acknowledgment, private permissions, malformed/expired requests, path and
symlink rejection, failure cleanup, expiration, and injected Keychain failures.

Manual Mac-to-Android validation:

1. Review and install the local build when ready, then open Nearside. Pair Android
   using the verified QR flow so it has the host's current persistent identity.
2. In Finder, select two regular files with different contents (also test two files
   having the same basename from separate folders). Choose Share → Nearside.
3. Select **Continue in Nearside**. Confirm the host window lists every file and
   no transfer starts until you select the paired Android recipient.
4. Select Android, keep Nearside open, and compare received file checksums. Repeat
   with the host initially closed to verify launch, import acknowledgment, and
   correct sender identity.
5. Turn Android offline, attempt sharing, confirm an actionable bounded failure,
   reconnect it, and retry. Close the host window after failure and confirm its
   private temporary copies are removed. Block/unpair Android and confirm it
   cannot be selected or sent files.
6. Cancel before opening the host and confirm extension copies are removed. Cancel
   while host import is pending and confirm no automatic transfer occurs; abandoned
   extension requests are removed on a later share after the 24-hour expiration.

Automated tests do not verify Finder activation, Launch Services, OS permission
prompts, or physical-device delivery; those checks require the manual steps above.
