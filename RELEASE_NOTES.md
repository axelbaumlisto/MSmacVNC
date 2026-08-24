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
