# Stamvio — iOS MVP

Название продукта: **Stamvio** (под иконкой — «Stamvio»; в App Store — «Stamvio: Timestamp Camera», subtitle
«Date, GPS & PDF Work Reports»; названия для других языков — в `Docs/ASO-Draft.md`). Проект, таргеты и внутренние
идентификаторы в Xcode сохранили рабочее имя `TimestampCameraWorkPhotos` — см. `Docs/TZ-Changelog.md` п. 30.
Обещание: «Сфотографируйте выполненную работу и отправьте клиенту аккуратный фотоотчёт».

Приложение реализовано по ТЗ v1.0 от 08.10.2026: iPhone, iOS 17+, Swift/SwiftUI, локальная работа без
регистрации и собственного сервера, StoreKit 2, 5 языков (EN/ES/RU/DE/FR).

> Что проверено и что ещё нужно проверить на реальном iPhone — см. [Docs/AcceptanceReport.md](Docs/AcceptanceReport.md).
> Отступления и уточнения к ТЗ — [Docs/TZ-Changelog.md](Docs/TZ-Changelog.md).
> Данные, SDK и сеть — [Docs/PrivacyDataMap.md](Docs/PrivacyDataMap.md); выпуск — [Docs/ReleaseChecklist.md](Docs/ReleaseChecklist.md);
> тексты магазина — [Docs/ASO-Draft.md](Docs/ASO-Draft.md); скриншоты реальных экранов — `Docs/Screenshots/`.

## Требования

- Xcode 16.4 (проверено), iOS SDK 18.5; минимальная iOS — 17.0.
- Swift 5 language mode (компилятор Swift 6.1).
- Зависимость: [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) **0.9.20** (exact version, MIT). Используется
  только для ZIP-архивов резервных копий и пакетного экспорта. Текст лицензии в приложение не включён по решению
  владельца (см. `Docs/TZ-Changelog.md` п. 27).

Если `xcode-select` указывает на Command Line Tools, команды ниже нужно запускать с
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` или один раз выполнить
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

## Сборка и запуск

```bash
open TimestampCameraWorkPhotos.xcodeproj
```

Схема **TimestampCameraWorkPhotos** (shared):
- Run (Debug / Development) использует StoreKit-конфигурацию `TimestampCameraWorkPhotosTests/StoreKit/Products.storekit`
  — покупки симулируются локально.
- Test запускает юнит-тесты и UI-тесты.
- Archive (Release / Production) — без StoreKit-конфигурации, без отладочного кода.

Из командной строки:

```bash
xcodebuild -project TimestampCameraWorkPhotos.xcodeproj -scheme TimestampCameraWorkPhotos -destination 'platform=iOS Simulator,name=iPhone 16' build
```

## Окружения Development / Production

| | Debug (Development) | Release (Production) |
|---|---|---|
| xcconfig | `Config/Development.xcconfig` | `Config/Production.xcconfig` |
| StoreKit | локальная конфигурация (только Run и тесты) | App Store / Sandbox / TestFlight |
| Отладочные аргументы `-uitest-*` | есть (`App/DebugSeeding.swift`) | вырезаны компилятором |
| Проверка конфигурации | предупреждение | **ошибка сборки**, пока не заполнены контакты |

Контакты и документы задаются в `Config/Shared.xcconfig` (а не в коде) и читаются `EnvironmentConfig` из Info.plist:

| Ключ | Назначение | Обязателен для Release |
|---|---|---|
| `WP_SUPPORT_EMAIL` | email поддержки | да |
| `WP_PRIVACY_POLICY_URL` | политика конфиденциальности (https) | да |
| `WP_TERMS_URL` | условия использования (https) | да |
| `WP_SUPPORT_FORM_URL` | внешняя форма поддержки (https) | нет |
| `WP_APP_STORE_ID` | числовой App Store ID (хранится в `EnvironmentConfig`, в интерфейсе v1 не используется) | нет |

В `.xcconfig` `//` начинает комментарий, поэтому URL пишется как `https:/$()/domain.tld/privacy`.
Заглушки вида `example.com` отвергаются и сборкой, и приложением.

## StoreKit: тестовая конфигурация и реальные продукты

Проектные идентификаторы (одна subscription group, один уровень `groupNumber = 1`):

| Product ID | Тип | Тестовая цена (US) |
|---|---|---|
| `workphotos.pro.monthly` | auto-renewable, 1 месяц | $4.99 |
| `workphotos.pro.yearly` | auto-renewable, 1 год | $29.99 |

Цены в интерфейсе всегда берутся из StoreKit (`Product.displayPrice`), экономия годового плана считается из реальных цен
одной валюты и округляется вниз (при тестовых ценах — 49 %). Длительность пробного периода и право на него — тоже из
StoreKit (`introductoryOffer`, `isEligibleForIntroOffer`).

Бесплатный режим: 3 фото и 1 проект за всё время (`AccessPolicy.freeLifetimePhotoLimit`, `freeLifetimeProjectLimit`).
Счётчик — `Services/Purchases/UsageLedger.swift`, хранится в Keychain и не сбрасывается удалением данных.

Создание в App Store Connect:
1. Уточнить префикс идентификаторов (если меняется — поправить `ProductCatalog` в
   `Services/Purchases/EntitlementService.swift` и `Products.storekit`).
2. App Store Connect → приложение → Subscriptions → создать группу «Pro», в ней два продукта одного уровня.
3. Указать цены, периоды, локализованные названия/описания (тексты есть в `Products.storekit`), Review screenshot.
4. Introductory offer «Free trial, 3 days» на обоих продуктах (решение владельца; в `Products.storekit` он уже есть,
   paywall показывает его только при подтверждённом праве). Lifetime нет.
5. Проверить в Sandbox и TestFlight: покупка, отмена, Ask to Buy, Restore, отключение автопродления в Настройках iPhone.

## Тесты

```bash
# юнит-тесты + UI-тесты на симуляторе
xcodebuild test -project TimestampCameraWorkPhotos.xcodeproj -scheme TimestampCameraWorkPhotos -destination 'platform=iOS Simulator,name=iPhone 16'

# UI-тесты со скриншотами в папку
TEST_RUNNER_SCREENSHOT_DIR=/path/to/shots xcodebuild test ... -only-testing:TimestampCameraWorkPhotosUITests

# образцы для сдачи (PDF, JPEG, backup) и замеры отчётов (200 фото, 20/200 кадров 12 МП)
TEST_RUNNER_SAMPLES_DIR=$PWD/Docs/Samples xcodebuild test ... -only-testing:TimestampCameraWorkPhotosTests/DeliverablesTests

# проверка поддержки с настроенным адресом (A27): адрес только для теста, в xcconfig не сохраняется
xcodebuild test ... -only-testing:TimestampCameraWorkPhotosUITests/WalkthroughUITests/test08_SupportWithoutMailApp WP_SUPPORT_EMAIL=support@check.invalid

# проверка локализации: все ключи из кода есть во всех 5 языках, спецификаторы совпадают
python3 Tools/check_localization.py
```

Покрытие юнит-тестами (101 тест, из них 5 в `DeliverablesTests` запускаются только с `TEST_RUNNER_SAMPLES_DIR`): источник даты и часовые пояса, ручные значения, EXIF/GPS/ориентация, лимиты импорта,
критерии актуальности геолокации, геометрия штампа (отступ ≥3 %, нормализованная раскладка, переносы, переполнение),
раскладка PDF (поля ≥14 мм, ≤2 фото на страницу, «до/после» без обрезки, длинные подписи DE/FR/RU), реальная генерация PDF
с извлечением текста, правила Free/Pro и счётчик бесплатного лимита, округление экономии, StoreKitTest (пробный период, покупка, Ask to Buy, ошибка, неверифицированная
транзакция, истечение, возврат, grace period, billing retry, отключение автопродления, Restore), экспорт с/без GPS,
резервная копия (полный цикл с remapping ID, конфликты, враждебные архивы), reconciliation, аналитика, конфигурация релиза.

UI-тесты (11 + 3 маркетинговых, которые запускаются только с `TEST_RUNNER_MARKETING_DIR` / `TEST_RUNNER_PROMO_MARKS`): онбординг, камера без устройства, лимит Free (второй проект и проект после архивации → paywall,
черновик сохраняется), 3 бесплатных фото → следующий импорт открывает paywall, фото, пары, отчёты (Standard и превью
«до/после»), закрытие системного Share без потери PDF, настройки, 4 других языка с paywall, крупный шрифт с paywall,
поддержка без почтового приложения, смена языка внутри приложения, импорт фикстур через системный PhotosPicker с проверкой отказов.

Отладочные аргументы запуска (только Debug): `-uitest-reset` (пустое состояние и сброс счётчика Free),
`-uitest-skip-onboarding`, `-uitest-seed` (образец проекта с пометкой Sample), `-uitest-showcase` (вместе с `-uitest-seed`:
демо-названия без пометки Sample для скриншотов и App Preview), `-uitest-free-photo-quota N` (больше
бесплатных фото, чтобы тест импорта проверил все фикстуры), `-uitest-pro-preview` (подписка Pro без StoreKit, для скриншотов).

Маркетинговые материалы (пропускаются в обычном прогоне):

```bash
# скриншоты экранов для сайта и App Store
TEST_RUNNER_MARKETING_DIR=/path/to/shots xcodebuild test ... -only-testing:TimestampCameraWorkPhotosUITests/MarketingCaptureUITests

# сценарий для записи App Preview (параллельно: xcrun simctl io booted recordVideo raw.mov)
TEST_RUNNER_PROMO_MARKS=/tmp/marks.json xcodebuild test ... -only-testing:TimestampCameraWorkPhotosUITests/PromoRecordingUITests

# проштампованные JPEG нарисованных комнат (экспорт приложения) для сайта
TEST_RUNNER_SAMPLES_DIR=/path/to/out xcodebuild test ... -only-testing:TimestampCameraWorkPhotosTests/DeliverablesTests/testExportShowcaseStampedPhotos
```

## Тестовые примеры (fixtures)

- `TestFixtures/Photos/` — фото с EXIF+offset+GPS, без offset, без EXIF (PNG), orientation 6, портрет/альбом для пар,
  63 МП (должен отклоняться), анимированный GIF (отказ), обрезанный JPEG (отказ), файл с длинными подписями DE/FR/RU.
  Генератор: `swift Tools/make_photo_fixtures.swift TestFixtures/Photos`. В симулятор: `xcrun simctl addmedia booted <файлы>`.
- `TimestampCameraWorkPhotosTests/Fixtures/` — повреждённые и враждебные резервные копии (zip slip, абсолютный путь,
  symlink, нет manifest, будущая версия, неверная контрольная сумма, ложный размер, нарушенные связи, не-ZIP) и одна
  корректная. Генератор: `python3 Tools/make_backup_fixtures.py TimestampCameraWorkPhotosTests/Fixtures`.
- `Docs/Samples/` — образцы Standard/Before-After PDF, JPEG со штампом, восстановимая резервная копия, замеры
  (`perf_200_photos.txt`, `perf_12mp.txt`).
- Иконка генерируется скриптом `swift Tools/make_app_icon.swift TimestampCameraWorkPhotos/Assets.xcassets/AppIcon.appiconset`.

## Архитектура

```
TimestampCameraWorkPhotos/
  App/            точка входа, AppEnvironment (composition root), AppRouter, EnvironmentConfig, DebugSeeding (DEBUG)
  Core/           L10n (+ язык отчёта независимо от языка UI), AppError (коды без пользовательских данных), DateTime
  Data/           SwiftData SchemaV1 (versioned + migration plan), ProjectRepository, FileStore, Reconciler
  Services/
    Camera/       CameraService (AVFoundation, своя очередь), CaptureCoordinator (файл → БД → «Saved», геоданные кадра)
    Import/       PhotoImportService (PhotosPicker, поштучные статусы), ImageInspector (ImageIO), ImageLoader, ThumbnailStore
    Location/     LocationService (When In Use, критерии 30 с / 100 м, таймаут 10 с), ReverseGeocodingService (адаптер провайдера)
    Stamp/        StampRenderer (одна геометрия для превью и файла), TextBox (CoreText)
    Report/       ReportSnapshot (immutable), ReportLayout (пагинация), ReportBuilder (UIGraphicsPDFRenderer), ReportService
    Export/       ImageExporter (stamped JPEG, оригинал без GPS, ZIP, Photos add-only)
    Backup/       BackupManifest + валидатор, BackupService (ZIPFoundation, staging, remapping ID)
    Purchases/    EntitlementService (StoreKit 2), AccessPolicy (правила Free/Pro, чистая логика)
    Analytics/    AnalyticsService (типизированные события, сбор выключен)
    Support/      SupportComposer, Diagnostics
  Features/       SwiftUI-экраны S01–S21
  UI/             общие компоненты (миниатюры, Share, Files, Mail, PDFKit, баннеры, тосты)
  Resources/      Localizable.xcstrings, InfoPlist.xcstrings
  PrivacyInfo.xcprivacy
```

Хранение: БД `Application Support/WorkPhotos/Database`, оригиналы `Originals/`, отчёты `Reports/<id>/` (PDF + snapshot.json),
логотипы `Logos/`; миниатюры и кэш — в `Caches` (восстанавливаемые). Модели хранят только относительные пути.

## Известные ограничения v1

- Камера, геолокация, Save to Photos, почта, Share sheet и фоновое прерывание отчёта не проверялись на реальном iPhone
  (в симуляторе нет камеры и GPS) — см. отчёт приёмки.
- Автотесты идут в iOS 18.5 Simulator; среда iOS 17 в этой системе не установлена. На iPhone с iOS 17.1.2 найдено и
  исправлено зависание навигации из-за ошибки SwiftUI 17.0–17.1 с `@Environment(\.openURL)` — в коде его не использовать,
  внешние ссылки открывать через `ExternalLink`.
- Адрес по координатам получается через `CLGeocoder` (в SDK 18.5 нет `MKReverseGeocodingRequest`); при переходе на SDK
  с новым API добавить адаптер в `ReverseGeocodingService` (протокол уже выделен).
- Замеры производительности сделаны в симуляторе на синтетических изображениях; целевые значения раздела 17 нужно
  измерить на iPhone 12.
