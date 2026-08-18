# macVNC 0.2.0

## Highlights

- Added GUI-managed IPv4 network security settings.
- Added active network picker for listen/bind address selection.
- Added explicit client allowlist with IPv4/CIDR support.
- Added explicit allow-all mode; empty allowlist no longer silently means allow all.
- Disabled IPv6 listener in v1 network policy until IPv6 allowlist semantics exist.
- Added clearer VNC address copying based on actual selected listen address.
- Bundled Homebrew dylib dependencies in the notarized standalone DMG.

## Security notes

- VNC should still be used behind Tailscale/VPN/private network controls.
- Tailscale-like/CGNAT `100.64.0.0/10` is treated as a broad explicit preset; Tailscale ACLs remain the primary trust boundary.
- First launch after installing this Developer ID build may require granting Accessibility and Screen Recording once.

## Validation

- Release build: passed.
- CTest: 14/14 passed.
- Developer ID Application signing: passed.
- Notarization: accepted.
- Stapler validation: passed.
- Gatekeeper assessment: accepted as Notarized Developer ID.
