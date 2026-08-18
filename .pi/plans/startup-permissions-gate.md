# Startup Permissions Gate

## Context

Сейчас macVNC пытается стартовать VNC-сервер сразу при запуске. Если macOS TCC не даёт Screen Recording/Accessibility, пользователь видит поздний generic error (`macVNC could not start`) вместо понятного статуса разрешений и прямых кнопок открытия System Settings.

Пользователь хочет:
- сначала план по SOLID/DRY/KISS;
- посмотреть Voxis;
- не рисовать новый сложный GUI;
- нажатие должно просто открывать нужный раздел настроек;
- сервер запускать только когда все нужные разрешения выданы.

Voxis reference:
- `voxis/src-tauri/src/permissions/checker.rs` — отдельные `Permission`, `PermissionStatus`, `PermissionChecker`.
- `voxis/src-tauri/src/permissions/macos.rs` — platform-specific checker + `open_settings` через `x-apple.systempreferences`.
- `voxis/src-tauri/src/setup/permission_check.rs` — startup gate возвращает `all_granted`, app не стартует функциональные части при missing permissions.

## Approach

KISS:
- Не делать кастомное окно/баннер.
- Использовать обычный `NSAlert` при запуске, только если permission missing.
- Кнопки: открыть Screen Recording, открыть Accessibility, Preferences, Quit.
- Если оба permission granted — без popup сразу стартовать сервер.
- Если что-то missing — сервер НЕ стартует.

SOLID:
- SRP: вынести permission logic из `AppDelegate.m` в отдельный модуль.
- DIP/OCP-lite: UI зависит от маленького API (`snapshot`, `allGranted`, `openSettings`), а не от конкретных TCC calls.
- AppDelegate только оркестрирует: check → alert/open settings/preferences/quit → startServer.

DRY:
- Один источник правды для permission names, descriptions, settings URLs.
- Не дублировать строки в alert и menu/future UI.

Security:
- No `Start Anyway`.
- No env/launchctl hacks.
- Server starts only if required permissions are granted.

## Tasks

### Task 1: Add permission model module
**Files:** `src/MacVNCPermissions.h`, `src/MacVNCPermissions.m`, `CMakeLists.txt`
**Acceptance:** Permission names/status/settings URLs are centralized; app compiles.
**Verify:** `cmake --build build-release-arm64 -j`
**Steps:**
1. Add enum `MacVNCPermissionKind`: ScreenRecording, Accessibility.
2. Add enum `MacVNCPermissionStatus`: Granted, Denied/NotGranted, Unknown.
3. Add descriptor/snapshot API:
   - `NSArray *macVNCRequiredPermissions(void)` or typed helper API.
   - `BOOL macVNCPermissionsAllGranted(void)`.
   - `NSArray *macVNCMissingPermissions(void)`.
4. Implement macOS checks:
   - Screen Recording: `CGPreflightScreenCaptureAccess()`.
   - Accessibility: `AXIsProcessTrusted()`.
5. Implement open/request helpers:
   - Screen Recording: `CGRequestScreenCaptureAccess()` if needed, then open `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.
   - Accessibility: `AXIsProcessTrustedWithOptions(prompt:true)` if needed, then open `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.
6. Add explicit framework link if needed: CoreGraphics/ApplicationServices.

### Task 2: Startup gate in AppDelegate
**Files:** `src/AppDelegate.m`
**Depends:** Task 1
**Acceptance:** `startServer` is called only when `macVNCPermissionsAllGranted()` is true.
**Verify:** build + smoke local granted path.
**Steps:**
1. In `applicationDidFinishLaunching`, call permission gate before `startServer`.
2. If all granted → `startServer`.
3. If missing → show startup `NSAlert`, do not call `startServer`.
4. Keep status menu as `Not running — permissions required` or similar.
5. Keep Preferences available from menu.

### Task 3: Minimal startup permission alert
**Files:** `src/AppDelegate.m`
**Depends:** Task 1
**Acceptance:** Popup shows status for both permissions and opens correct System Settings panes.
**Verify:** manual launch with missing permission / static code check.
**Steps:**
1. Alert title: `macVNC needs permissions before starting`.
2. Body example:
   - `Screen Recording: Granted / Not granted — required to share the screen`.
   - `Accessibility: Granted / Not granted — required for keyboard/mouse control`.
   - `Grant missing permissions, then relaunch macVNC.`
3. Buttons:
   - `Open Screen Recording` if Screen Recording missing.
   - `Open Accessibility` if Accessibility missing.
   - `Preferences`.
   - `Quit`.
4. Button actions only open settings/preferences/quit. No custom GUI drawing.
5. No `Start anyway` button.

### Task 4: First-run/config interaction
**Files:** `src/AppDelegate.m`
**Depends:** Task 2
**Acceptance:** User can still open Preferences even when permissions are missing; server still does not start.
**Verify:** launch without permission and choose Preferences.
**Steps:**
1. Preferences button opens current compact Preferences dialog.
2. Saving Preferences does not auto-start server if permissions are missing.
3. User must relaunch after granting permissions.

### Task 5: Tests / guards
**Files:** `tests/test_permissions.m` or focused static/unit test, `CMakeLists.txt`
**Depends:** Task 1
**Acceptance:** Non-TCC pure behavior is tested; OS-specific permissions are not faked unsafely.
**Verify:** `ctest --test-dir build-release-arm64 --output-on-failure`
**Steps:**
1. Unit-test descriptor names/URLs/status formatting.
2. Unit-test `allGranted` logic via injected/test snapshots if API supports it.
3. Do not assert current machine TCC state in CI/unit tests.

### Task 6: Release validation
**Files:** `RELEASE_NOTES.md`, release artifacts
**Depends:** Tasks 1-5
**Acceptance:** v0.2.6 installed locally and published only after validation.
**Verify:**
- `cmake --build build-release-arm64 -j`
- `ctest --test-dir build-release-arm64 --output-on-failure`
- `git diff --check`
- sign/notarize/staple/spctl
- installed smoke with permissions granted path
**Steps:**
1. Bump to `0.2.6` only after implementation compiles.
2. Update release notes.
3. Build notarized DMG.
4. Install locally.
5. Smoke: server starts only when permissions granted; missing permission path shows popup and no listener.
6. Commit/tag/release.

## Non-goals

- No custom settings window redesign in this task.
- No automatic TCC database modification.
- No `Start anyway`.
- No launchctl/env workaround.
- No public PKG.

## Verification checklist

- [ ] With all permissions granted: app starts server normally.
- [ ] With Screen Recording missing: startup popup appears; no TCP listener.
- [ ] With Accessibility missing: startup popup appears; no TCP listener.
- [ ] Popup buttons open the correct System Settings panes.
- [ ] Preferences can be opened from popup/menu while server remains stopped.
- [ ] `ctest` passes.
- [ ] Notarized installed app passes Gatekeeper.
