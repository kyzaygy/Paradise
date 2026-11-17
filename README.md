# Paradise

VPN-клиент для подписок (VLESS, VMess, Trojan, Shadowsocks) на ядре Xray. Сначала iOS, дальше macOS, Windows и Linux.

Главная фишка — **перенос профиля**: подписки, избранное и настройки передаются QR-кодом, ссылкой `paradise://`, текстом или файлом `.paradise`. Перед импортом показывается предпросмотр, есть пароль и срок действия. Коды SVOI1 из [SVOI](https://github.com/1atex/svoi) читаются и создаются.

## Структура

| Путь | Что внутри |
| --- | --- |
| `core/` | Ядро на Go: подписки, хранилище, сборка Xray-конфигов, перенос профиля, проверка задержки. Общее для всех платформ. |
| `core/pdcore` | API для gomobile: `Open`, `Call(method, json)`, `StartTunnel`, `StopTunnel`. |
| `apple/` | iOS-приложение на SwiftUI и расширение Packet Tunnel. Проект генерируется XcodeGen из `project.yml`. |
| `scripts/build-ios.sh` | Сборка неподписанной IPA на macOS. |
| `docs/` | Формат переноса профиля и заметки к релизам. |

## Сборка

GitHub Actions (`.github/workflows/build.yml`) прогоняет тесты ядра, собирает `PDCore.xcframework` через gomobile и IPA на macOS-раннере. Тег `v*` публикует релиз.

Локально на Mac:

```sh
scripts/build-ios.sh
```

Нужны Xcode, Go 1.27 и XcodeGen (скрипт поставит его через Homebrew).

## Установка IPA

IPA не подписана. Подпишите приложение **и** вложенное `PlugIns/PacketTunnel.appex` профилями одной команды с правом `com.apple.developer.networking.networkextension = packet-tunnel-provider`. Bundle ID: `com.kyzaygy.paradise` и `com.kyzaygy.paradise.tunnel` (можно поменять при переподписи, приложение находит расширение само). Без этого права iOS не даст создать VPN.

## Безопасность

- Данные на устройстве зашифрованы AES-256-GCM, ключ хранится в Keychain (только это устройство).
- Коды переноса — секрет: не логируются и никуда не отправляются. Пароль — Argon2id + AES-256-GCM.
- Нет аналитики и своих серверов. Запросы уходят только к серверу подписки и выбранному VPN-серверу.

## Лицензии

Xray-core — MPL-2.0. Части парсера ссылок и пакетного канала адаптированы из SVOI (MIT, © 2026 SVOI contributors). Тексты лицензий лежат в `third_party/` и внутри приложения.
