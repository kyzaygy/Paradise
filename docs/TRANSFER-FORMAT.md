# Формат переноса профиля

## PD1 (Paradise)

```
PD1.<base64url без паддинга(header || body)>
```

Заголовок (big-endian):

| Байты | Поле |
| --- | --- |
| 0 | версия контейнера = 1 |
| 1 | флаги: bit0 — зашифровано, bit1 — gzip (всегда 1) |
| 2..9 | срок действия, unix-секунды, 0 — без срока |
| 10..25 | соль (только если зашифровано) |
| 26 | KDF: 1 = Argon2id |
| 27 | Argon2: time |
| 28..31 | Argon2: memory, KiB |
| 32 | Argon2: threads |
| 33..44 | nonce AES-256-GCM |

Тело — `gzip(JSON)`. Если код зашифрован: `AES-256-GCM(key = Argon2id(password, salt), aad = header)`. Срок действия проверяет приложение. У зашифрованного кода срок защищён (он входит в AAD), у открытого — нет.

JSON (`v = 1`):

```json
{
  "v": 1,
  "crit": [],
  "app": "Paradise/0.1.0",
  "created": 1763400000,
  "name": "",
  "subscriptions": [
    { "name": "Provider", "url": "https://…" },
    { "name": "Configs", "servers": [ { "name": "NL", "outbound": { } }, { "name": "Full", "profile": { } } ] }
  ],
  "favorites": ["<server key>"],
  "selected": "<server key>",
  "settings": { "mode": "all", "killSwitch": false, "autoRefresh": true, "sendHwid": true, "probeUrl": "…" },
  "identity": { "hwid": "…" }
}
```

Правила совместимости:

- Неизвестные поля игнорируются.
- Если читатель не понимает что-то из `crit` или `v` больше поддерживаемой, импорт отклоняется с просьбой обновить приложение.
- Ключ сервера — хэш его конфигурации, одинаковый на всех устройствах, поэтому избранное переживает перенос.

Ссылка: `paradise://import#PD1.…`. Код передаётся во фрагменте (`#…`), который не уходит ни на какой сервер. Файл: `.paradise`, внутри тот же текст.

## SVOI1 (совместимость)

`SVOI1.` + base64url(gzip(JSON)), где JSON — `{version, name, identity, sources[{name, url, configs[{name, data}]}]}`.

- **Чтение**: оба известных диалекта (с полями `responseFormat`/`sourceProfileCore` и без). Конфиги для sing-box и mihomo пропускаются и считаются в предпросмотре.
- **Запись**: только базовый набор полей. Декодер SVOI отклоняет любые неизвестные поля, поэтому пароль, срок, избранное и настройки в SVOI1 не передаются. Подписки, которые SVOI не примет (не HTTPS или порт не 443), в код не попадают.
