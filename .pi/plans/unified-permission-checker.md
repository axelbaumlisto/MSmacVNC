# Unified Permission Checker + Single Double-Chip Popup

## Context

Сейчас проверки прав размазаны по коду и дают несогласованность:

- `src/MacVNCPermissions.m` — `CGPreflightScreenCaptureAccess()` + `AXIsProcessTrusted()`.
- `src/AppDelegate.m` startup gate — вызывает checker, показывает наш chip-popup.
- `src/AppDelegate.m` startServer failure — старый generic `NSAlert` `macVNC could not start` с `OK`.
- `src/mac.m` `vncServerStart` — отдельная проверка `AXIsProcessTrustedWithOptions`.
- `src/mac.m` `captureErrorHandler` — отдельный `NSAlert` `Screen Recording permission required` с `OK` + сам открывает Settings и делает `terminate`.

Наблюдаемый баг:
- gate пропустил старт (`CGPreflight` вернул устаревший `true` после обновления),
- реальный `ScreenCaptureKit` упал,
- вылез СТАРЫЙ `OK`-alert (из `mac.m`/failure path), а не наш двойной chip-popup,
- при этом наплодилось 2 процесса macVNC, listener не открыт.

Проверено фактически:
```
CGPreflightScreenCaptureAccess() = false
AXIsProcessTrusted()             = true
```

Хотим:
- один системный чекер (source of truth);
- один двойной chip-popup (Screen Recording + Accessibility) в одном окне;
- этот popup показывается и на старте, и при ошибке захвата;
- убрать все старые одиночные `OK`-alert по правам;
- не плодить двойные процессы.

## Approach (SOLID / DRY / KISS)

SRP:
- `MacVNCPermissions` — единственный модуль, который знает как проверять/запрашивать/открывать права.
- `AppDelegate` — оркестрация UI и жизненного цикла (gate, popup, relaunch).
- `mac.m` — только сервер/захват, БЕЗ собственных permission-alert и без дублирующей проверки прав.

DRY:
- Один чекер: `macVNCCheckPermission` / `macVNCPermissionSnapshots` / `macVNCPermissionsAllGranted`.
- Один popup-контроллер `MacVNCPermissionsPanelController` (двойной chip) — используется из gate и из capture-failure.
- Один список permission-описаний/URL/статусов.

KISS:
- Никаких новых кастомных виджетов сверх текущих chip-кнопок.
- `mac.m` при ошибке захвата НЕ рисует UI сам — только сообщает наверх (callback/флаг), а `AppDelegate` показывает единый popup.
- Единая точка старта сервера: `AppDelegate` проверяет чекер → показывает popup при нехватке → стартует сервер только при all-granted.

Security:
- Правило прежнее: нет прав → нет listener.
- Никаких `Start anyway`, launchctl, env-хаков.

## Root-cause fix

`CGPreflightScreenCaptureAccess()` может вернуть stale-`true` после обновления бинарника.
Решение:
- добавить в чекер надёжную верификацию Screen Recording (не только preflight),
- при ошибке `ScreenCaptureKit` считать Screen Recording фактически `NotGranted/RestartRequired`,
- отражать это в едином popup.

## Tasks

### Task 1: Единый чекер как source of truth
**Files:** `src/MacVNCPermissions.h`, `src/MacVNCPermissions.m`, `tests/test_permissions.m`
**Acceptance:** Все проверки прав идут только через `MacVNCPermissions`. Есть возможность пометить Screen Recording как "runtime capture failed".
**Verify:** `ctest -R permissions`
**Steps:**
1. Оставить `macVNCCheckPermission` единственным низкоуровневым чеком.
2. Добавить runtime-флаг: `macVNCNoteScreenCaptureFailure(void)` / `macVNCResetScreenCaptureFailure(void)`.
3. `macVNCCheckPermission(ScreenRecording)` учитывает и preflight, и runtime-флаг (если захват падал → NotGranted, даже если preflight=true).
4. Юнит-тесты на: имена/URL/статусы + логика с runtime-флагом через snapshot-функции.

### Task 2: Единый двойной chip-popup
**Files:** `src/AppDelegate.m`
**Depends:** Task 1
**Acceptance:** Один `MacVNCPermissionsPanelController` (2 chip'а) используется и на старте, и по запросу из ошибки захвата.
**Verify:** build + запуск с недостающим правом.
**Steps:**
1. Убедиться, что контроллер один и переиспользуемый.
2. Публичный метод в `AppDelegate`, например `-showPermissionsPanel`, который открывает единый popup (idempotent: не плодить второй).
3. Guard от повторного открытия, если popup уже показан.

### Task 3: Убрать дублирующие permission-alert из mac.m
**Files:** `src/mac.m`, `src/mac.h`, `src/AppDelegate.m`
**Depends:** Task 1, Task 2
**Acceptance:** В `mac.m` нет собственных `NSAlert` по правам и нет прямого `terminate`. Ошибка захвата и отсутствие Accessibility уходят наверх в единый popup.
**Verify:** build + capture-failure path.
**Steps:**
1. `captureErrorHandler` в `mac.m` больше не показывает alert/не открывает Settings/не terminate.
2. Вместо этого: `macVNCNoteScreenCaptureFailure()` + сообщить `AppDelegate` (callback или notification) → показать единый popup.
3. Убрать/ən‑свести дублирующую проверку `AXIsProcessTrustedWithOptions` в `vncServerStart`: право проверяет `AppDelegate` до старта.
4. Убрать старый generic `macVNC could not start` OK-alert либо свести к единому popup для permission-случаев.

### Task 4: Единая точка старта + отсутствие двойных процессов
**Files:** `src/AppDelegate.m`
**Depends:** Task 2, Task 3
**Acceptance:** Сервер стартует только через один путь; relaunch не оставляет два процесса.
**Verify:** запустить, проверить `pgrep macVNC` == 1.
**Steps:**
1. Все старты сервера идут через один метод (`-startServerIfPermitted`).
2. `Restart macVNC` завершает текущий процесс до/во время запуска нового (open -n только после terminate, либо single-instance guard).
3. Проверка: после relaunch ровно один процесс.

### Task 5: Тесты и guи-smoke
**Files:** `tests/test_permissions.m`, `tests/test_client_allowlist.py`
**Depends:** Task 1-4
**Acceptance:** ctest зелёный; gate по-прежнему не открывает listener без прав; test-bypass не ломается.
**Verify:** `ctest --output-on-failure`
**Steps:**
1. Тест runtime-флага Screen Recording.
2. Не ломать `MACVNC_TEST_SKIP_PERMISSION_GATE` bypass в build-dir.
3. Проверить denied/allowed listener сценарии.

### Task 6: Release 0.2.8
**Files:** `CMakeLists.txt`, `RELEASE_NOTES.md`
**Depends:** Task 1-5
**Acceptance:** Установлен и опубликован после полной валидации.
**Verify:** build, ctest, sign, notarize, staple, spctl, installed runtime-gate, single-process check.
**Steps:**
1. Bump `0.2.8` после успешной сборки.
2. Обновить release notes.
3. Notarized DMG → install → smoke.
4. Commit/tag/release.

## Non-goals

- Новый дизайн окна Preferences.
- Замена системного macOS TCC prompt (его показывает сама macOS).
- PKG.

## Verification checklist

- [ ] Один чекер: grep не находит permission-alert вне `AppDelegate`/`MacVNCPermissions`.
- [ ] Один двойной chip-popup и на старте, и при ошибке захвата.
- [ ] Stale-`CGPreflight=true` + capture fail → единый popup с `Restart required`, не старый OK-alert.
- [ ] Нет прав → нет listener.
- [ ] После relaunch ровно один процесс macVNC.
- [ ] ctest зелёный.
- [ ] Notarized install проходит Gatekeeper.
