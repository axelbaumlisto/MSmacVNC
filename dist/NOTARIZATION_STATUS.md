# macVNC 0.3.66 — notarized release

- DMG: `release-0.3.66/macVNC-0.3.66-arm64.dmg`
- SHA256: `f7424c6a890a4ae2a9253514545294e65f520f36115bb4408f73d74a017032ce`
- Notarized (submission accepted), stapled and re-validated:
  - DMG: `stapler validate` OK; `spctl -a -t install` accepted (Notarized Developer ID)
  - The .app INSIDE the DMG carries its own staple and passes `spctl -a -t exec`
- End-to-end verified by installing from the DMG: AUTH_OK 5552x2715,
  wrong password INIT_FAILED, 1107 frames / 33336 non-zero samples, 0 leaks,
  29/29 ctest.
- Previous notarized DMG (0.3.22) remains at `release-0.3.22/` as rollback.
