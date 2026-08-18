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
