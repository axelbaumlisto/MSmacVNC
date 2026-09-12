# Разбор ядра: mac.m и AppDelegate.m

План на отдельную сессию. Не смешивать с работой над правами — та закончена и
проверена (коммит `e86ea41`, установлена 0.3.50).

## Правило работы

**От плана не отступаем.** Один шаг — одна ответственность — одна проверка.
После каждого шага: сборка, 19 тестов, analyzer, живой прогон
(`refclient` AUTH_OK + кадры + неверный пароль отклонён). Коммит после
каждого зелёного шага, чтобы всегда был откат.

## Что уже сделано (не переделывать)

```text
ScreenInit  246 → 157 строк
  + resolveDisplayLayout()   топология дисплеев
  + buildClientAccessList()  сетевая политика
  + installPassword()        аутентификация
AppDelegate 662 → 595
  + MacVNCRelauncher   перезапуск
  + MacVNCStatusText   строки меню (чистые, покрыты тестами)
убрано: selectedCount (дубль displayLayout.count), shellQuote,
        applicationDidBecomeActive, латч сбоя захвата
```

## Настоящая проблема — не размер файла

`mac.m` — 866 строк, но связывает всё **20 глобальных переменных**:

```text
rfbScreen, frameBufferOne, displayLayout, screenCapturers,
viewOnly, displayNumber, macVNCListenAddress, macVNCAllowedClients,
macVNCClientAccessMode, clientAccessList, gPasswdList,
rfbServerInitialized, publishedServerPort, serverGeneration,
+ 3 мьютекса (serverLifecycle, compositor, clientLifecycle)
```

Дробить файл, не тронув это состояние, — только перенос строк. Поэтому план
идёт от состояния, а не от размера.

## Шаги

### Шаг 1 — ОТМЕНЁН как декоративный

Перенос 20 глобалей в структуры оставил бы состояние общим, просто
адресуемым через точку: большой diff по всем путям, выгода нулевая.
Вместо этого каждый извлекаемый модуль владеет своим состоянием сам —
глобали исчезают инкапсуляцией, а не переездом.

### Шаг 1-бис — выбор дисплеев (СДЕЛАНО, bc1d070)
- [ ] `MacVNCCompositor`  — `frameBufferOne`, `displayLayout`, `compositorMutex`;
- [ ] `MacVNCClientRegistry` — `screenCapturers`, `clientLifecycleMutex`,
      `publishedServerPort`, `serverGeneration`;
- [ ] `MacVNCAuthConfig` — `gPasswdList`, `viewOnly`;
- [ ] политика доступа (`macVNCAllowedClients`, `macVNCClientAccessMode`,
      `clientAccessList`) уже логически цельная — свести в одну структуру.
- **проверка:** поведение идентично; diff не меняет ни одной строки логики,
  только адресацию полей. Тесты и живой прогон обязательны — это самый
  «безопасный на вид» и потому опасный шаг.

### Шаг 2 — компоновщик (СДЕЛАНО, 5aef4b5)
- [ ] `MacVNCCompositor.{h,m}`: `updateCompositeFrame`, `markCompositeDirty`,
      `lockCurrentClients`, `unlockCurrentClients`;
- [ ] на вход — структура из шага 1, никаких глобалей;
- **проверка:** новый unit-тест композитора на снимке из двух дисплеев;
      живой прогон обоих мониторов (сейчас это покрыто только вручную).

### Шаг 3 — потоки захвата (СДЕЛАНО, d73c46f)
- [ ] `MacVNCServerLifecycle.{h,m}`: `vncServerStart/Stop/StopLocked`,
      `serverHasLifecycleResourcesLocked`, `vncServerCloseListeners`;
- [ ] `ScreenInit` остаётся сборщиком: вызывает уже извлечённые шаги;
- **проверка:** старт/стоп 10 раз подряд без утечек портов
      (`lsof -nP -iTCP:5903` после каждого), `leaks`.

### Шаг 4 — TCC вне ядра (СДЕЛАНО, 46b5f2d)
- [ ] `prepareAuthenticatedClient` сейчас сам решает про права
      (`CGPreflightScreenCaptureAccess` внутри `mac.m`);
- [ ] заменить на инъекцию: `bool (*macVNCCaptureAllowed)(void)`, задаётся
      из AppDelegate — как уже сделано для `macVNCScreenCaptureFailureHandler`;
- **проверка:** тест ядра с подставной функцией «прав нет» → захват не
      стартует, диалог не поднимается. Сейчас это непроверяемо вообще.

### Шаг 5 — AppDelegate (СДЕЛАНО: e309dea defaults, d73c46f запуск, b13c6df меню)
- [ ] `MacVNCStatusMenuController` — построение и обновление меню;
- [ ] `MacVNCServerLauncher` — `startServer`, обработка ошибок старта;
- [ ] `registerDefaults` — рядом с `MacVNCDefaultsKeys`;
- **проверка:** меню живое (щёлкнуть каждый пункт), строки обновляются при
      открытом меню (таймер в `NSRunLoopCommonModes`).

### Шаг 6 — ARCHITECTURE.md (СДЕЛАНО, e309dea + packaging/check_architecture.sh)
- [ ] карта слоёв, новые модули, порядок захвата мьютексов;
- **проверка:** каждое имя из документа существует в коде (скриптом).

## Инварианты (нарушение = откат шага)

- **I1** ни один шаг не меняет наблюдаемое поведение;
- **I2** после каждого шага: 19 тестов, analyzer 0 предупреждений, AUTH_OK,
  оба монитора, неверный пароль отклонён;
- **I3** порядок захвата мьютексов не меняется (описать до правки, сверить после);
- **I4** `vncServerStop` не вызывается с главного потока блокирующе;
- **I5** ядро не читает TCC напрямую после шага 4;
- **I6** каждый новый модуль получает тест, и тест проверяется мутацией.

## Не делаем

- не меняем сетевой протокол и формат кадра;
- не трогаем `disable-library-validation` (эмпирически обязателен);
- не переносим пароль в Keychain (решение пользователя);
- не вводим ARC в существующих файлах;
- не совмещаем два шага в одном коммите.

## Риски, честно

- **Шаг 1 самый опасный**: выглядит как переименование, но задевает все пути.
  Делать первым, пока внимание свежее, и проверять полным прогоном.
- **Шаг 2** трогает горячий путь кадров — возможна регрессия
  производительности. Мерить `updates=N` до и после, сравнивать.
- **Шаг 4** меняет момент проверки прав. Ровно здесь в прошлый раз всплывал
  системный диалог — проверять со сбросом прав, не только на выданных.

## Протокол проверки (иначе замеры ложны)

- запуск **только через GUI**: `open /Applications/macVNC.app`;
- auth только `/tmp/refclient` (vncdotool даёт ложный AUTH_OK);
- сброс прав адресный: `tccutil reset ScreenCapture net.christianbeier.macVNC`;
- установка `ditto` поверх, никогда `rm -rf`;
- бэкап `/Applications/macVNC.app` перед заменой;
- один экземпляр перед каждым замером.


## Итог прохода (2026-08-25)

```text
mac.m       871 → 746   AppDelegate 662 → 590
тестов      18  → 22    все новые проверены мутацией
установлена 0.3.54, коммиты bc1d070 5aef4b5 46b5f2d e309dea
```

### Итог всего прохода

```text
mac.m       871 → 732     AppDelegate 662 → 562
тестов      18  → 24      каждый новый проверен мутацией
коммиты     bc1d070 5aef4b5 46b5f2d e309dea d73c46f b13c6df
установлена 0.3.56
```

Новые модули: DisplaySelection, MacVNCCompositor, MacVNCCaptureSession,
MacVNCStatusText, MacVNCStartFailure, MacVNCRelauncher, MacVNCPermissionUI.

Дефекты, найденные попутно и исправленные:
- сигнал «захват работает» жил весь процесс вместо одного запуска —
  после перезапуска не приходил никогда;
- `selectedCount` дублировал `displayLayout.count`;
- блокирующий мьютекс на главном потоке при закрытии слушателей;
- `strdup` пароля без проверки на нехватку памяти;
- осиротевшие и противоречивые комментарии про `CGPreflight`.

Осознанно не сделано: клиентский `clientLifecycleMutex` и `MacVNCClientState`
остаются в `mac.m`. Они завязаны на `rfbClientPtr` и хуки LibVNCServer;
вынос дал бы модуль, который всё равно знает про libvncserver — перенос
строк без развязки. Разумно только вместе со сменой модели клиента.

## Шаги 7–9 — долг работы capture-liveness (2026-09-12)

Работа `.pi/plans/capture-liveness.md` вылечила поведение, но нарастила ровно
ту болезнь, против которой написан этот план: `mac.m` 1527 → 2795 строк,
глобалей 20 → 44. Из 32 `g*`-статиков 22 добавлены за один день и делятся
на двух владельцев без остатка.

### Шаг 7 — реестр раскладки `MacVNCLayoutRegistry.{h,c}` (СДЕЛАНО, a45f16e)
- владеет: `gDisplayLayoutSlots[2]`, `gPublishedLayout`, `gPinnedDisplayID`,
  `gCaptureSessionGeneration`;
- API: `publish(layout)`, `current()`, `nextSessionGeneration()`,
  `currentSessionGeneration()`, `pinnedDisplay()/pin()/resetPin()`;
- чистый C, без Foundation/SCK/rfb — тестируется как DisplayLayout;
- **проверка:** тест на двойной буфер (публикация N+1 никогда не пишет в
  слот, который читает N), на монотонность generation, на set-once пина;
  мутация: сломать выбор слота — тест должен упасть.

### Шаг 8 — надзор за захватом `MacVNCCaptureSupervisor.{h,m}` (СДЕЛАНО, 5e988a9)
- владеет: `gLastFrameNs[]`, `gCapturesStartedNs`, `gLastRearmNs`,
  `gRearmsSinceFrame`, `gCaptureLivenessTimer`, `gDeskShapeDebounceTimer`
  и все их test-only счётчики/оверрайды (13 глобалей);
- API: `noteFrame(index)`, `arm()/disarm()`, `noteDeskShapeMayHaveChanged()`;
- зависимости инжектятся: очередь (`gCaptureStopQueue`), `rearm`-колбэк,
  `reportFailure`-колбэк, `readDeskLayoutWithoutWaking`, `layoutsEqual`;
  `rearmCaptures()` ОСТАЁТСЯ в mac.m — он трогает `rfbScreen`/`frameBufferOne`;
- **проверка:** существующие тесты `capture_liveness_rearm*` и
  `capture_liveness_rearm_deskshape` проходят без изменения ассертов —
  это и есть доказательство I1.

### Шаг 9 — хуки и документ (СДЕЛАНО, этим коммитом)
- `mac.h`: из 29 `ForTesting`-хуков к своим модулям уходят все, что читают
  состояние шагов 7–8; в `mac.h` остаются только хуки жизненного цикла;
- `ARCHITECTURE.md`: два новых модуля в карте слоёв, порядок мьютексов
  сверен; `check_architecture.sh` зелёный.

Инварианты I1–I6 без изменений. Отдельно: **I7** — горячий путь
`compositeCapturedFrame` после шага 7–8 делает не больше атомарных операций,
чем до (сейчас: 1 load generation, 1 load layout, 1 store stamp, 1 store
rearms). Мерить `updates=N` за 90 с до и после.

### Итог шагов 7–9

```text
mac.m       2795 → 2279     globals(static g*) 44 → 12
тестов      51   → 52       коммиты a45f16e 5e988a9 (шаг 9 — этот)
```

Шаг 9 удалил один чистый форвардер (`macVNCCurrentCaptureGenerationForTesting`,
2 вызывающих места → инлайнены в `macVNCLayoutRegistryCurrentSessionGeneration()`)
и оставил два других форвардера в `mac.h` НЕ по правилу «только
жизненный цикл», а по правилу шага 9 «больше 3 вызывающих мест — не
дёргать тесты»: `macVNCCurrentDisplayLayoutCountForTesting` (5 мест) и
`macVNCPinnedDisplayIDForTesting` (6 мест) читают состояние
`MacVNCLayoutRegistry`, а не жизненный цикл сервера. Осознанное исключение,
не забытая уборка.

### Шаг 10 — форма (после 7–9, поведение 0)

Замер после шага 9: `mac.m` 1198 строк кода / 47% комментариев, 17 блоков
длиннее 12 строк; `CaptureSupervisor.m` 51%, блок в 40 строк над одним
`atomic_store`; `LayoutRegistry.c` 74%. Функции: `rearmCaptures` 121,
`reconcileCaptureState` 102, `startCapturesForNewClient` 89,
`captureLivenessWatchdogFired` 78.

- `rearmCaptures` → две функции по веткам (та же форма / новый холст),
  хвост `Build+Start` написан один раз;
- `reconcileCaptureState`, `startCapturesForNewClient`,
  `captureLivenessWatchdogFired` — вынести именованные шаги, цель ≤60 строк;
- комментарии-эссе → правило + ссылка на `ARCHITECTURE.md`; история
  инцидента живёт в документе (дописать туда, если её там нет), в коде
  остаётся ПОЧЕМУ в ≤12 строк;
- границы: `mac.m`, `mac.h`, `MacVNCCaptureSupervisor.m`,
  `MacVNCLayoutRegistry.c`. Curtain*/TLS/ScreenCapturer не трогать.
- **проверка:** I1 — 52 теста с неизменёнными ассертами; ни одного
  изменённого условия или порядка вызовов в diff; живой прогон.
