# Release configuration checklist

Отмечать по мере выполнения. Пункты с пометкой **владелец** — решения и доступы, которые разработчик не может
выдумать (раздел 20 ТЗ).

## 1. Данные от владельца

- [ ] **владелец** Доступ к Apple Developer Program и App Store Connect; принятые соглашения Paid Apps, налоги и банк.
- [x] **владелец** Bundle ID `com.stamvio.work.photos.camera`, Team `3B4YZ93BS3` (заданы в настройках таргета).
- [x] **владелец** Название: **Stamvio**; в App Store — названия и subtitle по языкам из `Docs/ASO-Draft.md`.
- [ ] **владелец** Проверить доступность названий в App Store Connect и товарные знаки «Stamvio».
- [x] **владелец** Имя под иконкой: «Stamvio» (`INFOPLIST_KEY_CFBundleDisplayName` и `InfoPlist.xcstrings`).
- [ ] **владелец** Окончательные цены по регионам (проектные: $4.99 / месяц, $29.99 / год).
- [ ] **владелец** Email поддержки, URL политики конфиденциальности и условий, при желании — URL формы поддержки.
- [ ] **владелец** Имя разработчика/компании для документов и App Store.

## 2. Конфигурация сборки

- [x] `Config/Shared.xcconfig`: `WP_SUPPORT_EMAIL` = reginadanilova82@icloud.com
- [x] `Config/Shared.xcconfig`: `WP_PRIVACY_POLICY_URL` = https://stamvio.site/privacy.html, `WP_TERMS_URL` = https://stamvio.site/terms.html
- [ ] **владелец** SSL-сертификат для stamvio.site и www.stamvio.site (сейчас хостинг отдаёт общий `*.web-hosting.com`,
      по https сайт не открывается) и перенаправление http → https. Проверить до отправки на ревью.
      (URL пишется как `https:/$()/domain.tld/path`); опционально `WP_SUPPORT_FORM_URL`, `WP_APP_STORE_ID`.
- [ ] Release-сборка проходит фазу «Release configuration check» (без заполненных контактов сборка падает —
      проверено; заглушки вида example.com и URL не по https отвергает тот же скрипт, а приложение — `EnvironmentConfig`,
      см. `testMissingAndPlaceholderValuesAreRejected`).
- [ ] `MARKETING_VERSION` (сейчас 1.0) и `CURRENT_PROJECT_VERSION` (сейчас 1) увеличены для каждой загрузки.
- [ ] Archive делается в конфигурации Release (Production): StoreKit-конфигурация в Archive не используется,
      отладочные аргументы `-uitest-*` и образец проекта вырезаны (`#if DEBUG`).
- [ ] Иконка: проверить светлый, тёмный и tinted вариант на устройстве (`Assets.xcassets/AppIcon.appiconset`).
- [ ] `ITSAppUsesNonExemptEncryption = NO`: в приложении нет шифрования, только SHA-256 для проверки целостности.
      Владелец подтверждает ответ export compliance.

## 3. Покупки (StoreKit 2)

- [ ] В App Store Connect создана subscription group с `workphotos.pro.monthly` и `workphotos.pro.yearly` одного уровня
      (если ID меняются — поправить `ProductCatalog` и `Products.storekit`).
- [ ] Для каждого продукта: цена, период, локализации на 5 языках, Review screenshot paywall, Review notes.
- [ ] **Introductory offer «Free trial, 3 days»** для новых подписчиков на `workphotos.pro.monthly` и
      `workphotos.pro.yearly` (решение владельца, `Docs/TZ-Changelog.md` п. 25), во всех регионах продаж.
      Lifetime в v1 нет.
- [ ] Sandbox: пробный период показывается только новому пользователю, после использования кнопка становится
      «Continue with Yearly/Monthly»; списание после окончания пробного периода; отмена во время пробного периода.
- [ ] Review notes: «Free plan: 3 photos and 1 project in total; the 4th photo or 2nd project opens the paywall.»
- [ ] Sandbox: покупка месяц/год, отмена, Ask to Buy, ошибка сети, Restore без покупок и на втором устройстве,
      отключение автопродления, истечение, grace period (если включён в App Store Connect), возврат.
- [ ] TestFlight: те же сценарии на сборке из Archive.
- [ ] Экран покупки показывает цены из StoreKit, условия автопродления, ссылки Terms/Privacy, Restore, Close (Manage в приложении нет — решение владельца).

## 4. Приватность и документы

- [ ] Политика конфиденциальности упоминает: всё хранится на устройстве; координаты отправляются Apple для получения
      адреса, только при включённых геоданных; резервные копии создаёт и хранит пользователь; аналитики нет;
      счётчик бесплатного лимита (два числа) хранится в Keychain и сохраняется после удаления данных и переустановки.
- [ ] App Privacy в App Store Connect заполнен по `Docs/PrivacyDataMap.md` (предложено «Data Not Collected»; решение — за владельцем).
- [ ] `PrivacyInfo.xcprivacy` соответствует коду (UserDefaults CA92.1, DiskSpace E174.1/85F4.1); после добавления SDK — пересмотреть.
- [ ] Возрастной рейтинг, категория (сейчас Productivity), права на контент.

## 5. Проверка на устройствах

- [ ] iPhone 12 (базовое устройство) и актуальная модель; минимальная iOS 17.x.
- [ ] Все пункты «ЧАСТИЧНО» и «НЕ ПРОВЕРЕНО» из `Docs/AcceptanceReport.md`.
- [ ] Замеры раздела 17 ТЗ на iPhone 12 записаны в отчёт приёмки.
- [ ] VoiceOver: камера → проект → отчёт → покупка; Dynamic Type до AX5; Reduce Motion; тёмная тема.
- [ ] Реальная отправка PDF клиенту: Mail, Messages, WhatsApp/Telegram (если установлены), Files.

## 6. Материалы App Store

- [ ] Скриншоты из фактической сборки в размерах, которые App Store Connect требует на момент загрузки
      (сейчас в `Docs/Screenshots` — iPhone 16 Simulator, 1178×2556; для страницы магазина нужны требуемые размеры).
- [ ] Тексты по `Docs/ASO-Draft.md` для 5 языков, без обещаний, которые не подтверждены (см. раздел «Нельзя обещать»).
- [ ] URL поддержки и маркетинговый URL (если есть) открываются.

## 7. Перед отправкой на review

- [ ] Полный прогон: `xcodebuild test` (юнит + UI) и `python3 Tools/check_localization.py` без ошибок.
- [ ] Release-сборка без предупреждений конфигурации.
- [ ] Удалены тестовые медиа из симуляторов/устройств, где делались скриншоты для магазина.
- [ ] Дата одобрения Apple не обещается.
