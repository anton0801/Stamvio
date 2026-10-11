# ASO-черновик (App Store)

Название и subtitle утверждены владельцем (11.10.2026): приложение называется **Stamvio**, под иконкой — «Stamvio».
Доступность имени в App Store Connect и товарные знаки нужно проверить до публикации. Все утверждения ниже соответствуют реализованным функциям; список того, что
обещать нельзя, — в конце.

Лимиты App Store: название и subtitle — до 30 символов, keywords — до 100, promotional text — до 170.
Длины ниже посчитаны скриптом.

## Английский (основной)

**Name (25):** Stamvio: Timestamp Camera

**Subtitle (28):** Date, GPS & PDF Work Reports

**Keywords (96):** `stamp,before after,photo log,job site,contractor,cleaning,cleaner,geotag,inspection,construction`

Keywords не повторяют слова из названия и subtitle: App Store индексирует их вместе, повтор только тратит символы.

**Promotional text (150):** Take work photos with a date stamp, add captions and send your client a clean PDF photo
report. No account needed — your projects stay on your iPhone.

**Description:**

Photograph the finished job and send your client a neat photo report.

Stamvio is made for cleaners, contractors, installers and anyone who reports work with photos.

CAPTURE
• Camera with an optional stamp: date and time, project name, address, coordinates and a short caption
• Three presets (Compact, Work, Location), stamp size and position, live preview
• The original photo is always kept without the stamp — change the stamp later at any time
• Location is off until you turn it on; approximate locations are marked as approximate
• Quick shots go to Unsorted and can be moved to a project later

IMPORT
• Add photos from your library, up to 50 at a time
• Dates and places from the file are marked as imported; if the file has no date, the app says so instead of
  guessing

PROJECTS
• Projects with site, client, notes and work date; captions, sorting and archive
• Before/after pairs: choose the two photos, title and note

PDF REPORTS
• Standard report with up to two photos per page, A4 or Letter
• Before/After report with one pair per page (Pro; free preview with a watermark)
• Report language independent of the app language: English, Spanish, Russian, German, French
• Locations are off in reports by default — you choose what to publish
• Searchable text, page numbers, your name and contact; logo with Pro
• Share or save to Files; previous report versions stay in the project

EXPORT AND BACKUP
• Stamped JPEG or original files, with or without location
• Back up all data to a ZIP file in Files and restore it on another iPhone

PRIVACY
• No account, no server, no ads, no analytics
• Projects, photos and reports stay on your device unless you share them
• To show an address, coordinates are sent to Apple's geocoding service — only when location is on

FREE AND PRO
Free: try the whole flow with 3 photos and 1 project — stamp, Standard PDF, stamped JPEG up to 2560 px, backups. Your
files and reports always stay available.
Pro: any number of projects up to 1,000 photos each, reports up to 200 photos, Before/After reports up to 100 pairs,
logo and brand presets, no "Created with" line, full-resolution and batch export.

Pro is an auto-renewable subscription (monthly or yearly) with a 3-day free trial for new subscribers. After the trial
the subscription price is charged to your Apple Account unless you cancel at least 24 hours before the trial ends. The
subscription renews automatically unless auto-renew is turned off at least 24 hours before the end of the current
period. Manage or cancel in your Apple Account settings. If your subscription ends, all your projects, photos and
reports stay available. Terms: [WP_TERMS_URL] · Privacy: [WP_PRIVACY_POLICY_URL]

## Другие языки

| Язык | Name | Subtitle | Keywords |
|---|---|---|---|
| RU (21 / 27 / 92) | Stamvio: Дата на фото | GPS, время и PDF-фотоотчёты | `штамп,до после,объект,ремонт,уборка,клининг,подрядчик,геометка,камера,отметка,стройка,мастер` |
| DE (27 / 28 / 94) | Stamvio: Zeitstempel-Kamera | GPS-Fotos & PDF-Fotoberichte | `datum,vorher nachher,baustelle,handwerker,reinigung,geotag,protokoll,bautagebuch,dokumentation` |
| FR (26 / 25 / 99) | Stamvio: Photos horodatées | Date, GPS et rapports PDF | `horodatage,avant après,chantier,artisan,nettoyage,géolocalisation,suivi,intervention,caméra,travaux` |
| ES (24 / 29 / 97) | Stamvio: Fotos con Fecha | GPS e informes PDF de trabajo | `marca de tiempo,sello,antes despues,obra,contratista,limpieza,geoetiqueta,cámara,reforma,registro` |

Цифры в скобках — длина name / subtitle / keywords (лимиты 30 / 30 / 100).

Описание на RU/DE/FR/ES — перевести английский текст выше без добавления новых обещаний; переводы приложения
для формулировок функций уже есть в `Localizable.xcstrings`. Перевод магазина нужно вычитать носителями
(бюджет ТЗ: до $150 на проверку пяти языков).

## Скриншоты для магазина (только реализованные экраны)

Готовый набор для App Store (1320×2868, 8 кадров на каждый из 5 языков) лежит вне проекта:
`~/Desktop/WorkPhotos-AppStore-Screenshots/appstore/<lang>/01–08.png`. Ниже — исходный план.

Снимать с фактической сборки на устройстве или симуляторе нужного размера. Порядок и подписи:

1. Камера со штампом — «Date stamp on every work photo» (на устройстве: в симуляторе нет камеры).
2. Проект с сеткой фото — «Projects for every job» (`en_12_project_photos`).
3. Готовый PDF — «Send a clean PDF report» (`en_18_report_ready`).
4. Пара до/после — «Before and after, side by side» (`en_20_before_after_preview`, отметить как Pro).
5. Настройки отчёта с приватностью — «You choose what to publish» (`en_17_report_settings_privacy`).
6. Отчёт на другом языке — «Reports in 5 languages» (`de_04_report_pdf` и др.).

Скриншоты в `Docs/Screenshots` сняты в iPhone 16 Simulator на тестовых данных проекта «Sample» — для магазина
переснять в требуемых App Store Connect размерах.

## Нельзя обещать (не реализовано или не подтверждено)

- Юридическую силу, «доказательство», защиту от подделки или подлинность снимка: SHA-256 в копиях — только проверка
  целостности файла.
- Точность места или «проверенный GPS»: место может быть приблизительным, ручным или недоступным, и это помечается.
- Автоматическую отправку клиенту, подтверждение доставки или прочтения: отправка — через системное меню Share.
- Облачную синхронизацию, командную работу, iPad, Mac, Android, веб-версию.
- Получение адреса без сети (без сети сохраняются координаты, адрес — позже).
- Восстановление фото через «Restore Purchases»: данные переносятся только через резервную копию.
- Конкретный размер PDF, время генерации или скорость до измерений на устройстве.
- Пожизненную покупку, скидку «50 %» (при текущих ценах экономия 49 %), «бесплатно навсегда» (Free — 3 фото и
  1 проект). Пробный период 3 дня упоминать только вместе с ценой после него и только пока он настроен в App Store Connect.
- Рейтинги, число пользователей, «№ 1», упоминания чужих брендов и приложений.
