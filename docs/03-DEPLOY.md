# Деплой proxy-tun: пошаговый план

Развёртывание YouTube-only PBR VPN (sing-box TUN + VLESS Reality + nftables PBR) на OpenWrt-роутере.

> Рассчитан на роутеры с ≥64 MB RAM, OpenWrt 25.12+ (mipsel_24kc, aarch64, x86_64), пакетный менеджер `apk`.

---

## Предусловия

### 1. Роутер доступен по SSH

```bash
ssh -i ~/.ssh/id_rsa_openwrt root@<ROUTER_IP>
```

### 2. WAN и LAN работают

```bash
uci show network.wan | grep device     # → network.wan.device='eth0.2'
uci show network.lan | grep ipaddr     # → network.lan.ipaddr='192.168.1.1'
ip -4 addr show br-lan                 # → inet 192.168.1.1/24
```

### 3. Подписка connliberty

Проверка с ПК — подписка должна быть доступна:

```bash
curl -sS --max-time 30 "https://connliberty.com/connection/subs/ваш-uuid-36-символов" | head -c 100
# → base64-строка (начинается с dmxlc3M6Ly8=...)
```

### 4. Ядро поддерживает TUN

```bash
zcat /proc/config.gz | grep -E '^CONFIG_TUN='   # → CONFIG_TUN=y
ls /dev/net/tun                                   # → crw-rw-rw-
```

### 5. Достаточно свободной памяти

```bash
free | grep Mem      # → Mem: всего 60000+ KB, свободно 25000+ KB
```

---

## Шаг 1. Установка sing-box

```bash
apk update && apk add sing-box
```

**Проверка:**
```bash
sing-box version | head -1   # → sing-box version 1.13.x (проверено 1.13.21; см. Приложение C)
```

> Пакеты `bash`, `jq`, `curl`, `ip-full`, `nftables-json`, `kmod-tun` — должны быть
> вшиты в кастомную прошивку (см. [01-CUSTOM_FIRMWARE.md](01-CUSTOM_FIRMWARE.md)).
> Если нет — установите сейчас.
>
> **Опциональные пакеты** (диагностика):
> ```bash
> apk add htop time
> ```

---

## Шаг 2. Файл подписки

```bash
mkdir -p /etc/sing-box
printf '%s' 'https://connliberty.com/connection/subs/ваш-uuid-36-символов' > /etc/sing-box/subscription.url
chmod 600 /etc/sing-box/subscription.url
```

**Проверка:**
```bash
cat /etc/sing-box/subscription.url
# → https://connliberty.com/connection/subs/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

---

## Шаг 3. Копирование файлов конфигурации

С ПК, из корня репозитория:

```bash
ROUTER="root@<ROUTER_IP>"

# Скрипты в /etc/sing-box/
cat router-files/update-servers.sh | ssh $ROUTER "cat > /etc/sing-box/update-servers.sh"
cat router-files/singbox-pbr-watch.sh | ssh $ROUTER "cat > /etc/sing-box/singbox-pbr-watch.sh"
cat router-files/sing-box.init | ssh $ROUTER "cat > /etc/init.d/sing-box"

# nft таблица PBR + QUIC block (в /etc/sing-box/, НЕ в /etc/nftables.d/!
# fw4 инклюдит /etc/nftables.d/*.nft внутрь своей таблицы — отдельная
# таблица там сломает firewall reload. init.d/sing-box грузит её сам.)
cat router-files/proxy-tun.nft | ssh $ROUTER "cat > /etc/sing-box/proxy-tun.nft"

# Опциональные nft-модули (включаются через include в proxy-tun.nft)
ssh $ROUTER "mkdir -p /etc/sing-box/proxy-tun.d"
cat router-files/proxy-tun.d/ajax.nft | ssh $ROUTER "cat > /etc/sing-box/proxy-tun.d/ajax.nft"

# init.d скрипт для PBR watcher
cat router-files/singbox-pbr | ssh $ROUTER "cat > /etc/init.d/singbox-pbr"

# Автообновление (cron 02:00) + healthcheck ротации ключей
cat router-files/auto-update.sh | ssh $ROUTER "cat > /etc/sing-box/auto-update.sh"
cat router-files/tun-healthcheck.sh | ssh $ROUTER "cat > /etc/sing-box/tun-healthcheck.sh"

# Права
ssh $ROUTER "chmod +x /etc/sing-box/update-servers.sh /etc/sing-box/singbox-pbr-watch.sh"
ssh $ROUTER "chmod +x /etc/sing-box/auto-update.sh /etc/sing-box/tun-healthcheck.sh"
ssh $ROUTER "chmod +x /etc/sing-box/proxy-tun.nft /etc/init.d/sing-box /etc/init.d/singbox-pbr"
```

**Включение опциональных ресурсов:** в `/etc/sing-box/proxy-tun.nft` раскомментируй
нужную строку `include "/etc/sing-box/proxy-tun.d/<module>.nft"`. По умолчанию
включён только YouTube (`@youtube_v4`). Пример — Ajax Hub (дачи):

```bash
sed -i 's|^# include "/etc/sing-box/proxy-tun.d/ajax.nft"|include "/etc/sing-box/proxy-tun.d/ajax.nft"|' \
    /etc/sing-box/proxy-tun.nft
```

**Проверка на роутере:**
```bash
ls -la /etc/sing-box/ /etc/sing-box/proxy-tun.d/ /etc/init.d/sing-box /etc/init.d/singbox-pbr
```

---

## Шаг 4. Таблица маршрутизации для PBR

```bash
grep -q '^100 youtube' /etc/iproute2/rt_tables || \
    echo '100 youtube' >> /etc/iproute2/rt_tables
```

**Проверка:**
```bash
grep youtube /etc/iproute2/rt_tables   # → 100 youtube
```

---

## Шаг 5. Firewall: зона vpn + forwarding

```bash
uci set firewall.vpn=zone
uci set firewall.vpn.name='vpn'
uci set firewall.vpn.device='tun0'       # device=, не network=!
uci set firewall.vpn.input='ACCEPT'
uci set firewall.vpn.output='ACCEPT'
uci set firewall.vpn.forward='ACCEPT'
uci set firewall.vpn.masq='1'

uci set firewall.lan_vpn=forwarding
uci set firewall.lan_vpn.src='lan'
uci set firewall.lan_vpn.dest='vpn'

uci commit firewall
/etc/init.d/firewall reload
```

**Проверка:**
```bash
uci show firewall.vpn
# → device='tun0', masq='1'

nft list chain inet fw4 accept_to_vpn 2>/dev/null
# → появится после того, как tun0 поднят (шаг 11)
```

---

## Шаг 6. DNS

> ⚠️ **Важно (2026-08-27, MR3020):** провайдер выборочно подменяет ответы открытого
> UDP/53 на `youtube.com`/`www.youtube.com` (отвечает NXDOMAIN). Симптом: YouTube на
> Samsung TV — чёрный экран на старте приложения, iPhone работает (у него свой
> зашифрованный DNS). Лечится: `noresolv` (не брать DNS из WAN-DHCP провайдера) +
> чистые резолверы + hosts-записи на отравленные имена. Подробности — в
> [TROUBLESHOOTING.md → Сценарий Ж](TROUBLESHOOTING.md#сценарий-ж-чёрный-экран-youtube-на-smart-tv).

```bash
# 1. Не использовать DNS из WAN-DHCP (провайдерские резолверы могут травить ответы)
uci set dhcp.@dnsmasq[0].noresolv='1'

# 2. Чистые upstream (9.9.9.9 + 1.0.0.1 — рабочая связка, проверена на даче Asus;
#    8.8.8.8 убран 2026-09-09 — нестабилен за агрессивным DPI)
uci delete dhcp.@dnsmasq[0].server 2>/dev/null
uci add_list dhcp.@dnsmasq[0].server='9.9.9.9'
uci add_list dhcp.@dnsmasq[0].server='1.0.0.1'

# 3. Не кэшировать NXDOMAIN (иначе отравленный ответ «залипает» на часы)
uci set dhcp.@dnsmasq[0].nonegcache='1'

# 4. hosts-записи на имена, которые провайдер травит (обход без upstream).
#    IP должны быть внутри @youtube_v4, чтобы шли через туннель.
cat >> /etc/hosts <<'EOF'
172.217.20.174   youtube.com
142.251.152.4    www.youtube.com
142.251.152.4    m.youtube.com
EOF

uci commit dhcp
/etc/init.d/dnsmasq restart
```

**Проверка:**
```bash
nslookup youtube.com 127.0.0.1 | grep Address
# → Address 1: 172.217.20.174 (из /etc/hosts, не зависит от провайдера)
nslookup kinopoisk.ru 127.0.0.1 | grep Address
# → Address 1: 213.180.x.x (обычный upstream)
```

> **Опционально — защита от IPv6-зависаний Tizen:** если Smart TV не фоллбэчится
> с IPv6 на IPv4 (чёрный экран при наличии ULA в LAN, но без глобального IPv6),
> отключить анонсы IPv6 и фильтровать AAAA:
> ```bash
> uci set dhcp.lan.ra='disabled'
> uci set dhcp.lan.dhcpv6='disabled'
> uci set dhcp.lan.ra_slaac='0'
> uci set dhcp.@dnsmasq[0].filter_aaaa='1'
> uci commit dhcp
> /etc/init.d/odhcpd restart; /etc/init.d/dnsmasq restart
> ```

---

## Шаг 7. init.d/sing-box

Пакетный init.d/sing-box использует procd, который нестабилен с sing-box на MIPS (gVisor
вешает роутер). Заменяем его на `sing-box.init` — лёгкий supervisor без procd, с прямым
`setsid` и PID-файлом.

Файл уже скопирован на шаге 3. Включаем вместо пакетного:

```bash
# Отключаем пакетный (если был включён)
/etc/init.d/sing-box disable 2>/dev/null

# Включаем кастомный
/etc/init.d/sing-box enable
```

> Кастомный init.d НЕ вызывает `update-servers.sh` при старте — это ручной шаг (см. шаг 8).
> Обновление конфига делается явно: `/etc/sing-box/update-servers.sh`.
> Скрипт сам перезапускает sing-box.

---

## Шаг 8. Генерация config.json

Скрипт `update-servers.sh` скачивает подписку, фильтрует по странам (Швейцария, Нидерланды,
Франция), TCP-тестит + замеряет RTT, проверяет Reality handshake через `sing-box check`
и записывает `/etc/sing-box/config.json`.

```bash
/etc/sing-box/update-servers.sh
```

Процесс занимает ~90-120 секунд (на 64 MB RAM check ~40 сек на сервер).

**Проверка:**
```bash
# Конфиг валиден
sing-box check -c /etc/sing-box/config.json

# auto_route/strict_route выключены
jq -e '.inbounds[0].auto_route == false and .inbounds[0].strict_route == false' \
    /etc/sing-box/config.json && echo "OK"

# Структура outbound
jq '.outbounds[0].server, .outbounds[0].server_port' /etc/sing-box/config.json
# → "<server>.live" 443
```

---

## Шаг 9. Запуск сервисов

```bash
# Убить старые процессы (если есть)
killall -9 sing-box 2>/dev/null; sleep 2

# Запустить sing-box
/etc/init.d/sing-box start

# Запустить PBR watcher
/etc/init.d/singbox-pbr enable
/etc/init.d/singbox-pbr start

# Перезагрузить firewall (на всякий случай)
/etc/init.d/firewall reload

# Ждём появления tun0 (30-40 сек на Asus, 10-15 на MR3020)
sleep 30
ip -4 addr show tun0
# → inet 172.19.0.1/30 scope global tun0
```

**Если tun0 не появился:**
```bash
logread | grep -i "sing-box" | tail -20
```

---

## Шаг 10. Автообновление (cron 02:00) + healthcheck ключей

Ежедневное автообновление и проверка ротации Reality-ключей:

```bash
# cron 02:00: auto-update.sh (update + проверка check_state)
echo '0 2 * * * /etc/sing-box/auto-update.sh >> /var/log/singbox-autoupdate.log 2>&1' \
    | crontab -

# healthcheck запускается watcher'ом раз в час (tun-healthcheck.sh вызывается из singbox-pbr-watch.sh)
```

**Проверка:**
```bash
crontab -l   # → 0 2 * * * /etc/sing-box/auto-update.sh ...
```

> `auto-update.sh` не берёт код возврата `update-servers.sh` за критерий успеха —
> оценивает фактическое состояние (`check_state`: sing-box, tun0, table 100,
> ip rule `lookup youtube`). Лог: `/var/log/singbox-autoupdate.log`.
>
> ⚠️ Ручной запуск: `setsid /etc/sing-box/auto-update.sh > /var/log/singbox-autoupdate.log 2>&1 &`
> (процесс идёт >2 мин, в форграунде упрётся в таймаут).

---

## Шаг 11. Финальная проверка

### Сеть

```bash
ip -4 addr show tun0
# → inet 172.19.0.1/30

ip route show table 100
# → default dev tun0 scope link
# → 192.168.1.0/24 dev br-lan scope link

ip rule show | grep 100
# → 100: from all fwmark 0x64 lookup youtube
```

### nftables

```bash
nft list table inet proxy_tun
# → set youtube_v4 (~37 диапазонов)
# → chain prerouting (RETURN для LAN/DNS/DHCP + mark 0x64)
# → chain forward (drop UDP/443 к youtube_v4)
```

### sing-box

```bash
/etc/init.d/sing-box status   # → running (или PID есть)
tail -5 /overlay/etc/sing-box/sing-box.log # → inbound/tun[tun-in]: started at tun0
```

### Тест с роутера (прямое подключение к серверу)

```bash
SERVER=$(jq -r '.outbounds[0].server' /etc/sing-box/config.json)
curl -sS --max-time 8 -o /dev/null -w 'HTTP %{http_code} time=%{time_total}s\n' \
    "https://$SERVER/" 2>&1 | head -1
# → SSL error (BADCERT_CN_MISMATCH) — это нормально, Reality работает
```

### Тест с LAN-устройства

Откройте YouTube на любом устройстве в LAN. Видео должно воспроизводиться.

На роутере:
```bash
tail -f /overlay/etc/sing-box/sing-box.log | grep 'outbound/vless'
# → появятся строки при просмотре YouTube
```

---

## Приложение A. Структура config.json

Критичные поля, которые должны быть в сгенерированном конфиге:

| Поле | Значение | Почему |
|---|---|---|
| `inbounds[0].auto_route` | `false` | иначе конфликт с нашим PBR |
| `inbounds[0].strict_route` | `false` | иначе DNS loop + OOM |
| `outbounds[0].flow` | `"xtls-rprx-vision"` | сервер требует vision |
| `outbounds[0].packet_encoding` | `"xudp"` | обязателен для vision |
| `outbounds[1].tag` | `"direct"` | для kinopoisk/vkvideo |
| `route.final` | `"proxy"` | весь остальной трафик → VPN |

Чего НЕ должно быть:
- ❌ `mux` — несовместим с vision flow
- ❌ `auto_route: true`, `strict_route: true`
- ❌ `packet_encoding` кроме `"xudp"`

**Быстрая проверка:**
```bash
jq -e '
  .inbounds[0].auto_route == false and
  .inbounds[0].strict_route == false and
  .outbounds[0].flow == "xtls-rprx-vision" and
  .outbounds[0].packet_encoding == "xudp" and
  .outbounds[1].tag == "direct" and
  .route.final == "proxy"
' /etc/sing-box/config.json && echo "OK" || echo "FAIL"
```

---

## Приложение B. Ротация Reality-ключей и подводные камни подписки

Провайдер периодически меняет `public_key` / `short_id`. Если YouTube перестал работать:

```bash
/etc/sing-box/update-servers.sh
```

Если скрипт не находит рабочий сервер — проверьте `subscription.url`

Подводные камни (2026-09-09, MR3020):

- **`short_id` ротируется при каждом fetch подписки** — «вчера работал, сегодня нет»
  лечится повторным `update-servers.sh`, а не откатом конфига.
- **Часть узлов подписки переехала на `type=xhttp`** — sing-box этот транспорт
  НЕ поддерживает (Xray-only; работает в Happ/NekoBox на Xray-ядре). Скрипт
  такие узлы пропускает (`SKIP ... type=xhttp` в logread) — не удаляйте этот фильтр.
- **Узел может проходить TCP-test и `sing-box check`, но душиться по throughput**
  (RTT живой, bulk <1 KB/s). `sing-box check` — офлайн-валидация, канал он не меряет.
  Решающий тест — bulk-curl страницы через `--interface tun0` (см. Сценарий И
  в TROUBLESHOOTING.md).

---

## Приложение C. Ручное обновление sing-box (когда opkg отстаёт)

Проверено 2026-09-09 на MR3020 (mipsel_24kc): апгрейд 1.11.15 → 1.13.21.
XHTTP не поддерживается ни одной версией sing-box — апгрейд ради него бесполезен.

```bash
# 1. Скачать с ПК (проверить наличие asset для своей архитектуры):
curl -sS "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=15" \
    | jq -r '[.[] | select(.prerelease==false)][0].tag_name'
# asset: sing-box-<ver>-linux-mipsle-softfloat.tar.gz  (MR3020/RT-AC1200 — mipsle, soft-float)

# 2. Залить на роутер (scp -O — dropbear без sftp; в /tmp не класть — tmpfs 28MB!):
scp -O -i ~/.ssh/id_rsa_legerity4u sing-box root@<ROUTER_IP>:/root/sing-box-new

# 3. На роутере (RAM-safe: бэкап → kill → замена → проверка версии):
cp -p /usr/bin/sing-box /root/sing-box.bak
killall -9 sing-box; sleep 3
cp -p /root/sing-box-new /usr/bin/sing-box && chmod +x /usr/bin/sing-box && sync
sing-box version | head -1

# 4. Пересобрать конфиг и запустить:
/etc/sing-box/update-servers.sh

# ⚠️ Перед тяжёлыми операциями (sing-box check) на 64 MB RAM поднимите swap:
dd if=/dev/zero of=/overlay/swapfile bs=1M count=256
chmod 600 /overlay/swapfile && mkswap /overlay/swapfile && swapon /overlay/swapfile
# persist: uci add fstab swap; uci set fstab.@swap[-1].device='/overlay/swapfile';
#          uci set fstab.@swap[-1].enabled='1'; uci commit fstab
```

> opkg-база после ручной замены остаётся на старой версии — будущий
> `opkg upgrade sing-box` перезапишет бинарник. Держите бэкап `/root/sing-box.bak`.

---

## Итоговый список на роутере

| Файл / состояние | Источник |
|---|---|
| `/etc/sing-box/update-servers.sh` | `router-files/update-servers.sh` |
| `/etc/sing-box/auto-update.sh` | `router-files/auto-update.sh` (cron 02:00, шаг 10) |
| `/etc/sing-box/tun-healthcheck.sh` | `router-files/tun-healthcheck.sh` (healthcheck ключей) |
| `/etc/sing-box/singbox-pbr-watch.sh` | `router-files/singbox-pbr-watch.sh` |
| `/etc/sing-box/subscription.url` | создан на шаге 2 |
| `/etc/sing-box/proxy-tun.nft` | `router-files/proxy-tun.nft` |
| `/etc/sing-box/proxy-tun.d/ajax.nft` | `router-files/proxy-tun.d/ajax.nft` (опциональный, include) |
| `/etc/init.d/sing-box` | `router-files/sing-box.init` (заменяет пакетный) |
| `/etc/init.d/singbox-pbr` | `router-files/singbox-pbr` |
| `/etc/iproute2/rt_tables` | строка `100 youtube` |
| `/etc/config/firewall` | zone `vpn` + forwarding lan→vpn |
| `/etc/config/dhcp` | server=9.9.9.9,1.0.0.1 |
| sing-box запущен, tun0 UP | шаг 11 |
| cron: `0 2 * * * auto-update.sh` | шаг 10 |
