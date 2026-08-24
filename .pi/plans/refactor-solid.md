# Refactor to SOLID/DRY/KISS (no behavior change)

## Context
Functional code is correct and tested (ctest 15/15), but two files violate SRP:
- `src/AppDelegate.m` (1169 lines): app delegate + Keychain/password + password-file + permission popup controller (whole class inline) + preferences UI + login item + network rows.
- `src/mac.m` (1226 lines): server lifecycle + capture + password wiring + dimming + display-wake + input.

DRY issue: password trimming duplicated in defaults path and file path.

Goal: extract cohesive modules, one source of truth per concern, keep behavior identical. Verify with ctest + reference libvncclient auth + frame grab after each step.

## Guardrails
- No behavior change. Same defaults keys, same trimming, same signing.
- Build + ctest after every task; must stay 15/15.
- Auth verified with /tmp/refclient (libvncclient), NOT vncdotool.
- MRC (manual retain/release) style preserved (project is non-ARC).

## Tasks

### Task 1: MacVNCPassword module (SRP + DRY)
Files: src/MacVNCPassword.h, src/MacVNCPassword.m, src/AppDelegate.m, CMakeLists.txt
Extract from AppDelegate.m:
- Keychain: query/read/delete
- defaults load (plaintext, trimmed)
- secure password-file read (trimmed)
- ONE trim helper used by both paths
API:
- `NSString *macVNCLoadPassword(NSUserDefaults *)`
- `NSString *macVNCReadSecurePasswordFile(NSString *path, NSString **err)`
- `void macVNCStorePassword(NSUserDefaults *, NSString *raw)` (trims, writes defaults, deletes keychain)
Verify: build + ctest + refclient auth.

### Task 2: MacVNCPermissionsPanel module (SRP)
Files: src/MacVNCPermissionsPanel.h, .m, src/AppDelegate.m, CMakeLists.txt
Move `MacVNCPermissionsPanelController` out of AppDelegate.m into its own unit.
Keep action constants in header.
Verify: build + ctest.

### Task 3: MacVNCDisplayWake module (SRP)
Files: src/MacVNCDisplayWake.h, .m, src/mac.m, CMakeLists.txt
Extract display-wake assertion helpers (macVNCWakeDisplays / release) into module.
mac.m keeps ScreenInit retry loop but calls the module.
Verify: build + ctest + assertion held check.

### Task 4: Final validation + release 0.3.5
- ctest 15/15
- refclient AUTH_OK + frames
- notarized install smoke
- commit/tag/release

## Non-goals
- Splitting the giant `openPreferences` UI builder (cosmetic; high risk, low value now).
- Rewriting mac.m server core.
