# proxy-tun

**Split-tunneling VPN на OpenWrt + sing-box.** YouTube/Google и Ajax Hub — через VLESS Reality, всё остальное — напрямую в WAN.

---

## Зачем

Провайдеры часто режут или throttлят YouTube (DPI, QoS) и блокируют IP-диапазоны AWS, к которым обращаются IoT-устройства (Ajax Security Hub). Обычный VPN решает проблему, но гонять *весь* трафик через зарубежный сервер — оверхед по latency и скорости.

**Решение:** split-tunnel — YouTube/Google и облако Ajax идут через VPN, Кинопоиск, VK Видео, банкинг — напрямую к провайдеру. Роутер ставится между вышестоящим роутером и клиентами LAN.

---

## Как устроено

```
Вышестоящий роутер (DHCP, <upstream_subnet>)
  │
  ├── WAN → Наш роутер (OpenWrt, фиксированный IP по MAC reservation)
  │       └── LAN (<lan_subnet>)
  │           ├── Smart TV, iPhone, десктопы
  │
WAN↑  ↑LAN
   ┌──────────────────────────────────────────┐
   │  nftables (table inet proxy_tun)         │
   │  prerouting: @youtube_v4 + @ajax_v4 → mark 0x64    │
   │  forward:   UDP/443 → drop (QUIC block) │
   └──────────────────────────────────────────┘
        │                        │
    fwmark 0x64              fwmark 0
        │                        │
    table 100 (youtube)      main table
    default dev tun0         default via WAN
        │                        │
    ┌───┴──────────────┐    WAN (eth0.2)
    │  sing-box (tun0) │    → провайдер
    │  172.19.0.1/30   │
    │  VLESS Reality   │
    └──────────────────┘
    → VPN-сервер (EU)
```

**Ключевые точки:**

| Что | Как |
|-----|-----|
| **Какие IP туннелировать** | nftables sets `@youtube_v4` (Google/YouTube) + `@ajax_v4` (Ajax Hub cloud, AWS EU) |
| **Как направлять** | fwmark 0x64 → ip rule → table 100 → tun0 |
| **QUIC block** | UDP/443 к YouTube дропается на forward → TCP fallback (иначе xudp hole punching не работает на >200ms latency) |
| **Reply клиентам LAN** | MASQUERADE на tun0 (fw4 zone vpn) + второй маршрут `192.168.x.0/24 dev br-lan` в table 100 |
| **VPN-клиент** | sing-box TUN + VLESS Reality (xtls-rprx-vision + xudp) |
| **Смена сервера** | `update-servers.sh` — автовыбор сервера из подписки по RTT + Reality handshake |
| **Автообновление** | cron 02:00 `auto-update.sh` — прогоняет update-servers.sh и проверяет `check_state` (sing-box/tun0/table 100) |
| **Ротация ключей** | `tun-healthcheck.sh` раз в час сверяет pbk/sid сервера с подпиской; при смене — перезапуск update-servers.sh |

> **Нюанс таблицы 100:** таблица зарегистрирована как `100 youtube` в `/etc/iproute2/rt_tables`,
> поэтому `ip rule show` печатает `lookup youtube`, а не `lookup 100`. Проверки и грепы должны
> искать **`lookup youtube`** (в противном случае — вечный false, как было с `check_state` в auto-update.sh).

---

## Автообновление

Ежедневно в **02:00** cron запускает `/etc/sing-box/auto-update.sh` (лог: `/var/log/singbox-autoupdate.log`):

1. `/etc/sing-box/update-servers.sh` — обновляет подписку, перевыбирает сервер по RTT, перегенерирует config.json, рестартует sing-box.
2. Ждёт подъём sing-box + tun0 (до 90s).
3. `check_state` — проверяет 5 критериев: sing-box жив, tun0 `inet`, table 100 содержит `default dev tun0` и `192.168.1.0/24 dev br-lan`, ip rule `fwmark 0x64 lookup youtube`. Ретрай до 40s (watcher поднимает маршруты с задержкой).
4. Итог: `OK:` или `ERR:` + `exit 1`.

Код возврата `update-servers.sh` не является критерием успеха (он с `set -eu` и может вернуть ненулевой код, если ip rule уже создал watcher) — оценивается фактическое состояние.

Ручной запуск: `setsid /etc/sing-box/auto-update.sh > /var/log/singbox-autoupdate.log 2>&1 &` (занимает >2 мин, поэтому не в форграунде).

---

## Компоненты

| Компонент | Роль |
|-----------|------|
| `/etc/sing-box/config.json` | sing-box TUN inbound + outbounds (proxy/direct) + route rules |
| `/etc/sing-box/update-servers.sh` | Скачивает подписку, выбирает сервер по RTT + handshake, генерирует config.json, поднимает PBR-маршруты |
| `/etc/sing-box/auto-update.sh` | Ежедневное автообновление (cron 02:00): update-servers.sh + проверка `check_state` |
| `/etc/sing-box/tun-healthcheck.sh` | Раз в час сверяет Reality-ключи (pbk/sid) с подпиской; при ротации — перезапуск |
| `/etc/sing-box/singbox-pbr-watch.sh` | Следит за tun0, добавляет/восстанавливает ip rule + routes в table 100, запускает healthcheck |
| `/etc/sing-box/proxy-tun.nft` | Таблица `inet proxy_tun`: PBR-маркировка + QUIC block. Опциональные ресурсы — include из `/etc/sing-box/proxy-tun.d/` |
| `/etc/iproute2/rt_tables` | Определяет таблицу `100 youtube` |
| `/etc/init.d/sing-box` | Supervisor без procd (setsid + PID-файл, иначе OOM на 64 MB RAM); грузит nft при старте |
| `/etc/init.d/singbox-pbr` | init-скрипт для watcher (procd, respawn 3600s) |

### Upstream роутер

На вышестоящем роутере **обязательна DHCP-резервация по MAC** WAN-порта нашего роутера. Иначе WAN-IP изменится при перезагрузке, и opencode не сможет подключиться по SSH. LAN нашего роутера — отдельная подсеть, не пересекается с upstream.

---

## Быстрый старт

```bash
# 1. Собрать и прошить OpenWrt → docs/01-CUSTOM_FIRMWARE.md
# 2. Настроить роутер        → docs/02-INITIAL_SETUP.md
# 3. Развернуть VPN          → docs/03-DEPLOY.md
```

Минимальные требования: **OpenWrt 25.12+ (apk), 64 MB RAM, модуль tun**.

> См. также [03-DEPLOY.md](docs/03-DEPLOY.md) — актуальный пошаговый деплой, включая настройку cron автообновления.

---

## Протестировано на

- **TP-Link MR3020 v3** — 64 MB RAM, будет перепрошит с нуля
- **ASUS RT-AC1200** — ✅ VPN работает, YouTube стабильно (проверен 2026-07-24, обновлён 2026-08-03)
  - sing-box 1.12.17, OpenWrt 25.12.5, kernel 6.12.94
  - Samsung TV (WiFi) + iPhone — через PBR + QUIC block
  - Ajax Security Hub — bypass автоматический (только local routing)
  - Автообновление (cron 02:00) + healthcheck ключей — проверены, `check_state` PASS

**Ограничения (обе платформы, 64 MB RAM):**
- `auto_route`/`strict_route` не используются — OOM через 1-2 дня
- init.d/sing-box без procd (прямой setsid, иначе форки не влезают в RAM)
- `sing-box check` ~40 секунд, CHECK_TIMEOUT=90
- Short-list серверов: США | Канада | Швейцария (только `type=tcp`/vision — xhttp-серверы подписки несовместимы с sing-box)

**Протестировано с sing-box 1.11–1.12.**

---

## Структура проекта

```
proxy-tun/
├── README.md
├── AGENTS.md                     ← инструкции для AI-агента
├── opencode.json                 ← конфигурация opencode
├── private/
│   └── AGENTS.local.md           ← приватные данные площадок (не коммитить)
├── router-files/                 ← файлы для установки на роутер
│   ├── update-servers.sh         ← генерация config.json + автовыбор сервера
│   ├── auto-update.sh            ← ежедневный cron: update + проверка check_state
│   ├── tun-healthcheck.sh        ← проверка ротации Reality-ключей (раз в час)
│   ├── proxy-tun.nft             ← таблица nftables (PBR + QUIC block, youtube всегда)
│   ├── proxy-tun.d/
│   │   └── ajax.nft              ← опциональный модуль Ajax Hub (include из proxy-tun.nft)
│   ├── sing-box.init             ← init.d скрипт sing-box (без procd)
│   ├── singbox-pbr-watch.sh      ← watcher для появления tun0 + восстановление routes
│   └── singbox-pbr               ← init.d скрипт watcher (procd)
└── docs/
    ├── 01-CUSTOM_FIRMWARE.md     ← сборка кастомной прошивки
    ├── 02-INITIAL_SETUP.md       ← USB overlay, пакеты, SSH, WiFi
    ├── 03-DEPLOY.md              ← пошаговый деплой VPN
    └── TROUBLESHOOTING.md        ← диагностика проблем
```

---

## Диагностика

Если YouTube перестал работать — см. [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
