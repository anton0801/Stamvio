# Отчёт по приёмке A01–A30

Версия приложения 1.0 (1), дата проверки 08.10.2026.

## Где проверялось

| | |
|---|---|
| Среда | Xcode 16.4, iOS 18.5 Simulator, iPhone 16 (macOS 15, Apple Silicon) |
| Реальные устройства | iPhone 13 Pro, iOS 17.1.2 — короткая проверка навигации в «Настройках» с разрешения владельца (см. «Дефекты, найденные на устройстве»). Остальные пункты на устройстве **не проверялись** |
| iOS 17 (минимальная) | **не проверялось**: среда iOS 17 в этой системе не установлена |
| StoreKit | только локальная конфигурация Xcode (`StoreKitTest`); Sandbox и TestFlight **не проверялись** |

ТЗ (раздел 18) прямо требует проверять камеру, разрешения, память, фон, почту и реальный Share на устройстве,
а покупки — в Sandbox/TestFlight. Поэтому ни один пункт ниже не отмечен как «принят на устройстве».
Локальная StoreKit-конфигурация не считается доказательством работы production IAP.

## Обозначения

- **PASS (авто)** — проверено автоматическим тестом, который проходит.
- **PASS (UI, симулятор)** — проверено UI-тестом в симуляторе (есть скриншоты в `Docs/Screenshots`).
- **ЧАСТИЧНО** — проверена логика или часть сценария; оставшееся нужно проверить на устройстве.
- **НЕ ПРОВЕРЕНО** — реализовано в коде, но проверить в этой среде нельзя (нужен iPhone или Sandbox).

Известных FAIL нет. Последний полный прогон на итоговом коде (симулятор iPhone 16, iOS 18.5): 101 юнит-тест — 0 падений
(5 генераторов образцов и замеров пропускаются без `TEST_RUNNER_SAMPLES_DIR`; отдельный запуск с ним прошёл); 14 UI-тестов —
0 падений (`test08` в сборке без адреса поддержки проверяет уведомление «not configured» и помечается пропущенным; с
`WP_SUPPORT_EMAIL` он прошёл полностью, и после того как владелец указал адрес поддержки, прошёл полностью в обычной сборке; 3 теста для скриншотов и App Preview запускаются только с `TEST_RUNNER_MARKETING_DIR` /
`TEST_RUNNER_PROMO_MARKS`, отдельные запуски прошли). Предупреждений компилятора нет. Бесплатный режим и paywall изменены по
решению владельца — см. A30 и `Docs/TZ-Changelog.md` п. 20–26.

## Сводка

| ID | Проверка | Статус | Чем подтверждено / фактическое поведение |
|---|---|---|---|
| A01 | Новый запуск, пропустить онбординг | PASS (UI, симулятор) | `test01`: онбординг из 2 шагов без запросов разрешений и paywall; `test02`: проект создан без оплаты и регистрации; `ImportUITests`: импорт с чистой установки. Скриншоты `en_01`, `en_02`, `en_07`–`en_09`, `import_00`–`import_03` |
| A02 | Запретить камеру | ЧАСТИЧНО | В симуляторе нет камеры: показан экран «Camera unavailable», импорт и проекты работают (`test01`, `en_03`). Экран отказа в доступе (Open Settings + Import) и отсутствие повторного системного запроса — по коду `CameraViewModel`, **на устройстве не проверено** |
| A03 | 20 фото в авиарежиме без GPS | ЧАСТИЧНО | Формирование PDF полностью локальное: сетевые API есть только в `ReverseGeocodingService`; отчёт из 20 кадров 12 МП собран за 3,1 с в симуляторе (`perf_12mp.txt`). Съёмка 20 кадров **на устройстве не проверена** |
| A04 | Разрешить approximate location | ЧАСТИЧНО | `testApproximateLocationIsMarked`, `testFreshnessAndAccuracy`: «Приблизительно» или точность хуже 100 м помечается как Approximate; `testApproximateCoordinatesHaveNoFalsePrecision`, `testApproximateLocationIsRoundedInEXIF`: координаты в приложении, штампе, PDF и EXIF округлены до реальной точности (±1 км → 2 знака). Адрес для приблизительного места запрашивается только до уровня района/города (код `ReverseGeocodingService`). Реальное разрешение «Приблизительно» и геокодер **на устройстве не проверены** |
| A05 | GPS после ухода с объекта | ЧАСТИЧНО | `testFreshnessAndAccuracy`: измерение позже 10 с после спуска или старше 30 с до него отклоняется (`.stale`), к кадру не привязывается. Реальное перемещение **не проверено** |
| A06 | Импорт фото без даты/GPS | PASS (авто + UI) | `testApplyMetadataSources`; `testManualAndImportedValuesAreMarkedInReport` (в PDF: «Capture time unavailable», «Imported; time zone unknown»); `ImportUITests` импортирует PNG без EXIF: «Unknown», «Imported», текущая дата и место не подставлены (`import_06`, `import_07`) |
| A07 | EXIF с/без timezone, смена timezone iPhone | PASS (авто) | `testEXIFWithOffsetBecomesAbsoluteInstant`, `testOffsetParsingAndDisplay`, `testSortByCaptureDateNeverInventsAbsoluteOrder`, `testDisplayDoesNotDependOnCurrentTimeZone` (смена зоны процесса Los Angeles → Tokyo не меняет отображение). Смена зоны в настройках реального iPhone не делалась |
| A08 | Исправить дату/адрес вручную | PASS (авто) | `testManualDateKeepsOriginalValues`, `testManualLocationIsMarkedAndCreatesNoCoordinates`: исходные значения сохранены; пометка «Manual» в штампе (`testProvenanceLabels`) и в тексте PDF (`testManualAndImportedValuesAreMarkedInReport`); ручные значения меняют только базу, файл оригинала не трогается (хэш при правках штампа — `testStampChangesKeepOriginalHash`) |
| A09 | Повернуть телефон, фронтальная камера | ЧАСТИЧНО | `testOrientationIsReadAndAppliedOnDecode`, `testRotatedOriginalExportsUpright`: EXIF-ориентация 6 даёт ровный результат и штамп. Поворот при съёмке (`AVCaptureDevice.RotationCoordinator` в `CameraViewModel`) и фронтальная камера (сохранение без зеркала в `CameraService`) — по коду, **на устройстве не проверено** |
| A10 | Экспорт «без места» | PASS (авто) | `testOriginalCopyWithoutLocationStripsGPS`, `testStampedJPEGLocationModes`, `testWithoutLocationRemovesPlaceFromStamp`; в PDF адрес объекта и места выключены по умолчанию (`testStandardPDFHasTextAndAllPages`) |
| A11 | SHA-256 оригинала до/после 5 правок штампа | PASS (авто) | `testStampChangesKeepOriginalHash` |
| A12 | 20/200 фото с длинными DE/FR/RU подписями | PASS (авто) | `testCyrillicAndDiacriticsAreSearchable` (текст извлекается из PDF), `testLongCaptionsAreKeptWhole` проверяет, что каждая подпись DE/FR/RU есть в раскладке целиком и рамка текста вмещает его; `testTwoHundredPhotoReportTiming` (запускается с `TEST_RUNNER_SAMPLES_DIR`: 200 фото с длинными DE и RU подписями, проверенный PDF из 101 страницы). Образец `Sample_Standard_RU_A4_Coordinates.pdf` проверен визуально |
| A13 | Портрет/альбом в «до/после» | PASS (авто + UI) | `testBeforeAfterOnePairPerPageAndMixedOrientation`, `testPhotosAreNeverCropped`; превью `en_20`, образец `Sample_BeforeAfter_EN_A4_Pro.pdf` |
| A14 | Прервать генерацию и повторить | ЧАСТИЧНО | `testCancelledJobRegistersNothing`, `testJobRegistersVerifiedReportVersion`: отмена не оставляет ReportVersion и файла, повтор создаёт проверенный отчёт. Прерывание фоном (истечение background task) — по коду, **на устройстве не проверено** |
| A15 | Нехватка места в середине записи | НЕ ПРОВЕРЕНО | Реализовано: проверка свободного места до записи (`FileStore.ensureSpace`, импорт, backup, отчёт), запись через временный файл и атомарное перемещение, БД обновляется только после файла. Реальное заполнение диска не проводилось (на машине разработки 4,8 ГБ свободно — рискованно) |
| A16 | Отменить Share | ЧАСТИЧНО | `test03`: системное окно Share открыто и закрыто без отправки — готовый PDF остался (`en_18b_share_sheet`). `share_completed` пишется только при положительном callback (код `PDFResultView`). Отправка в реальное приложение — на устройстве |
| A17 | StoreKit success/cancel/pending/error | ЧАСТИЧНО | StoreKitTest: покупка (`testPurchaseThenExpireAndRefund`), Ask to Buy → pending без Pro (`testAskToBuyIsPendingWithoutPro`), ошибка (`testFailedPurchaseKeepsFree`), неверифицированная транзакция (`testUnverifiedPurchaseDoesNotUnlock`). Пробный период 3 дня: предложение и право на него, состояние «пробный период», после покупки предложение исчезает (`testFreeTrialOfferAndEligibility`). Отмена пользователем — `StoreKitTest` её не симулирует, обработана в коде без ошибки. Повторная покупка блокируется (`isPurchasing`, кнопка неактивна). **Sandbox/TestFlight не проверены** |
| A18 | active → grace → expired/revoked | PASS (авто, локальный StoreKit) | `testGracePeriodAndBillingRetry`, `testPurchaseThenExpireAndRefund`, `testExpiredProWithManyProjects`; данные остаются доступны |
| A19 | Offline launch с действующей покупкой | НЕ ПРОВЕРЕНО | Права берутся только из `Transaction.currentEntitlements` (работает офлайн из кэша StoreKit), ошибка сети/загрузки продуктов не сбрасывает Pro. Нужна проверка на устройстве в авиарежиме |
| A20 | Выключить auto-renew | PASS (авто, локальный StoreKit) | `testAutoRenewOffKeepsAccessUntilExpiry`: Pro до окончания оплаченного периода, статус «продление отменено» |
| A21 | Restore после покупки/без покупок | ЧАСТИЧНО | `testRestoreWithoutPurchasesFindsNothing`; тексты: «Restoring purchases never restores photos — use Backups». Restore после покупки в Sandbox **не проверен** |
| A22 | Истекла Pro, проект 100 фото | PASS (авто) | `testExpiredProProjectKeepsAllPhotosAndArchiveCarriesNoPro`: все 100 фото видны, архив проекта содержит 100 оригиналов, оригинал экспортируется; `testExpiredProWithManyProjects`: проект только для чтения, без урезания до 20 |
| A23 | Backup → чистая установка → restore | PASS (авто) | `testRoundTripIntoCleanInstall` (файлы по SHA-256, подписи, ручные даты, места, пары, PDF, Unsorted, пресеты, новые ID); `testExpiredProProjectKeepsAllPhotosAndArchiveCarriesNoPro`: в manifest нет состояния покупок. Образец `Docs/Samples/Sample_Backup.zip` при генерации восстанавливается в чистую базу (`testGenerateSamples`); фикстура `valid_minimal` — `testValidMinimalFixtureRestores` |
| A24 | Повреждённый backup, zip slip, > лимита | PASS (авто) | `testHostileArchivesAreRefused` (10 враждебных архивов: отказ с кодом, проекты и фото не изменены, staging очищен, файл вне песочницы не создан), `testValidatorLimits` (2 ГБ, число записей, размер manifest) |
| A25 | Очистить кэш / удалить все данные | PASS (авто) | `testClearCacheNeverTouchesOriginalsOrReports`, `testDeleteAllData` |
| A26 | 5 языков, крупный шрифт, VoiceOver | ЧАСТИЧНО | `test05`: RU/DE/FR/ES — проекты, проект, настройки отчёта, PDF, настройки, камера, paywall (`*_07_paywall*`); `test06`: размер Accessibility L — проекты, paywall целиком до Restore, проект, камера (`a11y_*`); скриншоты просмотрены, обрезанных кнопок не найдено. VoiceOver: подписи и действия заданы в коде (статус фото, номер, источник), **полный проход с VoiceOver человеком не выполнялся** |
| A27 | Нет почты, support form не задана | PASS (UI, симулятор) | `test08` в сборке с тестовым адресом: в симуляторе нет почтового аккаунта и Mail — встроенный композер не показан, «Copy support email» копирует адрес, «Write in the mail app» сообщает, что почта не открылась (`en_30`, `en_31`). Без адреса сборка показывает «Support contact isn't configured», Release без адреса не собирается |
| A28 | Диагностика и события | PASS (авто) | `testDiagnosticsContainNoUserContent`, `testAnalyticsParametersAreWhitelisted`; провайдер аналитики не подключён, события только в отладочном журнале Debug |
| A29 | Дважды быстро нажать спуск/экспорт | ЧАСТИЧНО | По коду: спуск блокируется до сохранения кадра (`isCapturing`, кнопка неактивна, один `captureID` на кадр); экспорт, резервная копия и запуск отчёта защищены от повторного входа. Автотеста двойного нажатия нет; спуск — **на устройстве не проверен** |
| A30 | Архивировать Free-проект и создать новый | PASS (авто + UI) — **по изменённому ожиданию** | Решение владельца (`Docs/TZ-Changelog.md` п. 20–22): в Free 1 проект и 3 фото за всё время. `testArchivingOrDeletingDoesNotFreeTheProjectSlot`, `testUsageLedgerCountsForeverAndReconcilesUpward`; `test02`: второй проект → paywall, после архивации новый проект тоже → paywall с объяснением, черновик сохранён (`en_10`, `en_10b`, `en_10c`); `testFreePlanAllowsThreePhotosThenPaywall`: 3 фото импортируются, следующий импорт открывает paywall (`free_01`, `free_02`). Скрытого paywall нет: расход «Фото: N из 3», «Проекты: N из 1» виден в приложении |

## Дефекты, найденные на устройстве

| Дефект | Где | Причина | Исправление | Проверка |
|---|---|---|---|---|
| Переход из «Настроек» на любой экран (профиль, пресеты, поддержка, штамп, Pro) намертво подвешивал интерфейс, память росла | iPhone 13 Pro, iOS 17.1.2; в iOS 18.5 Simulator не воспроизводится | Ошибка SwiftUI в iOS 17.0–17.1: экран, читающий `@Environment(\.openURL)` и содержащий ссылки навигации, при переходе бесконечно перерисовывается. Найдено по spindump и бисекцией на устройстве (минимальная форма с одним `openURL` зависает, без него — нет) | Внешние ссылки открываются через `ExternalLink` (`UIApplication.shared.open`) во всех трёх экранах, где был `openURL`: «Настройки», «Поддержка», paywall | На устройстве после исправления «Pro» и «Штамп по умолчанию» открылись за 1,9 с (до исправления оба зависали); полный проход по всем экранам на устройстве не завершён — владелец попросил прекратить тесты на телефоне. В симуляторе — `test04`, `test09` |

## Производительность (раздел 17)

Цели ТЗ нужно измерять на iPhone 12. Здесь — только ориентир из симулятора на Mac:

| Замер | Результат в симуляторе | Цель ТЗ (iPhone 12) |
|---|---|---|
| Standard PDF из 20 кадров 12 МП | 3,1 с, 10 страниц, 25,2 МБ | ≤ 15 с |
| Отчёт из 200 кадров 12 МП | 27,3 с, 100 страниц; память процесса до/после 26 → 27 МБ, пик за всё время процесса 133 МБ (вместе с генерацией тестовых картинок) | без memory termination, время задокументировать |
| 200 кадров ~4 МП с длинными подписями DE/RU | 6,5 с, 101 страница | — |

Тестовые 12-МП кадры синтетические (градиент + текстура, в среднем 7,1 МБ JPEG): по декодированию они близки к
настоящим, но это не снимки камеры. В 200-кадровом замере 20 разных изображений повторяются, поэтому размер того PDF
не показателен (CoreGraphics хранит одинаковые картинки один раз). Исходные строки: `Docs/Samples/perf_12mp.txt`,
`Docs/Samples/perf_200_photos.txt`.

Не измерялись (нужен iPhone): холодный запуск ≤ 2,5 с, preview камеры ≤ 1,5 с, сохранение кадра 12 МП ≤ 2 с,
сетка 1 000 фото (миниатюры 480 px из кэша — по коду), 30 минут камеры без фонового GPS и нагрева.

## Что проверить на iPhone до релиза

1. A02, A03, A09, A29 — камера: отказ в доступе, 20 кадров в авиарежиме, поворот, фронтальная камера, быстрый двойной спуск.
2. A04, A05 — геолокация: «Приблизительно», уход с объекта, отказ, таймаут, адрес без сети.
3. A14, A15 — сворачивание во время генерации отчёта; заполненный диск.
4. A16 — реальная отправка PDF в Mail/Messages/Files и отмена.
5. A17–A21 — Sandbox и TestFlight: покупка, отмена, Ask to Buy, Restore на другом устройстве, офлайн-запуск, отключение автопродления.
6. A26 — полный проход VoiceOver: камера → проект → отчёт → покупка.
7. Раздел 17 — замеры на iPhone 12 и на минимальной iOS 17.
