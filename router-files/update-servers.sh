#!/bin/bash
# update-servers.sh — скачать подписку, случайно перебрать живые vless-серверы
# и оставить первый, чей канал реально тянет bulk-трафик через tun0.
#
#   --dry-run   показать случайный порядок кандидатов, ничего не менять
#
# Алгоритм (2026-09-11, замена «топ-3 по RTT + sing-box check»):
#   1. подписка → все vless://; скип type=xhttp (sing-box не умеет не-tcp);
#      скип узлов, чьё имя содержит Россия|Torrent|GAMING (EXCLUDE_RE,
#      регистронезависимо; имя фрагмента декодируется из URL-encoding);
#      COUNTRIES env (опционально) — regexp-белый список по имени;
#      по умолчанию — все узлы, кроме чёрного списка
#   2. TCP-test (nc) — дешёвый отсев мёртвых портов
#   3. перемешать случайно (seed из /dev/urandom)
#   4. для каждого кандидата, до первого рабочего:
#      config.json → рестарт sing-box → PBR → live-тест через tun0:
#      generate_204 (2 попытки) + bulk ≥ BULK_MIN_KBPS (2 попытки)
#   5. рабочий найден → стоп. Список исчерпан → ERR (остаётся последний
#      протестированный конфиг; retry по cron)
#
# Почему не «топ по RTT + sing-box check»: задушенный узел проходит оба теста
# (RTT жив, Reality-handshake жив), но bulk=0 — Сценарий И в docs/TROUBLESHOOTING.md.
# Решает только сквозной live-тест канала.
#
# Env:
#   BULK_MIN_KBPS=50      порог «канал жив» в KB/s
#   COUNTRIES="regexp"    опц. белый список по имени узла (по умолчанию — все не-исключённые)
#   EXCLUDE_RE="Россия|Torrent|GAMING"
#                         чёрный список подстрок в имени узла (регистронезависимо);
#                         провайдер метит так узлы не для нас: Россия — прямые,
#                         Torrent/GAMING — нерекомендованные

set -eu

LOG_TAG="update-servers"
TCP_TIMEOUT=2
SUB_URL_FILE=/etc/sing-box/subscription.url
CONF_FILE=/etc/sing-box/config.json
TMPDIR=/tmp/servers-test.$$
DRY_RUN=false
START_TS=$(date '+%T')

BULK_MIN_KBPS=${BULK_MIN_KBPS:-50}
BULK_URL="https://speed.cloudflare.com/__down?bytes=300000"
COUNTRIES=${COUNTRIES:-}
EXCLUDE_RE=${EXCLUDE_RE:-"Россия|Torrent|GAMING"}

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

log() { local ts; ts=$(date '+%T'); logger -t "$LOG_TAG" "[$ts] $*"; echo "[$ts] $*"; }

# фрагмент-имя провайдер URL-кодирует (%D0%A0… = «Россия») — для фильтров нужен UTF-8
urldecode() { printf '%b' "${1//%/\\x}"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT
trap '' HUP

# ---------------------------------------------------------------
# helper: убить sing-box (быстро, с эскалацией)
# ---------------------------------------------------------------
kill_singbox() {
    pgrep sing-box >/dev/null 2>&1 || return 0
    log "WARN: sing-box запущен, убиваю"
    local i
    for i in 1 2 3; do
        killall -9 sing-box 2>/dev/null || true
        sleep 5
        pgrep sing-box >/dev/null 2>&1 || { sleep 1; return 0; }
    done
    log "ERR: не удалось убить sing-box после 3 попыток"
    return 1
}

# ---------------------------------------------------------------
# helper: сгенерировать config.json для строки vless:// (креды — только в файл)
# ---------------------------------------------------------------
gen_config() {
    local line=$1
    local url=${line#vless://}
    local url_no_frag=${url%%#*}
    local uuid_v=${url_no_frag%%@*}
    local rest=${url_no_frag#*@}
    local host=${rest%%:*}
    local portrest=${rest#*:}
    local port=${portrest%%/*}; port=${port%%\?*}
    local qs=${url_no_frag#*\?}
    local pbk sid sni fp flow
    pbk=$(echo "$qs" | sed -n 's/.*pbk=\([^&]*\).*/\1/p')
    sid=$(echo "$qs" | sed -n 's/.*sid=\([^&]*\).*/\1/p')
    sni=$(echo "$qs" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
    fp=$(echo "$qs"  | sed -n 's/.*fp=\([^&]*\).*/\1/p')
    flow=$(echo "$qs" | sed -n 's/.*flow=\([^&]*\).*/\1/p')
    [ -z "$flow" ] && flow="xtls-rprx-vision"

    cat > "$CONF_FILE" <<EOF
{
  "log": { "level": "warn", "output": "/overlay/etc/sing-box/sing-box.log", "timestamp": true },
  "inbounds": [{
    "type": "tun", "tag": "tun-in", "interface_name": "tun0",
    "address": ["172.19.0.1/30"], "mtu": 1500,
    "stack": "system",
    "auto_route": false, "strict_route": false
  }],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "flow": "$flow",
      "packet_encoding": "xudp",
      "server": "$host",
      "server_port": $port,
      "uuid": "$uuid_v",
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "public_key": "$pbk",
          "short_id": "$sid"
        },
        "server_name": "$sni",
        "utls": { "enabled": true, "fingerprint": "$fp" }
      },
      "transport": {}
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [],
    "final": "proxy",
    "auto_detect_interface": true
  }
}
EOF
    chmod 644 "$CONF_FILE"
}

# ---------------------------------------------------------------
# helper: запустить sing-box + дождаться tun0 + поднять PBR
# ---------------------------------------------------------------
start_singbox() {
    log "  жду 10s освобождения памяти..."
    sleep 10
    rm -rf /tmp/sing-box
    mkdir -p /tmp/sing-box
    setsid /usr/bin/sing-box run -c "$CONF_FILE" -D /tmp/sing-box \
        </dev/null >/dev/null 2>&1 &
    echo $! > /var/run/sing-box.pid
    local i
    for i in $(seq 15); do
        ip -4 addr show tun0 2>/dev/null | grep -q "inet " && break
        sleep 2
    done
    if ! ip -4 addr show tun0 2>/dev/null | grep -q "inet "; then
        log "  ERR: tun0 не поднялся за 30s, повторяю запуск"
        killall -9 sing-box 2>/dev/null || true
        sleep 5
        setsid /usr/bin/sing-box run -c "$CONF_FILE" -D /tmp/sing-box \
            </dev/null >/dev/null 2>&1 &
        echo $! > /var/run/sing-box.pid
        local j
        for j in $(seq 20); do
            ip -4 addr show tun0 2>/dev/null | grep -q "inet " && break
            sleep 2
        done
        if ! ip -4 addr show tun0 2>/dev/null | grep -q "inet "; then
            log "  ERR: tun0 не поднялся и на повторе"
            killall -9 sing-box 2>/dev/null || true
            return 1
        fi
    fi
    sleep 3
    ip rule add pref 100 fwmark 0x64 lookup 100 2>/dev/null || true
    local i
    for i in 1 2 3; do
        ip route replace default dev tun0 scope link table 100 2>/dev/null && break
        sleep 2
    done
    ip route replace 192.168.1.0/24 dev br-lan scope link table 100 2>/dev/null || true
    log "  tun0 поднят, PBR на месте"
    return 0
}

# ---------------------------------------------------------------
# helper: live-тест канала через tun0 (204 + bulk). Итог — в LIVE_RESULT
# ---------------------------------------------------------------
LIVE_RESULT=""
live_test() {
    local code="" speed try
    for try in 1 2; do
        code=$(curl --interface tun0 -m 10 -sS -o /dev/null -w '%{http_code}' \
               https://www.youtube.com/generate_204 2>/dev/null || true)
        [ "$code" = "204" ] && break
        code=""
        sleep 3
    done
    if [ "$code" != "204" ]; then
        LIVE_RESULT="204 не проходит"
        return 1
    fi
    for try in 1 2; do
        speed=$(curl --interface tun0 -m 20 -sS -o /dev/null -w '%{speed_download}' \
                "$BULK_URL" 2>/dev/null || true)
        if awk -v s="${speed:-0}" -v t="$BULK_MIN_KBPS" 'BEGIN{exit !(s+0 >= t*1024)}'; then
            LIVE_RESULT=$(awk -v s="${speed:-0}" 'BEGIN{printf "bulk %.1f KB/s", s/1024}')
            return 0
        fi
        sleep 3
    done
    LIVE_RESULT=$(awk -v s="${speed:-0}" -v t="$BULK_MIN_KBPS" \
        'BEGIN{printf "bulk %.1f KB/s < %d KB/s", s/1024, t}')
    return 1
}

mkdir -p "$TMPDIR"

# ---------------------------------------------------------------
# 1. скачать подписку (туннель пока не трогаем — меньше даунтайма)
# ---------------------------------------------------------------
sub_url=$(cat "$SUB_URL_FILE" 2>/dev/null | tr -d ' \t\n\r')
[ -z "$sub_url" ] && { log "ERR: subscription.url пуст"; exit 1; }

sub=$(curl -sS --max-time 30 "$sub_url" 2>/dev/null) || {
    log "ERR: подписка недоступна"
    exit 1
}
[ -z "$sub" ] && { log "ERR: пустой ответ подписки"; exit 1; }

if echo "$sub" | base64 -d >/dev/null 2>&1; then
    dec=$(echo "$sub" | base64 -d)
else
    dec="$sub"
fi

total=$(echo "$dec" | grep -c "^vless://" || true)
log "подписка: $total серверов"

# ---------------------------------------------------------------
# 2. кандидаты: только vless-строки; скип не-tcp; фильтры по имени узла
# ---------------------------------------------------------------
src_lines=$(echo "$dec" | grep -E "^vless://" || true)

cands="$TMPDIR/cands.txt"
: > "$cands"
echo "$src_lines" | while IFS= read -r line; do
    [ -z "$line" ] && continue

    url=${line#vless://}
    url=${url%%#*}
    host=${url#*@}; host=${host%%:*}
    rest=${url#*:}; port=${rest%%[^0-9]*}

    case "$line" in *#*) frag=${line#*#} ;; *) frag="" ;; esac
    frag_dec=$(urldecode "$frag")

    # COUNTRIES env — опц. белый список (regexp по декодированному имени)
    if [ -n "$COUNTRIES" ] && ! printf '%s' "$frag_dec" | grep -qE "$COUNTRIES"; then
        continue
    fi

    # sing-box не поддерживает xhttp (и др. не-tcp транспорты) — узлы провайдера
    # с type=xhttp генерируют конфиг с живым TCP, но мёртвым data-слоем (2026-09-09)
    ltype=$(echo "$url" | sed -n 's/.*[?&]type=\([^&]*\).*/\1/p')
    if [ -n "$ltype" ] && [ "$ltype" != "tcp" ]; then
        log "SKIP $host:$port (type=$ltype)"
        continue
    fi

    # чёрный список имён (регистронезависимо): Россия — прямые узлы,
    # Torrent/GAMING — провайдер метит узлы не для нашей задачи
    if printf '%s' "$frag_dec" | grep -qiE "$EXCLUDE_RE"; then
        log "SKIP $host:$port (исключён по имени: $frag_dec)"
        continue
    fi

    echo "$line" >> "$cands"
done

cands_n=$(wc -l < "$cands")
[ "$cands_n" -eq 0 ] && { log "ERR: нет валидных vless-кандидатов"; exit 1; }
log "кандидатов (tcp, не из чёрного списка): $cands_n"

# ---------------------------------------------------------------
# 3. TCP-test — дешёвый отсев мёртвых портов
# ---------------------------------------------------------------
alive="$TMPDIR/alive.txt"
: > "$alive"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    url=${line#vless://}; url=${url%%#*}
    host=${url#*@}; host=${host%%:*}
    rest=${url#*:}; port=${rest%%[^0-9]*}
    if timeout $TCP_TIMEOUT nc "$host" "$port" < /dev/null 2>/dev/null; then
        echo "$line" >> "$alive"
    fi
done < "$cands"

alive_n=$(wc -l < "$alive")
[ "$alive_n" -eq 0 ] && { log "ERR: ни один сервер не прошёл TCP"; exit 1; }
log "TCP-test: $alive_n живы"

# ---------------------------------------------------------------
# 4. случайный порядок (seed из /dev/urandom)
# ---------------------------------------------------------------
SEED=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')
[ -z "$SEED" ] && SEED=$$
order="$TMPDIR/order.txt"
awk -v seed="$SEED" 'BEGIN{srand(seed)}{printf "%d\t%s\n", int(rand()*100000000), $0}' \
    "$alive" | sort -n | cut -f2- > "$order"

if $DRY_RUN; then
    log "dry-run: случайный порядок кандидатов (конфиг и туннель не трогаю):"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        url=${line#vless://}; url=${url%%#*}
        case "$line" in *#*) frag=${line#*#} ;; *) frag="" ;; esac
        hp=${url#*@}; hp=${hp%%\?*}
        log "  $hp ($(urldecode "$frag"))"
    done < "$order"
    exit 0
fi

# ---------------------------------------------------------------
# 5. перебор в случайном порядке до первого рабочего (live-тест E2E)
# ---------------------------------------------------------------
log "тестирую в случайном порядке, до первого рабочего:"
attempt=0
winner=""
while IFS= read -r line; do
    [ -z "$line" ] && continue
    attempt=$((attempt + 1))
    url=${line#vless://}; url_nf=${url%%#*}
    case "$line" in *#*) frag=${line#*#} ;; *) frag="" ;; esac
    hp=${url_nf#*@}; hp=${hp%%\?*}
    log "[$attempt/$alive_n] $hp ($(urldecode "$frag"))"

    kill_singbox || exit 1
    gen_config "$line"
    if ! start_singbox; then
        log "  FAIL (sing-box/tun0 не поднялся)"
        continue
    fi

    if live_test; then
        log "  OK: $LIVE_RESULT"
        winner=$hp
        log "выбран: $winner ($(urldecode "$frag")) — попытка $attempt из $alive_n"
        break
    fi
    log "  FAIL ($LIVE_RESULT)"
done < "$order"

if [ -z "$winner" ]; then
    log "ERR: ни один из $alive_n кандидатов не прошёл live-тест"
    log "-- остаётся последний протестированный конфиг, retry по cron"
    exit 1
fi

END_TS=$(date '+%T')
log "готово (${START_TS} → ${END_TS})"
