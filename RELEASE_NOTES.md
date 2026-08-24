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
