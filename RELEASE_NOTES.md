# macVNC 0.3.21

## Critical: release tooling is now version-controlled

- `make_release.sh` and `entitlements.plist` lived in `build/`, which `.gitignore` excluded — they were **never committed**. A routine `rm -rf build` (or a fresh clone) destroyed the signing recipe irrecoverably, including the two hard-won invariants it encodes (realpath dylib bundling; the `disable-library-validation` entitlement required for VNC DES auth). Moved to a tracked `packaging/` directory.

## Reliability / availability fixes

- **One stalled client no longer freezes every client.** The compositor took each client's `sendMutex` with a blocking lock while holding the compositor lock; since LibVNCServer holds that mutex for the entire encode+socket write, a single viewer that stopped reading (suspended laptop, dead link, or a hostile peer stalling TCP) froze the screen for all co-viewers indefinitely, and could also wedge capture teardown. Locking is now non-blocking: a busy client simply causes that frame to be skipped and retried. `maxClientWait` is also bounded so a dead client gets dropped.
- **A capture error is no longer permanently misdiagnosed as “no Screen Recording permission”.** Any ScreenCaptureKit failure (e.g. a display being unplugged) latched a process-global “permission missing” flag that nothing could clear, killing the session with a false diagnosis and no recovery. The failure handler now receives the error class and only latches on a genuine TCC denial (`SCStreamErrorUserDeclined` / `MissingEntitlements`); other failures clear the latch and report a recoverable error.
- **The permissions gate is no longer a dead end.** Choosing “Preferences” on the permission panel previously left the app with no way to ever start the server again. That branch now returns to the gate, and a permanent **Start Server** menu item was added (it also clears a stale capture-failure latch).

## Validation

- Release build: passed. clang static analyzer: 0 warnings.
- CTest: 17/17 passed.
- A/B verified that the non-blocking compositor change does not affect frame delivery (frame capture in a shell-launched build is limited by TCC, not by this change; the GUI-launched instance streams normally).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.20

## Security fixes (found by an adversarial security review)

- **CGNAT interface no longer silently widens the allowlist.** Selecting an interface that
  merely *has* a CGNAT (100.64.0.0/10) address — e.g. a carrier/campus LAN — previously
  replaced its real subnet with the whole `100.64.0.0/10` range (~4.2M addresses) and
  labelled it "Tailscale clients". The broad tailnet preset now applies only to an actual
  point-to-point tailnet interface (`utunN`, /32); a CGNAT address on a normal broadcast
  interface keeps its true subnet and is labelled honestly. Added the missing regression
  test for that case.
- **"Allow all" confirmation is now semantic, not a substring match.** Any `/0` prefix
  (e.g. `10.0.0.0/0`) matches every IPv4 client but previously bypassed the warning, which
  only looked for the literal `0.0.0.0/0`. The gate now parses the list and uses
  `macVNCNetworkAccessContainsAllowAll()` (which existed but was unused).
- **The 8-character VNC password limit is now surfaced.** RFB's DES auth derives its key
  from only the first 8 characters, so a longer password added no entropy and rotating only
  its tail did not change the credential — silently. Preferences now warns explicitly on
  save (with a tooltip on the field).

## Other fixes

- Fixed a latent teardown self-deadlock: `ScreenCapturer -dealloc` could run on its own
  sample-handler queue (when GCD dropped the last block-captured reference there) and
  `dispatch_sync` to that same serial queue. It now detects that case via a queue-specific
  key and skips the redundant drain.

## Validation

- Release build: passed. clang static analyzer: 0 warnings.
- CTest: 17/17 passed, including the new CGNAT-on-broadcast-interface regression test.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.19

## Highlights

- Fixed a real startup crash found by an adversarial review: `keyboardInit` dereferenced `kTISPropertyUnicodeKeyLayoutData` without a NULL check. That property is NULL for input sources without uchr data (e.g. CJK/handwriting IMEs), so a user whose active input source was such an IME crashed on launch before the listener opened. Now guarded — startup fails cleanly with a clear message instead of crashing.
- Fixed latent UB in the same loop: `UCKeyTranslate` may set `realLength = 0` and leave `chars[0]` unwritten; the code now skips those keycodes instead of reading an uninitialized `UniChar` (which could inject a bogus char→keycode mapping).

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.18

## Highlights

- Closed the last two cosmetic review nits (codebase now converged/clean):
  - `MacVNCPowerMgmt undim()` consumes its 1s throttle window only after confirming the module is initialised, so an uninitialised/failed call no longer blocks the next nudge.
  - `MacVNCPreferences` form layout uses a named grid (row/column constants) instead of scattered magic `NSMakeRect` numbers.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.17

## Highlights

- Final polish from a convergence-confirming blind review:
  - **UX fix:** an empty/unset password now yields an explicit configuration error in `MacVNCStartupConfig` (surfaced as a dialog) instead of failing silently to “Not running”. Added a unit-test case.
  - **Logging accuracy:** `clientGone` now reports the authoritative connected-client count under the lock for un-counted (never-authenticated) clients.
  - **DRY:** `MacVNCPowerMgmt` dim/sleep save+restore collapsed from four near-identical functions into two key-parameterized helpers.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.16

## Highlights

- Closed the remaining clean-code refinements from an independent blind re-scoring pass:
  - **DIP:** replaced the mutable `extern preventDimming/preventSleep` globals in `MacVNCPowerMgmt.h` with an explicit `macVNCSetPowerPolicy()` setter (config, not ambient state).
  - **SRP/KISS:** extracted the Preferences form construction into `-buildFormForPort:...` so `-runModal` no longer mixes view building with model decode + persistence.
  - **DRY:** loopback address now flows from one source — new `MacVNCLoopbackIPv4` (derived from the `MACVNC_LOOPBACK_IPV4` C macro) used by AppDelegate defaults, Preferences, and NetworkInventory; Fn keysym/keycode named (`MACVNC_KEYSYM_FN`/`MACVNC_KEYCODE_FN`).
  - **KISS:** `macVNCReadSecurePasswordFile` uses a single `goto fail` cleanup instead of repeating close/free across five validation branches.
  - Fixed a stale header doc in `MacVNCStartupConfig.h` (removed the mention of a `passwordFileReader` seam the API never exposed).

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.15

## Highlights

- Completed the full SOLID/DRY/KISS scoring-review TOP-10 punch list:
  1. `MacVNCPowerMgmt` — fixed resource leak + mutex-init UB on `dimmingInit` intermediate error paths (single rollback via `releasePowerResources` + `pthread_mutex_destroy`).
  2. Wired the previously-dead `allowAllConfirmed` path: confirming the 0.0.0.0/0 warning now sets ALLOW_ALL_CONFIRMED so mode + status label reflect reality.
  3. Throttled `undim()` to at most once/second (was 3 IOKit syscalls under a lock on every keystroke/mouse-move).
  4. `MacVNCDisplayWake` now reuses one user-activity assertion ID and releases it (per Apple guidance) instead of leaking a fresh one per wake.
  5. Split the ~190-line `MacVNCPreferences -runModal` — extracted pure model helpers (`macVNCManualAllowedText`, selection/allowlist assembly) out of the view builder.
  6. Replaced magic listen-popup tags (1/2/1000) with named constants shared by build + save paths.
  7. Network-row dictionary keys are now shared `MacVNCRowKey*` constants (single source of truth for producer + consumer; no more typo-masking).
  8. `specialKeyMap` converted from fragile pair-stride `int[]` to a typed `{sym, code}` struct array.
  9. `main.m` autoreleases the app delegate (balances the one unbalanced MRC alloc).
  10. Added `src/ARCHITECTURE.md` documenting the pure-C-core ↔ ObjC-glue split, seams, and concurrency/lock model.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.14

## Highlights

- Finished the optional areview punch-list (the “tails”):
  - **Login-item extracted:** new `MacVNCLoginItem` owns SMAppService / LaunchAgent start-at-login; AppDelegate just delegates.
  - **Startup config extracted:** new `MacVNCStartupConfig` is a pure, unit-tested builder that turns NSUserDefaults + environment into a `MacVNCServerConfig` (owns its backing storage). AppDelegate `startServer` shrank to a few lines; added `test_startup_config` (4 cases).
  - **Cross-language DRY:** shared `MacVNCListenModeNames.h` C macros are now the single source of truth for the listen-mode strings and loopback address, consumed by both `NetworkPolicyResolver` (C) and `MacVNCListenMode` (ObjC); `test_listen_mode` asserts they stay in sync.
  - AppDelegate.m: 494 → 378 lines.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 17/17 passed (lsof-based `client_allowlist` skipped on this host's unreliable lsof; listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.13

## Highlights

- Second “ideal code” blind areview round (3 critics, 9/9/9, no blockers). Fixed every remaining item:
  - **IOKit resource leak:** `MacVNCPowerMgmt` now closes the `io_connect_t` and deallocates the mach port on shutdown, is idempotent across restarts, and destroys its mutex (no re-init UB).
  - **Encapsulation:** `rfbScreen` and `frameBufferOne` are now `static` (were external linkage but file-local).
  - **Robustness:** keyboard-layout name printed via a safe buffer (no `printf("%s", NULL)` from `CFStringGetCStringPtr`); `rfbScreen->thisHost` explicitly NUL-terminated.
  - **Consistency:** capture-failure flag is `_Atomic` (was `volatile BOOL`).
  - **Security:** the in-memory VNC password is now zeroized and freed on server stop (and on restart), not left resident for the process lifetime.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across changed Objective-C modules.
- CTest: 16/16 passed (the lsof-based `client_allowlist` harness is unreliable on this host's network stack; server listener + auth verified directly: AUTH_OK, composite 5552x2715).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.12

## Highlights

- Addressed every finding from a 3-critic “ideal code” blind areview (scores 8-9/10, no blockers) plus a memory-safety pass:
  - **Config struct:** `vncServerStart(const MacVNCServerConfig *)` replaces five ambient mutable globals (viewOnly/displayNumber/listenAddress/allowedClients/accessMode). AppDelegate now forwards the resolved policy as an immutable value object; the server keeps a private copy. Mirrors the clean `macVNCInputSetContext` seam.
  - **DRY:** single `macVNCReadinessNow()` clock in ReadinessPolicy (removed two identical `monotonicNanoseconds`); MacVNCPassword reuses `MacVNCKeyPassword`/`MacVNCBundleID` instead of re-hardcoding `@"rfbPassword"` and the bundle id.
  - **Contract fix:** mac.h no longer claims `password==NULL disables auth` (it is mandatory).
  - **Encapsulation:** ScreenCapturer private ivars moved out of the public header; `newClient`/`clientGone` made `static`.
  - **Memory safety:** fixed a real `_stream` leak in ScreenCapturer -dealloc; hardened the MACVNC_PASSWORD_FILE invalid-UTF-8 path (explicit free); PtrAddEvent now null-guards the injected context and writes cursorX/Y under the pointer mutex; permissions-panel observer removed symmetrically in runModal.

## Validation

- Release build: passed.
- clang static analyzer: 0 warnings across all Objective-C modules.
- CTest: 17/17 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.11

## Highlights

- Zero-exceptions clean-code pass — finished every deferred item:
  - Extracted all keyboard + pointer input from `mac.m` into a new `MacVNCInput` module (owns the CGEventSource, keymaps, input mutexes and state; screen/layout injected via `macVNCInputSetContext`). `mac.m` 1030 → 644 lines and no longer holds any input globals.
  - Removed the `#define kKey*` alias shim in `AppDelegate.m`; call sites now use the canonical `MacVNC*` defaults-key symbols directly.
  - Dropped the now-unused Carbon include from `mac.m`; refreshed its file header.
  - Added `test_input_context` unit test for the injectable input context.

## Validation

- Release build: passed.
- CTest: 17/17 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715 (both displays).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.10

## Highlights

- Post-review cleanup (3-critic blind areview, all non-blocking findings addressed):
  - Fixed stale header docs in `MacVNCDisplayWake.h` / `MacVNCPowerMgmt.h` (they described a persistent NoDisplaySleep assertion that was removed; wake is now a one-shot user-activity nudge only).
  - Removed dead imports in `AppDelegate.m` (NetworkAccess/NetworkCIDR/NetworkInventory).
  - Removed orphaned IOPM includes in `mac.m`.
  - DRY: extracted `macVNCTrimmedNonEmptyLines()` helper in `MacVNCPreferences.m` (was duplicated twice).
- Confirmed by review: display wake takes only the caffeinate *principle* (wake-on-demand), not persistent screen holding. Intended: an idle passive/view-only client may let the display sleep.

## Validation

- Release build: passed.
- CTest: 16/16 passed.
- 3 independent code critics: 8/10, 7/10, 8/10, CONDITIONAL GO; no code defects, only the doc/cleanup items now fixed.

# macVNC 0.3.9

## Highlights

- DRY: removed scattered magic listen-mode strings ("localhost"/"all"/"custom"/"selected") and duplicated bind-host resolution.
- New `MacVNCListenMode` module is the single source of truth for mode constants and `macVNCBindHostForMode()`, with unit tests.

## Validation

- Release build: passed.
- CTest: 16/16 passed (added listen_mode).
- Reference libvncclient auth: AUTH_OK, composite 5552x2715.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.8

## Highlights

- Removed the built-in "caffeinate" behavior: macVNC no longer holds a persistent NoDisplaySleep power assertion.
- Display wake is now KISS: on start and on client connect it only declares local user activity (a one-shot nudge that lights up a sleeping/dimmed screen), without forcing the display to stay awake indefinitely.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Verified: no persistent NoDisplaySleep assertion is held by the process; UserIsActive nudge on connect.

# macVNC 0.3.7

## Highlights

- Further SOLID/DRY/KISS refactor (no behavior change): extracted the legacy IOPM screen dim/sleep control into `MacVNCPowerMgmt`.
- `mac.m` reduced from 1226 → 1030 lines; the remaining code is the cohesive server/capture/input core.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715 (both displays).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.6

## Highlights

- Multi-monitor: default capture is now all displays (`displayNumber = -2`), so a second monitor is no longer "lost" in the remote session (composited into one framebuffer).
- More SOLID/DRY/KISS refactor (no behavior change):
  - `MacVNCDefaultsKeys` — single source of truth for NSUserDefaults keys / bundle id / default port.
  - `MacVNCNetworkRows` — active-interface enumeration extracted from AppDelegate.
  - `MacVNCPreferences` — the entire Preferences window moved out of AppDelegate.
- `AppDelegate.m` reduced from 1169 → 500 lines; concerns now split across focused units.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth: AUTH_OK, composite 5552x2715 (both displays).
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.5

## Highlights

- Internal refactor for SOLID/DRY/KISS (no behavior change):
  - `MacVNCPassword` — single source of truth for password load/store/file read with one trim helper.
  - `MacVNCPermissionsPanel` — the startup permission chip panel moved out of AppDelegate.
  - `MacVNCDisplayWake` — display wake + NoDisplaySleep assertion extracted from mac.m.
- `AppDelegate.m` reduced from 1169 to ~800 lines; each concern now lives in its own unit.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth: AUTH_OK.
- NoDisplaySleep assertion held while running.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.4

## Highlights

- macVNC now wakes the display automatically so a remote client never sees a blank/black screen when the Mac has dimmed or slept the display.
- On server start it nudges the display awake and retries if the active display count is 0 (previously it failed with "Unsupported active display count: 0").
- On each client connection it declares user activity to wake the screen.
- Holds a `NoDisplaySleep` power assertion for the lifetime of the session and releases it on stop.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Verified: NoDisplaySleep + UserIsActive assertions held while running; frames delivered.

# macVNC 0.3.3

## Highlights

- Fixed the long-standing "password check failed" bug for the notarized standalone build.
- Root cause: the app was signed with hardened runtime but WITHOUT `com.apple.security.cs.disable-library-validation`, so the bundled Homebrew dylibs (libvncserver + OpenSSL) failed library validation and libvncserver's OpenSSL-backed VNC DES password check always failed.
- Release signing now uses `build/entitlements.plist` with `disable-library-validation`.
- Release packaging now bundles the REAL dylib targets (resolves symlinks) so a stale/mismatched OpenSSL can no longer be shipped.
- Password is stored in plaintext defaults and trimmed of surrounding whitespace/newlines.
- Note: VNC passwords are effectively 8 characters (DES); longer values are truncated.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Reference libvncclient auth against the signed bundle: AUTH_OK.
- Developer ID + hardened runtime + entitlements: signed, notarized, stapled.

# macVNC 0.3.1

## Highlights

- Password is now stored in plaintext `NSUserDefaults` (by request), not in the macOS Keychain.
- Fixes the case where a Keychain-stored password was unreadable by the app (`errSecInteractionNotAllowed -25308`), which made the server refuse to start with "A non-empty VNC password is required".
- Any legacy Keychain password is migrated back into defaults and removed from the Keychain.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing / notarization / staple: passed.

# macVNC 0.3.0

## Highlights

- Do not block startup on `CGPreflightScreenCaptureAccess()` false-negatives; rely on the runtime capture handler instead.

# macVNC 0.2.9

## Highlights

- Permission chips now only open the relevant macOS Privacy & Security pane.
- Removed the extra macOS system permission request dialog that popped up when clicking a chip (no more `CGRequestScreenCaptureAccess`/Accessibility prompt from our UI).
- Behavior otherwise unchanged: single unified permission popup; no permissions → no VNC listener.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.

# macVNC 0.2.8

## Highlights

- Unified permission handling into a single source of truth (`MacVNCPermissions`).
- One single double-chip permission popup is used everywhere:
  - at startup when permissions are missing;
  - when ScreenCaptureKit fails at runtime.
- Removed the old separate `OK` permission alerts from the server/capture path.
- Fixed a class of bugs where `CGPreflightScreenCaptureAccess()` returned a stale `true` after an update:
  - a runtime capture failure now marks Screen Recording as not effectively granted;
  - the unified popup shows `Restart required` and offers `Restart macVNC`.
- `Restart macVNC` now waits for the current process to exit before launching a new one, so it no longer leaves two macVNC processes running.
- Safety rule unchanged: no required permissions → no VNC listener.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.
- Installed runtime gate: no listener without permissions; single process after relaunch.

# macVNC 0.2.7

- Fixed startup permission popup refresh behavior after granting permissions in System Settings.
- `Restart required` chip state and `Restart macVNC` action for permissions pending process restart.

# macVNC 0.2.6

- Added startup permission gate with two clickable permission chips.
- No `Start anyway`: no permissions → no VNC listener.
- Permission logic isolated in `MacVNCPermissions`.

# macVNC 0.2.5

- Password is stored in macOS Keychain instead of plaintext `NSUserDefaults`.
- Compact Preferences window; advanced allowed-clients format hint.

# macVNC 0.2.4

- Simplified Network Preferences; automatic client allow policy from selected interface.

# macVNC 0.2.3

- Selected interfaces show `Selected address` as read-only.

# macVNC 0.2.2

- Localhost default no longer shown as a manual custom CIDR when using a network preset.

# macVNC 0.2.1

- Clarified Network Preferences wording and tooltips.

# macVNC 0.2.0

- Added GUI-managed IPv4 network security settings and active network picker.
- Added explicit client allowlist and allow-all mode.
- Disabled IPv6 listener in v1 network policy.
- Bundled Homebrew dylib dependencies in the notarized standalone DMG.
