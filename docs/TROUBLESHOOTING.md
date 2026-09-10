# TROUBLESHOOTING.md

Диагностика проблем proxy-tun от того, что видит пользователь.

> **Перед диагностикой:** уточни у пользователя, какой роутер? IP адреса в `private/AGENTS.local.md`.

> **⏰ Часовые пояса в логах:** метки времени в `/overlay/etc/sing-box/sing-box.log` и в `logread`
> идут в **UTC**, а не в локальном времени (TZ). Пока роутер в `Europe/Moscow` (UTC+3),
> при анализе логов прибавляй **+3 часа** к меткам, чтобы сопоставить с реальным
> моментом события. Не путай «лог устарел» с «лог актуален» из-за разницы в 3 часа —
> проверяй через `date -u` (UTC) и `date` (локальное) на роутере.

---

## Быстрая карта

Что видит пользователь → сразу к нужному сценарию:

| Что на экране | Сценарий |
|---|---|
| YouTube: страница грузится, видео — серый квадрат / бесконечная буферизация | **Сценарий А** |
| YouTube: страница не грузится, превью нет, ошибка сети | **Сценарий Б** |
| YouTube: работал, через часы/дни перестал | **Сценарий В** |
| YouTube на iPhone: «Не удалось загрузить видео» | **Сценарий Г** |
| Кинопоиск / VK Видео: не грузятся | **Сценарий Д** |
| Ajax Hub: нет соединения с Ethernet, сервера не видны | **Сценарий Д2** |
| YouTube на Smart TV: чёрный экран при старте приложения (iPhone при этом работает) | **Сценарий Ж** |
| YouTube: не работает на ВСЕХ устройствах; туннель жив (204 OK), но страницы/видео грузятся крошками (<10 KB/s) | **Сценарий И** |
| Роутер завис, SSH не отвечает | **Сценарий Е** |

---

## Сценарий А: YouTube страница грузится, но видео — серый квадрат

**Что видит пользователь:** страница YouTube открывается, превью видны, но при запуске
видео — серый экран / квадрат, буферизация не заканчивается.

**Корень проблемы:** sing-box использует `packet_encoding: xudp` (требование VLESS
xtls-rprx-vision). XUDP работает через hole punching, который ломается при latency
>200ms (Россия → Европа). YouTube по умолчанию стримит через QUIC (UDP 443).
Если QUIC не блокировать, UDP-пакеты не проходят через xudp → клиент не получает
видео. QUIC block принудительно переключает YouTube на TCP 443, который надёжно
работает через xudp.

**Как проверить:**

### Как проверить

**Шаг 1 — QUIC block активен?**

```bash
nft list chain inet proxy_tun forward
# Ищи строку: iifname "br-lan" udp dport 443 ip daddr @youtube_v4 drop
# Справа в скобках — счётчик packets. Если 0 — правило не срабатывает.
```

Если цепочка пустая или правила нет — **QUIC block не загружен**.

**Шаг 2 — PBR маркирует YouTube IP?**

```bash
nft list chain inet proxy_tun prerouting
# Ищи: meta mark set 0x00000064
# Счётчик packets должен расти, когда на клиенте открыт YouTube
```

Если счётчик не растёт — **PBR не захватывает трафик YouTube**.

### Как исправить

```bash
# Перезагрузить таблицу proxy_tun вручную:
nft -f /etc/sing-box/proxy-tun.nft
```

### Как проверить что помогло

Открой YouTube на том же устройстве, запусти любое видео. Должно воспроизводиться.
На роутере:

```bash
nft list chain inet proxy_tun forward
# packets должны расти при просмотре
```

### Не помогло?

Если QUIC block есть, счётчики растут, но видео всё равно серое — проверь
Сценарий В (возможно, сервер перестал отвечать, и блокировка QUIC тут ни при чём).

---

## Сценарий Б: YouTube страница не грузится совсем

**Что видит пользователь:** YouTube не открывается ни на одном устройстве.
Приложение выдаёт «Ошибка сети», браузер — таймаут.

**Корень проблемы:** трафик YouTube не доходит до туннеля или ответ не
возвращается клиенту. Три типичные причины:

1. **tun0 не поднят** — sing-box не запущен, конфиг сломан, tun модуль отсутствует
2. **table 100 неполная** — в ней должен быть не только `default dev tun0`, но и
   маршрут к LAN-подсети (`192.168.x.0/24 dev br-lan`). Иначе reply-пакеты от
   YouTube приходят на IP клиента LAN, ядро ищет его в table 100, не находит,
   фоллбэчит на main → main не знает LAN-подсеть → пакет дропается
3. **Нет MASQUERADE на tun0** — без него fw4 не подменяет src=172.19.0.1
   на LAN-адрес роутера, reply обрабатывается локально вместо форварда в LAN

### Как проверить — начать с самого базового

**Шаг 1 — tun0 существует?**

```bash
ip -4 addr show tun0 2>/dev/null || echo "НЕТ tun0"
# Должен быть: inet 172.19.0.1/30
```

Нет tun0 → иди к **Шаг 2**. Tun0 есть → перейди к **Шагу 4**.

**Шаг 2 — sing-box запущен?**

```bash
pgrep -la sing-box
# Должен быть ровно 1 процесс

/etc/init.d/sing-box status
# Должен быть: running
```

**Шаг 3 — если не запущен, ищем причину в логах:**

```bash
logread | grep -i "sing-box" | tail -20
# Или:
tail -30 /overlay/etc/sing-box/sing-box.log 2>/dev/null
```

Типичные ошибки в логах:
- `FATAL` — конфиг невалиден, tun module отсутствует, адрес занят
- `panic` / `segfault` — битая сборка sing-box
- `can't find device 'tun0'` — tun module не загружен

**Проверка конфига (без запуска второго sing-box):**

> ⚠️ `sing-box check` — отдельный процесс, он потребляет ~20-30 MB RAM.
> Если sing-box уже запущен, **не запускай `sing-box check` одновременно** —
> на 64 MB памяти оба процесса не влезут → OOM.

```bash
# Если sing-box НЕ запущен — можно проверить конфиг:
sing-box check -c /etc/sing-box/config.json

# Если sing-box ЗАПУЩЕН — сначала убить, потом проверить:
killall -9 sing-box; sleep 2
sing-box check -c /etc/sing-box/config.json
```

**Как исправить (шаги 2-3):**

```bash
# Ошибка в конфиге — перегенерировать:
/etc/sing-box/update-servers.sh

# Если скрипт падает — см. приложение «Подписка: Token not found»

# Если tun module отсутствует:
apk add kmod-tun

# После исправления — запустить sing-box:
/etc/init.d/sing-box restart
sleep 20
ip -4 addr show tun0
# Должен появиться
```

**Шаг 4 — tun0 есть, но table 100 пустая?**

```bash
ip route show table 100
# Должно быть два маршрута:
#   default dev tun0 scope link
#   192.168.1.0/24 dev br-lan scope link
```

**Как исправить:**

```bash
# Проверить watcher:
ps | grep singbox-pbr-watch | grep -v grep

# Если не запущен:
/etc/init.d/singbox-pbr enable
/etc/init.d/singbox-pbr start

# Добавить вручную (для проверки):
ip rule add pref 100 fwmark 0x64 lookup 100 2>/dev/null
ip route replace default dev tun0 scope link table 100
ip route replace 192.168.1.0/24 dev br-lan scope link table 100
```

**Шаг 5 — fw4 zone vpn существует?**

```bash
uci get firewall.vpn.device
# Должно быть: tun0 (НЕ network=tun0)

uci get firewall.vpn.masq
# Должно быть: 1

nft list chain inet fw4 accept_to_vpn 2>/dev/null
# Должна быть не пустая (правила с oifname "tun0")
```

**Как исправить:**
См. [03-DEPLOY.md → Шаг 5](03-DEPLOY.md#шаг-5-firewall-зона-vpn--forwarding).

### Как проверить что помогло

Открой YouTube на любом устройстве — должно работать.
На роутере:

```bash
curl --interface tun0 -m 8 -o /dev/null -w '%{http_code}' https://www.youtube.com/generate_204
# Должен вернуть 204
```

### Дальнейшие шаги

Если после всех шагов YouTube не открывается — скорее всего проблема на стороне
сервера (Сценарий В).

---

## Сценарий В: YouTube работал, но через часы/дни перестал

**Что видит пользователь:** вчера всё работало, сегодня YouTube не грузится.
Роутер доступен, tun0 есть, sing-box работает.

**Почему так бывает:** провайдер подписки (connliberty) периодически ротирует
Reality-ключи (`public_key`, `short_id`). Config.json содержит старые ключи →
TLS handshake с сервером не проходит. Либо IP сервера заблокирован провайдером.

### Как проверить

**Шаг 1 — какой сервер используется?**

```bash
jq -r '.outbounds[0].server' /etc/sing-box/config.json
```

**Шаг 2 — обновить подписку и пересоздать конфиг:**

```bash
/etc/sing-box/update-servers.sh
sleep 20
ip -4 addr show tun0
# tun0 должен появиться
```

**Шаг 3 — если не помогло, обновить подписку:**
```bash
/etc/sing-box/update-servers.sh
```

`update-servers.sh` сам выберет лучший сервер из short-list.

### Как проверить что помогло

```bash
curl --interface tun0 -m 8 -o /dev/null -w '%{http_code}' https://www.youtube.com/generate_204
# Должен вернуть 204

# Или просто открой YouTube на устройстве
```

### Не помогло?

Проверь что подписка валидна (см. Сценарий «Проблемы с подпиской» в конце).
Если подписка ок, но YouTube не работает — возможно, IP сервера заблокирован
на уровне провайдера (попробуй сервер из другой локации).

---

## Сценарий Г: YouTube на iPhone не грузится

**Что видит пользователь:** на Samsung TV YouTube работает, на iPhone —
«Не удалось загрузить видео». Или наоборот.

**Почему так бывает:** разные устройства по-разному резолвят DNS.
Если iPhone использует IPv6 DNS (Google DNS 2001:4860:4860::8888), а наш PBR
маркирует только IPv4 — IPv6-трафик идёт напрямую в WAN, минуя туннель.

### Как проверить

**Шаг 1 — PBR активен?** (см. Сценарий А, Шаг 2)

**Шаг 2 — IPv6 включён на iPhone?**

На iPhone:
```
Настройки → Wi-Fi → (твоя сеть) → DNS → Конфигурация DNS
```
Если там не «Автоматически», а кастомный DNS с IPv6-адресами (2001:...) — проблема в этом.

**Шаг 3 — проверить что трафик с iPhone идёт через tun0:**

```bash
cat /proc/net/dev | grep tun0
# RX bytes должны расти, когда на iPhone открыт YouTube
```

### Как исправить

На iPhone в настройках Wi-Fi убрать IPv6 DNS или переключить на «Автоматически».
Или вручную прописать только IPv4: `1.1.1.1`, `8.8.4.4`.

### Как проверить что помогло

Открой YouTube на iPhone. Если работает — всё ок.

---

## Сценарий Д: Кинопоиск / VK Видео не грузятся

**Что видит пользователь:** YouTube работает, а Кинопоиск или VK Видео —
тормозят, не грузятся, или открываются очень медленно.

**Почему так бывает:** текущая архитектура использует `route.final = "proxy"`,
поэтому весь немаркированный трафик, дошедший до tun0, идёт через VPN. Для
Кинопоиска/VK это приемлемо (latency замечается). Если нужен `direct` — потребуется
добавить `route.rules` с `outbound: direct` в config.json.

### Как проверить

```bash
jq '.route.final' /etc/sing-box/config.json
jq '.route.rules' /etc/sing-box/config.json
```

### Как исправить

Если latency критична — добавить в `update-servers.sh` правило `outbound: direct`
для `kinopoisk.ru` / `vkvideo.ru` или обновить конфиг вручную.

---

## Сценарий Д2: Ajax Hub — нет соединения с Ethernet

**Что видит пользователь:** Ajax Hub подключён по кабелю, IP получает, но в
приложении — «нет соединения с Ethernet». YouTube при этом работает.

**Почему так бывает:** ISP блокирует IP-диапазоны AWS (Eu-West), к которым
обращается Ajax Hub (ec2 EU). Это не связано с VPN/PBR — проблема проявляет
себя даже при прямом подключении хаба к upstream-роутеру.

### Как проверить

```bash
# Смотрим IP, к которым обращается Ajax (из conntrack):
cat /proc/net/nf_conntrack | grep 192.168.1.144 | grep -oP "dst=\K[\d.]+" | sort -u
# Все UNREPLIED? Проблема не в нашем роутере.

# DNS-резолв этих IP:
for ip in $(cat /proc/net/nf_conntrack | grep 192.168.1.144 | grep -oP "dst=\K[\d.]+" | sort -u); do
  echo "$ip: $(nslookup $ip 2>/dev/null | grep 'name =' | head -1)"
done
```

### Как исправить

Если IP принадлежат AWS EU (eu-west-1, eu-west-3) — добавить их в `@ajax_v4`
set в `/etc/sing-box/proxy-tun.d/ajax.nft` (или подключить модуль include)
и перезагрузить:

```bash
nft -f /etc/sing-box/proxy-tun.nft
```

IP Ajax Hub обычно: AWS EC2 (eu-west-1, eu-west-3) — Париж, Ирландия.

### Как проверить что помогло

Открой kinopoisk.ru или vkvideo.ru на любом устройстве — должно грузиться как обычно, без задержек.

---

## Сценарий Ж: Чёрный экран YouTube на Smart TV при старте

**Что видит пользователь:** на iPhone YouTube работает, а на Samsung TV приложение
открывается сразу чёрным экраном — не доходит даже до экрана выбора профиля.

**Корень проблемы (2026-08-27, MR3020):** провайдер выборочно подменяет ответы
открытого UDP/53 на имена `youtube.com` / `www.youtube.com` — отвечает `NXDOMAIN`.
Tizen-приложение не может зарезолвить `youtube.com` → умирает до старта UI. iPhone
работает, потому что использует собственный зашифрованный DNS (Private Relay/DoH)
или кэш. Остальные Google-домены (`youtubei.googleapis.com`, `i.ytimg.com`,
`*.googlevideo.com`) не отравляются — поэтому по conntrack видно, что TV успешно
ходит к YouTube API через туннель, но само приложение всё равно не стартует.

### Как проверить

**Шаг 1 — резолвится ли `youtube.com` через dnsmasq?**

```bash
nslookup youtube.com 127.0.0.1 | grep Address
# NXDOMAIN → провайдер травит это имя
nslookup youtubei.googleapis.com 127.0.0.1 | grep Address
# резолвится → отравление точечное (только youtube.com/www.youtube.com)
```

**Шаг 2 — dnsmasq не подтягивает DNS провайдера из WAN-DHCP?**

```bash
uci get dhcp.@dnsmasq[0].noresolv   # должно быть '1'
uci get dhcp.@dnsmasq[0].server     # чистые резолверы (9.9.9.9, 1.0.0.1)
```

Если `noresolv` не задан — dnsmasq, помимо списка `server=`, использует DNS из
`/etc/resolv.conf` WAN-DHCP (провайдерские резолверы). Они отвечают NXDOMAIN на
`youtube.com` мгновенно (1 хоп) и выигрывают гонку у честного ответа 8.8.8.8.

**Шаг 3 — отравление точечное или глобальное?**

```bash
nslookup youtube.com 8.8.8.8     # прямой запрос (не через dnsmasq)
# резолвится → DPI различает форму пакета dnsmasq (EDNS0/0x20) — см. ниже
```

### Как исправить

```bash
uci set dhcp.@dnsmasq[0].noresolv='1'          # не брать DNS из WAN-DHCP
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='9.9.9.9'
uci add_list dhcp.@dnsmasq[0].server='1.0.0.1'
uci set dhcp.@dnsmasq[0].nonegcache='1'        # NXDOMAIN не кэшировать
cat >> /etc/hosts <<'EOF'
172.217.20.174   youtube.com
142.251.152.4    www.youtube.com
142.251.152.4    m.youtube.com
EOF
uci commit dhcp
/etc/init.d/dnsmasq restart
```

> **Почему hosts, а не «просто другие резолверы»:** DPI отравляет открытый UDP/53
> по форме пакета dnsmasq (EDNS0 + 0x20-рандомизация регистра) — даже запросы
> dnsmasq к `8.8.8.8` получают NXDOMAIN, тогда как прямой `nslookup youtube.com 8.8.8.8`
> проходит. Поэтому единственный надёжный обход для этих 2 имён — hosts-записи
> (резолв без upstream). Остальные домены резолвятся штатно через 9.9.9.9/1.0.0.1
> (связка как на даче; 8.8.8.8 как upstream убран 2026-09-09).

### Как проверить что помогло

```bash
nslookup youtube.com 127.0.0.1 | grep Address
# → 172.217.20.174 (из /etc/hosts)
```

Полностью выключите TV из розетки на ~30 сек (сброс DNS-кэша Tizen), включите,
откройте YouTube — должен выйти на выбор профиля.

### Что НЕ работает (проверено 2026-08-27)

- **DNS через туннель** (маркировка UDP/53 к 8.8.8.8 → tun0): xudp поверх VLESS
  на этом канале ненадёжен — sing-box сыпет `listen outbound packet connection: EOF`,
  DNS работает рывками, ломает и iPhone. Не использовать.
- **https-dns-proxy (DoH)**: пакет из 23.05.6 на mipsel_24kc зависает в D-state
  (не отвечает на запросы, неубиваем, 94% CPU). Требует перезагрузки роутера.

---

## Сценарий И: Туннель «жив» (204 OK), а YouTube не грузится на всех устройствах

**Что видит пользователь:** YouTube не работает ни на ТВ, ни на телефоне. При этом
SSH на роутер есть, tun0 поднят, `curl --interface tun0 .../generate_204` возвращает
204. Страницы и видео грузятся крошками или не грузятся совсем.

**Корень проблемы (2026-09-09, MR3020):** провайдер квартиры душит **throughput**
до диапазона провайдера подписки (`31.56.150.x`). RTT живой (TCP-тест и `sing-box
check` проходят!), но bulk-трафик через туннель — сотни байт/сек. Диагноз «сервер
работает» по 204 — ложный: 204-ответ крошечный и пролезает даже через мёртвый канал.

Второй подвох того же дня: часть узлов подписки переехала на `type=xhttp` —
sing-box не умеет этот транспорт (Xray-only). TCP+Reality до такого узла
устанавливается, но VLESS-слой молчит → соединения «есть», данных нет.

### Как проверить

**Шаг 1 — bulk-тест (решающий, 204 недостаточно):**

```bash
# страница ~1 MB — если <10 KB/s, канал задушен
curl --interface tun0 -m 20 -sS -o /dev/null \
    -w 'page: %{http_code} %{size_download}B %{time_total}s (%{speed_download}B/s)\n' \
    https://www.youtube.com/
curl --interface tun0 -m 20 -sS -o /dev/null \
    -w 'img: %{http_code} %{size_download}B %{time_total}s\n' \
    https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg
```

**Шаг 2 — контрольный A/B: тот же объём напрямую через WAN:**

```bash
curl -m 20 -sS -o /dev/null \
    -w 'WAN: %{size_download}B %{speed_download}B/s\n' \
    "https://speed.cloudflare.com/__down?bytes=2000000"
curl --interface tun0 -m 20 -sS -o /dev/null \
    -w 'TUN: %{size_download}B %{speed_download}B/s\n' \
    "https://speed.cloudflare.com/__down?bytes=2000000"
# WAN быстрый + TUN задушен → душится путь к узлу (или сам узел), не роутер и не DNS
```

**Шаг 3 — узел не xhttp?** `update-servers.sh` скипает не-tcp узлы
(`SKIP ... type=xhttp` в logread). Если в конфиг попал xhttp-узел (транспорт в
подписке меняется) — конфиг надо пересобрать с tcp-узлом.

### Как исправить

```bash
/etc/sing-box/update-servers.sh        # свежая подписка = свежие sid + другой узел
# если снова выбрал душащийся узел: SKIP_N=1 /etc/sing-box/update-servers.sh
```

Если задушен весь шорт-лист (все узлы в одном диапазоне) — искать в подписке
узлы вне диапазона или поднимать Xray-core ради xhttp-узлов (см. лог анализа
2026-09-09: Япония/Бельгия вне `31.56.150.x`).

> **2026-09-11 (MR3020):** топ-1 RTT-узел из задушенного диапазона снова мёртв для
> bulk (204 OK, bulk RST/0–585 B/s), а `SKIP_N` на роутере недоступен (07.09-версия
> скрипта). Обход без изменения скрипта: временно сузить `COUNTRIES` в
> `/etc/sing-box/update-servers.sh` до одной страны с живым узлом вне диапазона,
> прогнать скрипт, затем восстановить файл байт-в-байт (md5-контроль). На время
> прогона — пауза cron и watcher. Верификация: 204 ×3 OK, bulk 93 KB/s,
> страница YouTube 71 KB/s, подтверждено пользователем на ТВ. Побочка: каждый
> автопрогон (сейчас каждые 2 ч) заново берёт топ-1 RTT и может вернуть
> задушенный узел.

### Как проверить что помогло

Повторить bulk-тест: `page` должен отдавать сотни KB/s. Потом YouTube на устройстве.

---

## Сценарий Е: Роутер завис / не отвечает

**Что видит пользователь:** SSH не подключается, клиенты в LAN потеряли
интернет. Требуется физическая перезагрузка роутера (выдернуть питание).

**Корень проблемы:** sing-box с включённым `auto_route` / `strict_route`
создаёт десятки ip rule и запускает встроенный DNS-модуль, который в цикле
переспрашивает сам себя (DNS loop). На 64 MB RAM это приводит к 120-200 MB RSS
через 1-2 дня → OOM killer убивает процесс → роутер зависает.

### Профилактика (на работающем роутере)

**Проверить что auto_route выключен:**

```bash
jq '.inbounds[0] | {auto_route, strict_route}' /etc/sing-box/config.json
# Должно быть: {"auto_route": false, "strict_route": false}
```

Если true — срочно исправить:

```bash
/etc/sing-box/update-servers.sh
```

### Если роутер уже завис

1. Физически выключить и включить питание
2. Подключиться, проверить конфиг (команда выше)
3. Исправить

### Дополнительно

- Проверить что swap активен: `free -h` (Swap: не 0)
- Если swap отсутствует — настроить USB-свап
  (см. [02-INITIAL_SETUP.md → 2.4 Настройка fstab](02-INITIAL_SETUP.md#24-настройка-fstab))

---

## Приложение: что ещё может сломаться

Проблемы, которые не проявляются как «YouTube не работает», но мешают при
обслуживании.

### Подписка: Token not found

```
[2/5] Загружаю подписку...
{"detail":"Token not found"}
```

**Причина:** UUID невалидный или подписка истекла.

**Что делать:**
1. Получить новый URL подписки от провайдера
2. Записать на роутер: `printf '%s' 'новый-url' > /etc/sing-box/subscription.url`
3. Запустить: `/etc/sing-box/update-servers.sh`

### Подписка: недоступна (WARN: использую кэш)

**Причина:** роутер не может соединиться с connliberty.com.

**Проверить:**
```bash
nslookup connliberty.com 1.1.1.1
curl -sS --max-time 10 "$(cat /etc/sing-box/subscription.url)" | head -c 50
```

### sing-box 1.12+: legacy tun address FATAL

**Симптом:** при `sing-box check` ошибка про legacy tun address.

**Решение:**
```bash
/etc/sing-box/update-servers.sh
jq '.inbounds[0].address' /etc/sing-box/config.json
# Ожидаемый результат: ["172.19.0.1/30"] (массив, не строка)
```

### jq / base64: not found

```bash
apk add jq coreutils-base64
```

### DNS loop в sing-box

**Симптом:** в логах sing-box множественные `inbound/dns` соединения к 172.19.0.2.

**Решение:**
```bash
# Убить sing-box перед проверкой (64 MB RAM не выдержат два процесса)
killall -9 sing-box; sleep 2
jq 'del(.dns)' /etc/sing-box/config.json > /tmp/cfg.json
sing-box check -c /tmp/cfg.json && mv /tmp/cfg.json /etc/sing-box/config.json
/etc/init.d/sing-box start
```

---

## Если ничего не помогло

Собери диагностический вывод и обратись за помощью:

```bash
ssh root@<ROUTER_IP>

echo "=== 1. sing-box ==="
pgrep -la sing-box
ip -4 addr show tun0

echo "=== 2. table 100 ==="
ip route show table 100
ip rule show | grep 100

echo "=== 3. nft ==="
nft list table inet proxy_tun 2>/dev/null

echo "=== 4. fw4 ==="
uci show firewall | grep -E "=zone|forwarding"
nft list chain inet fw4 accept_to_vpn 2>/dev/null
nft list chain inet fw4 srcnat_vpn 2>/dev/null

echo "=== 5. config ==="
sing-box check -c /etc/sing-box/config.json
jq '.inbounds[0] | {auto_route, strict_route}' /etc/sing-box/config.json
jq '.route.rules' /etc/sing-box/config.json

echo "=== 6. память ==="
free -h
df -h /overlay

echo "=== 7. логи ==="
tail -20 /overlay/etc/sing-box/sing-box.log 2>/dev/null
```
