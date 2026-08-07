#!/bin/bash
# tun-healthcheck.sh — проверка Reality-ключей текущего сервера.
# Раз в час вызывается из singbox-pbr-watch.sh.
# Если pbk/sid в подписке отличаются от config.json → ключи сменились
# → запускает update-servers.sh и рестарт sing-box.

set -eu
LOG_TAG="tun-health"
SUB_URL_FILE=/etc/sing-box/subscription.url
CONF_FILE=/etc/sing-box/config.json
LOCK=/tmp/tun-healthcheck.lock

[ -f "$LOCK" ] && exit 0
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

CURRENT_PBK=$(jq -r '.outbounds[0].tls.reality.public_key' "$CONF_FILE" 2>/dev/null || echo "")
CURRENT_SID=$(jq -r '.outbounds[0].tls.reality.short_id' "$CONF_FILE" 2>/dev/null || echo "")
[ -z "$CURRENT_PBK" ] && exit 0

sub_url=$(cat "$SUB_URL_FILE" | tr -d ' \t\n\r')
[ -z "$sub_url" ] && exit 0

sub=$(curl -sS --max-time 30 "$sub_url" 2>/dev/null) || exit 0
dec=$(echo "$sub" | base64 -d 2>/dev/null) || dec="$sub"

CURRENT_HOST=$(jq -r '.outbounds[0].server' "$CONF_FILE" 2>/dev/null || echo "")
[ -z "$CURRENT_HOST" ] && exit 0

line=$(echo "$dec" | grep -F "$CURRENT_HOST" | head -1)
[ -z "$line" ] && exit 0

qs=${line#*\?}
pbk=$(echo "$qs" | sed -n 's/.*pbk=\([^&]*\).*/\1/p')
sid=$(echo "$qs" | sed -n 's/.*sid=\([^&]*\).*/\1/p')

if [ "$pbk" != "$CURRENT_PBK" ]; then
    logger -t "$LOG_TAG" "keys changed, running update-servers.sh"
    /etc/sing-box/update-servers.sh
fi
