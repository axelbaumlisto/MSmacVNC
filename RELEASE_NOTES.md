# macVNC 0.2.2

## Highlights

- Network Preferences no longer shows the safe localhost default (`127.0.0.1`) as a manual custom CIDR when using a network preset.
- Keeps the explicit broad-range warning for `100.64.0.0/10` / Tailscale-like access.

## Validation

- Release build: passed.
- CTest: 14/14 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.

# macVNC 0.2.1

- Clarified Network Preferences wording and tooltips.
- Reduced noisy network presets.
- Tailscale-like/CGNAT rows show `100.64.0.0/10` as an explicit broad preset.

# macVNC 0.2.0

- Added GUI-managed IPv4 network security settings and active network picker.
- Added explicit client allowlist and allow-all mode.
- Disabled IPv6 listener in v1 network policy.
- Bundled Homebrew dylib dependencies in the notarized standalone DMG.
