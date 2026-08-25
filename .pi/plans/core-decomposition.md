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

### Шаг 1 — сгруппировать состояние в структуры (без смены поведения)
- [ ] `MacVNCCompositor`  — `frameBufferOne`, `displayLayout`, `compositorMutex`;
- [ ] `MacVNCClientRegistry` — `screenCapturers`, `clientLifecycleMutex`,
      `publishedServerPort`, `serverGeneration`;
- [ ] `MacVNCAuthConfig` — `gPasswdList`, `viewOnly`;
- [ ] политика доступа (`macVNCAllowedClients`, `macVNCClientAccessMode`,
      `clientAccessList`) уже логически цельная — свести в одну структуру.
- **проверка:** поведение идентично; diff не меняет ни одной строки логики,
  только адресацию полей. Тесты и живой прогон обязательны — это самый
  «безопасный на вид» и потому опасный шаг.

### Шаг 2 — вынести компоновку кадра
- [ ] `MacVNCCompositor.{h,m}`: `updateCompositeFrame`, `markCompositeDirty`,
      `lockCurrentClients`, `unlockCurrentClients`;
- [ ] на вход — структура из шага 1, никаких глобалей;
- **проверка:** новый unit-тест композитора на снимке из двух дисплеев;
      живой прогон обоих мониторов (сейчас это покрыто только вручную).

### Шаг 3 — вынести жизненный цикл сервера
- [ ] `MacVNCServerLifecycle.{h,m}`: `vncServerStart/Stop/StopLocked`,
      `serverHasLifecycleResourcesLocked`, `vncServerCloseListeners`;
- [ ] `ScreenInit` остаётся сборщиком: вызывает уже извлечённые шаги;
- **проверка:** старт/стоп 10 раз подряд без утечек портов
      (`lsof -nP -iTCP:5903` после каждого), `leaks`.

### Шаг 4 — убрать TCC из ядра (Dependency Inversion)
- [ ] `prepareAuthenticatedClient` сейчас сам решает про права
      (`CGPreflightScreenCaptureAccess` внутри `mac.m`);
- [ ] заменить на инъекцию: `bool (*macVNCCaptureAllowed)(void)`, задаётся
      из AppDelegate — как уже сделано для `macVNCScreenCaptureFailureHandler`;
- **проверка:** тест ядра с подставной функцией «прав нет» → захват не
      стартует, диалог не поднимается. Сейчас это непроверяемо вообще.

### Шаг 5 — AppDelegate: остальные извлечения
- [ ] `MacVNCStatusMenuController` — построение и обновление меню;
- [ ] `MacVNCServerLauncher` — `startServer`, обработка ошибок старта;
- [ ] `registerDefaults` — рядом с `MacVNCDefaultsKeys`;
- **проверка:** меню живое (щёлкнуть каждый пункт), строки обновляются при
      открытом меню (таймер в `NSRunLoopCommonModes`).

### Шаг 6 — привести ARCHITECTURE.md к реальности
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
