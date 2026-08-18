# macVNC 0.2.5

## Highlights

- Password is now stored in macOS Keychain instead of plaintext `NSUserDefaults`.
- Existing plaintext password is migrated to Keychain automatically and removed from defaults.
- Preferences window is more compact with less empty space.
- `Extra allowed clients (advanced)` now shows the expected format:
  - one IPv4/CIDR per line;
  - examples: `100.x.y.z/32`, `192.168.100.0/24`.
- Automatic allowed-client summary is shortened so it fits in the window.

## Validation

- Release build: passed.
- CTest: 14/14 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.
- Installed smoke: RFB banner passed; IPv6 disabled passed.

# macVNC 0.2.4

- Simplified Network Preferences:
  - removed the confusing `Allow clients from` checkbox list;
  - removed `All interfaces` from the normal UI path;
  - allowed clients are now calculated automatically from `Accept connections on`.
- Manual CIDRs are clearly labeled as `Extra allowed clients (advanced)`.

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
