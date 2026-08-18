# macVNC 0.2.1

## Highlights

- Clarified Network Preferences wording:
  - `Accept connections on` = local interface/address where macVNC listens.
  - `Allow clients from` = remote client IP ranges allowed to connect.
- Reduced noisy network presets:
  - hidden loopback, bridge, AWDL/LLW, link-local, and non-CGNAT `/32` tunnel rows from allow presets.
- Tailscale-like/CGNAT rows now present a clear broad `100.64.0.0/10` preset with tooltip warning instead of a useless local `/32` client range.
- Manual CIDR field now shows only custom entries, not duplicated checked presets.
- Added tooltips/help text for listen vs allowlist behavior.

## Validation

- Release build: passed.
- CTest: 14/14 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.

# macVNC 0.2.0

- Added GUI-managed IPv4 network security settings.
- Added active network picker for listen/bind address selection.
- Added explicit client allowlist with IPv4/CIDR support.
- Added explicit allow-all mode; empty allowlist no longer silently means allow all.
- Disabled IPv6 listener in v1 network policy until IPv6 allowlist semantics exist.
- Bundled Homebrew dylib dependencies in the notarized standalone DMG.
