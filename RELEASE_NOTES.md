# macVNC 0.2.6

## Highlights

- Added startup permission gate: macVNC starts the VNC server only when required macOS permissions are granted.
- New startup popup uses two clickable permission chips:
  - `Screen Recording` — required to share the display;
  - `Accessibility` — required for remote keyboard/mouse control.
- Clicking a missing permission chip opens the matching macOS Privacy & Security pane.
- Permission chips auto-refresh while the popup is open; `Start macVNC` is enabled only after both permissions are granted.
- No `Start anyway` path: no permissions → no VNC listener.
- Permission logic is isolated in `MacVNCPermissions` instead of being mixed into server startup.

## Validation

- Release build: passed.
- CTest: 15/15 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.

# macVNC 0.2.5

- Password is stored in macOS Keychain instead of plaintext `NSUserDefaults`.
- Existing plaintext password is migrated to Keychain automatically and removed from defaults.
- Preferences window is more compact with less empty space.
- `Extra allowed clients (advanced)` shows the expected format.

# macVNC 0.2.4

- Simplified Network Preferences:
  - removed the confusing `Allow clients from` checkbox list;
  - removed `All interfaces` from the normal UI path;
  - allowed clients are now calculated automatically from `Accept connections on`.

# macVNC 0.2.3

- Selected interfaces show `Selected address` as read-only.
- `Custom address` appears only for explicit `Custom IPv4 address` mode.

# macVNC 0.2.2

- Network Preferences no longer shows the safe localhost default (`127.0.0.1`) as a manual custom CIDR when using a network preset.

# macVNC 0.2.1

- Clarified Network Preferences wording and tooltips.
- Reduced noisy network presets.

# macVNC 0.2.0

- Added GUI-managed IPv4 network security settings and active network picker.
- Added explicit client allowlist and allow-all mode.
- Disabled IPv6 listener in v1 network policy.
- Bundled Homebrew dylib dependencies in the notarized standalone DMG.
