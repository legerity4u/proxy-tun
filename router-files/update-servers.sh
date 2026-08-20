#!/bin/bash
# update-servers.sh — скачать подписку, отобрать лучший сервер из
# short-list стран, проверить через sing-box check, сгенерировать config.json
# и перезапустить sing-box.
#
#   --dry-run   только показать отбор, config.json не трогать
#
# Страны short-list (зашиты): Финляндия, Нидерланды, Венгрия
# Матчим по флагам (URL-encoded) — провайдер кодирует названия стран в метках,
# русские названия оставлены как fallback для старого формата подписки.
#   🇫🇮 Финляндия  = %F0%9F%87%AB%F0%9F%87%AE
#   🇳🇱 Нидерланды = %F0%9F%87%B3%F0%9F%87%B1
#   🇭🇺 Венгрия    = %F0%9F%87%AD%F0%9F%87%BA
# Отбор: все серверы этих стран → TCP-test (nc) → топ-3 по RTT
# → sing-box check (Reality handshake) → первый прошедший → config.json
# → restart sing-box

set -eu

LOG_TAG="update-servers"
SELF="update-servers"
COUNTRIES="%F0%9F%87%AB%F0%9F%87%AE|%F0%9F%87%B3%F0%9F%87%B1|%F0%9F%87%AD%F0%9F%87%BA|Финляндия|Нидерланды|Венгрия"
TOP_N=3
TCP_TIMEOUT=2
CHECK_TIMEOUT=90

SUB_URL_FILE=/etc/sing-box/subscription.url
CONF_FILE=/etc/sing-box/config.json
TMPDIR=/tmp/servers-test.$$
TMP_CONF=$TMPDIR/config.json
DRY_RUN=false
START_TS=$(date '+%T')

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

log() { local ts; ts=$(date '+%T'); logger -t "$LOG_TAG" "[$ts] $*"; echo "[$ts] $*"; }

cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

# ---------------------------------------------------------------
# 1. убить любой sing-box перед check
# ---------------------------------------------------------------
if pgrep sing-box >/dev/null 2>&1; then
    log "WARN: sing-box запущен, убиваю"
    for i in 1 2 3; do
        killall -9 sing-box 2>/dev/null || true
        pkill -9 -f "sing-box check" 2>/dev/null || true
        sleep 7
        pgrep sing-box >/dev/null 2>&1 || { sleep 1; break; }
    done
    if pgrep sing-box >/dev/null 2>&1; then
        log "ERR: не удалось убить sing-box после 3 попыток"
        exit 1
    fi
fi

# ---------------------------------------------------------------
# 2. скачать подписку
# ---------------------------------------------------------------
sub_url=$(cat "$SUB_URL_FILE" 2>/dev/null | tr -d ' \t\n\r')
[ -z "$sub_url" ] && { log "ERR: subscription.url пуст"; exit 1; }

sub=$(curl -sS --max-time 30 "$sub_url" 2>/dev/null) || {
    log "ERR: подписка недоступна ($sub_url)"
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
# 3. отфильтровать по странам
# ---------------------------------------------------------------
filtered=$(echo "$dec" | grep -E "^vless://.*#.*($COUNTRIES)" || true)
filtered_count=$(echo "$filtered" | grep -c . || true)
log "отфильтровано ($COUNTRIES): $filtered_count"

[ "$filtered_count" -eq 0 ] && { log "ERR: ни одного сервера из short-list"; exit 1; }

# ---------------------------------------------------------------
# 4. TCP-test всех отфильтрованных + RTT
# ---------------------------------------------------------------
mkdir -p "$TMPDIR"
results="$TMPDIR/results.txt"
echo "$filtered" | while IFS= read -r line; do
    [ -z "$line" ] && continue

    url=${line#vless://}
    url=${url%%#*}
    host=${url#*@}; host=${host%%:*}
    rest=${url#*:}; port=${rest%%[^0-9]*}

    start=$EPOCHREALTIME
    if timeout $TCP_TIMEOUT nc "$host" "$port" < /dev/null 2>/dev/null; then
        end=$EPOCHREALTIME
        rtt=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.0f", (e-s)*1000}')
        echo "$rtt ${line}" >> "$results"
    fi
done

[ ! -s "$results" ] && { log "ERR: ни один сервер не прошёл TCP"; exit 1; }

log "TCP-test: $(wc -l < "$results") живы, топ по RTT:"
sort -n "$results" | head -5 | awk '{print "\t" $1 "ms " substr($0, index($0,$2))}' | while IFS= read -r l; do log "$l"; done

# ---------------------------------------------------------------
# 5. взять топ-3 по RTT
# ---------------------------------------------------------------
top_n=$(sort -n "$results" | head -$TOP_N)
top_count=$(echo "$top_n" | grep -c . || true)
log "топ-${TOP_N}: ${top_count} серверов"

# ---------------------------------------------------------------
# 6. sing-box check для каждого из топ-3
# ---------------------------------------------------------------
select_server() {
    local line=$1
    local rtt=$2

    local url=${line#vless://}
    local frag=${line#*#}
    local url_no_frag=${url%%#*}

    local uuid_v=${url_no_frag%%@*}
    local rest=${url_no_frag#*@}
    local host=${rest%%:*}
    local portrest=${rest#*:}
    local port=${portrest%%/*}
    port=${port%%\?*}

    local qs=${url_no_frag#*\?}
    local pbk sid sni fp flow
    pbk=$(echo "$qs" | sed -n 's/.*pbk=\([^&]*\).*/\1/p')
    sid=$(echo "$qs" | sed -n 's/.*sid=\([^&]*\).*/\1/p')
    sni=$(echo "$qs" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
    fp=$(echo "$qs"  | sed -n 's/.*fp=\([^&]*\).*/\1/p')
    flow=$(echo "$qs" | sed -n 's/.*flow=\([^&]*\).*/\1/p')
    [ -z "$flow" ] && flow="xtls-rprx-vision"

    cat > "$TMP_CONF" <<EOF
{
  "log": { "level": "info", "timestamp": true },
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

    log "  check ${host}:${port} ($frag, rtt=${rtt}ms)..."

    if timeout $CHECK_TIMEOUT sing-box check -c "$TMP_CONF" >/dev/null 2>&1; then
        log "  OK"
        return 0
    else
        log "  FAIL"
        return 1
    fi
}

while IFS= read -r line; do
    [ -z "$line" ] && continue
    rtt=$(echo "$line" | awk '{print $1}')
    rest_line=$(echo "$line" | cut -d' ' -f2-)
    if select_server "$rest_line" "$rtt"; then
        echo "$rest_line" > "$TMPDIR/winner.txt"
        echo "$rtt" > "$TMPDIR/winner_rtt.txt"
        break
    fi
done <<EOF
$top_n
EOF

# ---------------------------------------------------------------
# 7. проверить результат
# ---------------------------------------------------------------
if [ ! -f "$TMPDIR/winner.txt" ]; then
    log "ERR: ни один сервер из топ-${TOP_N} не прошёл проверку"
    log "-- отмена — туннель не запущен"
    exit 1
fi

winner=$(cat "$TMPDIR/winner.txt")
winner_rtt=$(cat "$TMPDIR/winner_rtt.txt")
url=${winner#vless://}
frag=${winner#*#}
host="${url#*@}"; host="${host%%:*}"

$DRY_RUN && log "pbk=$(echo "$winner" | grep -oE 'pbk=[^&]+' | head -1)"

log "выбран: ${host} ${frag} (rtt=${winner_rtt}ms)"

# ---------------------------------------------------------------
# 8. сгенерировать config.json
# ---------------------------------------------------------------
if $DRY_RUN; then
    log "dry-run: config.json НЕ записан"
else
    # перегенерировать через ту же функцию, что в select_server
    url_no_frag=${url%%#*}
    uuid_v=${url_no_frag%%@*}
    rest=${url_no_frag#*@}
    host=${rest%%:*}
    portrest=${rest#*:}
    port=${portrest%%/*}; port=${port%%\?*}
    qs=${url_no_frag#*\?}
    pbk=$(echo "$qs" | sed -n 's/.*pbk=\([^&]*\).*/\1/p')
    sid=$(echo "$qs" | sed -n 's/.*sid=\([^&]*\).*/\1/p')
    sni=$(echo "$qs" | sed -n 's/.*sni=\([^&]*\).*/\1/p')
    fp=$(echo "$qs"  | sed -n 's/.*fp=\([^&]*\).*/\1/p')
    flow=$(echo "$qs" | sed -n 's/.*flow=\([^&]*\).*/\1/p')
    [ -z "$flow" ] && flow="xtls-rprx-vision"

    cat > "$CONF_FILE" <<EOF
{
  "log": { "level": "info", "output": "/var/log/sing-box.log", "timestamp": true },
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
    log "config.json записан"
fi

# ---------------------------------------------------------------
# 9. перезапустить sing-box
# ---------------------------------------------------------------
if ! $DRY_RUN; then
    log "жду 15s освобождения памяти..."
    sleep 15
    log "запускаю sing-box..."
    rm -rf /tmp/sing-box
    mkdir -p /tmp/sing-box
    setsid /usr/bin/sing-box run -c "$CONF_FILE" -D /tmp/sing-box \
        </dev/null >/dev/null 2>&1 &
    SB_PID=$!
    echo "$SB_PID" > /var/run/sing-box.pid
    sleep 20
    if pgrep sing-box >/dev/null 2>&1; then
        END_TS=$(date '+%T')
        log "sing-box запущен (${START_TS} → ${END_TS})"

        for i in $(seq 30); do
            ip -4 addr show tun0 2>/dev/null | grep -q "inet " && break
            sleep 2
        done
        sleep 3
        ip rule add pref 100 fwmark 0x64 lookup 100 2>/dev/null || true
        for i in 1 2 3; do
            ip route replace default dev tun0 scope link table 100 2>/dev/null && break
            sleep 2
        done
        ip route replace 192.168.1.0/24 dev br-lan scope link table 100 2>/dev/null
        log "PBR routes added for tun0"
    else
        log "ERR: sing-box не запустился после restart"
        exit 1
    fi
fi
