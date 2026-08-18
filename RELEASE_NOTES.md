# macVNC 0.2.4

## Highlights

- Simplified Network Preferences:
  - removed the confusing `Allow clients from` checkbox list;
  - removed `All interfaces` from the normal UI path;
  - allowed clients are now calculated automatically from `Accept connections on`.
- New behavior:
  - `Localhost only` → allows `127.0.0.1` only;
  - `Tailscale-like` interface → allows `100.64.0.0/10` automatically;
  - LAN/Wi‑Fi interface → allows that interface subnet automatically;
  - `Custom IPv4 address` → advanced mode; requires extra allowed client CIDRs.
- Manual CIDRs are now clearly labeled as `Extra allowed clients (advanced)` and are optional for normal interface choices.
- Removed repeated broad-range confirmation for the automatic Tailscale range; still warns for explicit `0.0.0.0/0`.

## Validation

- Release build: passed.
- CTest: 14/14 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.

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
