# MAX Desktop

**Основное** десктопное приложение для Windows (Flutter / Dart) с встроенным браузером **WebView2** и официальным **[web.max.ru](https://web.max.ru)**.

> Старый Node.js/Electron проект (`max-accounts-manager`) помечен как **LEGACY** и больше не развивается.

Каждый аккаунт — отдельный профиль браузера (cookies и сессия изолированы). Для **web.max.ru** — официальный сайт; для **регистрации/входа по SMS** — встроенный CLI через неофициальный API MAX.

## Возможности

- Несколько аккаунтов MAX в одном приложении
- **Вход / регистрация по SMS** прямо в приложении (новый номер или существующий)
- Встроенный браузер с официальным web.max.ru (QR-вход для автоматизации на сайте)
- Отдельное хранилище сессии для каждого профиля + изоляция отпечатка браузера
- Автоматизация на странице MAX (автоответы, сценарии с кликами)
- Журнал событий автоматизации

## Требования (разработка)

- Windows 10/11
- [Flutter SDK](https://docs.flutter.dev/get-started/install)
- [Microsoft Edge WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) (обычно уже есть)
- [Node.js 18+](https://nodejs.org) — только для разработки SMS/CLI (`tools/max_auth`)

## Установка для пользователей (Windows)

Соберите установщик на своём ПК:

```powershell
cd max-desktop
.\scripts\build_windows.ps1
```

В папке `release/` появятся:

- `MAX-Desktop-Setup-1.0.1.exe` — установщик (ярлык в меню Пуск)
- `MAX-Desktop-Portable-1.0.1.zip` — портативная версия без установки

Пользователю достаточно запустить Setup.exe. **Отдельно ставить Flutter и Node.js не нужно** — Node встроен в пакет.

> Windows может показать SmartScreen (нет цифровой подписи). Нажмите «Подробнее» → «Выполнить в любом случае».
> Нужен WebView2 Runtime (на Windows 10/11 обычно уже установлен).

### Автообновление

При запуске приложение проверяет `http://145.63.130.142:8080/latest.json`.
Если версия новее — предлагает скачать и установить.

Выкладка новой версии на сервер:

```powershell
.\scripts\deploy_update.ps1
```

Первый раз (один пароль root → ставит HTTP-uploader + deploy-ключ без фразы):

```powershell
$env:UPDATE_SERVER_PASSWORD = '...'   # только для bootstrap
python .\scripts\bootstrap_update_deploy.py
.\scripts\deploy_update.ps1
```

Дальше пароль не нужен: заливка идёт на `http://…:8080/_deploy/upload` по токену из `scripts/.deploy_secrets` (в git не попадает). Fallback — SCP с ключом `~/.ssh/max_desktop_deploy`.

## Запуск (разработка)

```bash
cd max-desktop
flutter pub get
cd tools/max_auth && npm install && cd ../..
flutter run -d windows
```

## Сборка exe (без установщика)

```bash
flutter build windows --release
```

Готовое приложение: `build/windows/x64/runner/Release/max_desktop.exe`

Для SMS/матки рядом с exe нужна папка `tools/max_auth/` (и лучше встроенный `tools/node/` — их кладёт `build_windows.ps1`).

### Вариант A: SMS (регистрация или вход)

1. Нажмите **«Вход / регистрация SMS»** в левой панели
2. Введите номер телефона → **Отправить код**
3. Введите код из SMS (или из приложения MAX)
4. При необходимости — пароль 2FA
5. Аккаунт появится в списке с сохранённым API-токеном
6. Для **автоматизации на web.max.ru** откройте профиль и при необходимости отсканируйте QR

> SMS-модуль использует неофициальный API. Без RU-IP MAX может блокировать отправку кода (captcha). Рекомендуется VPN с российским IP.

### Вариант B: QR (только web.max.ru)

1. **«Профиль + QR»** — задайте название
2. В центральной панели откроется **web.max.ru**
3. Отсканируйте QR в приложении MAX на телефоне
4. Сессия сохранится в профиле браузера
5. Справа добавьте **правила автоматизации** или **сценарии**
6. Откройте нужный чат — скрипт работает на странице MAX

### Вариант C: Android-эмулятор (регистрация +998 и др.)

1. Создайте профиль → **«Эмулятор Android»** (иконка телефона на аккаунте)
2. Нужен **Android Studio** + system-image **x86_64** (Android 33+)
3. **Создать AVD** → **Запустить** → установите MAX (APK или Play Store)
4. **Открыть MAX** → зарегистрируйте номер в приложении
5. Вернитесь в MAX Desktop → **«Профиль + QR»** → отсканируйте QR из эмулятора

Каждый профиль получает **отдельный AVD** (изолированные данные Android).

## Сборка exe

```bash
flutter build windows
```

Готовое приложение: `build/windows/x64/runner/Release/max_desktop.exe`

Для SMS-входа в release-сборке рядом с exe должна быть папка `tools/max_auth/` с выполненным `npm install`.

## Где хранятся данные

```
%APPDATA%/com.maxmanager.max_desktop/max_desktop/
├── data.json           # список аккаунтов и правил
└── profiles/{id}/      # cookies и сессия WebView2 для каждого аккаунта
```

## Автоматизация

Скрипт внедряется в web.max.ru и:

- следит за новыми сообщениями через `MutationObserver`
- ищет поле ввода и кнопку отправки на странице
- отправляет автоответ по заданным ключевым словам

> DOM сайта MAX может меняться. Если автоответ перестал работать — используйте кнопку «Сканировать чат сейчас» и смотрите журнал справа.

## Структура

```
lib/
├── main.dart
├── app.dart
├── models/
├── services/          # storage, browser, automation JS
├── providers/
├── screens/
└── widgets/
```
