#!/bin/bash
# tun-healthcheck.sh — сверка текущего outbound с подпиской по ВСЕЙ секции
# параметров. Из config.json берутся host, port и параметры Reality/VLESS
# (pbk, sid, sni, fp, flow + константы type/security/encryption) и ищется
# ХОТЯ БЫ ОДНА строка подписки для этого host:port с полным совпадением.
# Совпадения нет → update-servers.sh (свежая подписка → новый конфиг →
# рестарт sing-box).
#
# Вызывается из cron (15,45 * * * *) и из singbox-pbr-watch.sh (~раз в час).
#
# Отличия от версии до 2026-09-10:
#   - сверяется вся параметрическая секция, а не только pbk. Провайдер
#     ротирует sid при каждом fetch подписки — старый скрипт (pbk-only)
#     на ротацию никогда не реагировал
#   - проверяются ВСЕ строки подписки для host, а не только первая
#     (у одного host бывает несколько строк с разными портами/ключами)
#   - если host исчез из подписки — тоже триггер (раньше — тихий exit)

set -eu
LOG_TAG="tun-health"
SUB_URL_FILE=/etc/sing-box/subscription.url
CONF_FILE=/etc/sing-box/config.json
UPD_SCRIPT=/etc/sing-box/update-servers.sh
LOCK=/tmp/tun-healthcheck.lock
TMP_SUB=/tmp/tun-healthcheck.sub.$$

[ -f "$LOCK" ] && exit 0
touch "$LOCK"
trap 'rm -f "$LOCK" "$TMP_SUB"' EXIT

# --- текущий outbound из config.json ---
C_HOST=$(jq -r '.outbounds[0].server // ""' "$CONF_FILE" 2>/dev/null || echo "")
C_PORT=$(jq -r '.outbounds[0].server_port // ""' "$CONF_FILE" 2>/dev/null || echo "")
C_PBK=$(jq -r '.outbounds[0].tls.reality.public_key // ""' "$CONF_FILE" 2>/dev/null || echo "")
C_SID=$(jq -r '.outbounds[0].tls.reality.short_id // ""' "$CONF_FILE" 2>/dev/null || echo "")
C_SNI=$(jq -r '.outbounds[0].tls.server_name // ""' "$CONF_FILE" 2>/dev/null || echo "")
C_FP=$(jq -r '.outbounds[0].tls.utls.fingerprint // ""' "$CONF_FILE" 2>/dev/null || echo "")
C_FLOW=$(jq -r '.outbounds[0].flow // ""' "$CONF_FILE" 2>/dev/null || echo "")

if [ -z "$C_HOST" ] || [ -z "$C_PORT" ] || [ -z "$C_PBK" ]; then
    exit 0    # конфиг не читается / не наш формат — healthcheck не судья
fi

sub_url=$(cat "$SUB_URL_FILE" 2>/dev/null | tr -d ' \t\n\r')
[ -z "$sub_url" ] && exit 0

sub=$(curl -sS --max-time 30 "$sub_url" 2>/dev/null) || exit 0
[ -z "$sub" ] && exit 0
dec=$(echo "$sub" | base64 -d 2>/dev/null) || dec="$sub"
[ -z "$dec" ] && exit 0

# значение параметра из query-string: qget "a=1&b=2" b -> "2"
qget() {
    printf '%s\n' "$1" | tr '&' '\n' | sed -n "s/^$2=//p" | head -1
}

# подписка во временный файл: содержимое подписки НЕ прогонять через
# heredoc/eval — command substitution в данных = инъекция
printf '%s\n' "$dec" > "$TMP_SUB"

match_found=0
lines_for_host=0

while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in vless://*) ;; *) continue ;; esac

    url=${line#vless://}
    url_no_frag=${url%%#*}
    hostport_qs=${url_no_frag#*@}      # host:port?query
    hostport=${hostport_qs%%\?*}
    qs=${hostport_qs#*\?}              # вся секция параметров

    l_host=${hostport%%:*}
    l_rest=${hostport#*:}
    l_port=${l_rest%%/*}

    [ "$l_host" = "$C_HOST" ] || continue
    [ "$l_port" = "$C_PORT" ] || continue
    lines_for_host=$((lines_for_host + 1))

    if [ "$(qget "$qs" pbk)"        = "$C_PBK"  ] \
       && [ "$(qget "$qs" sid)"     = "$C_SID"  ] \
       && [ "$(qget "$qs" sni)"     = "$C_SNI"  ] \
       && [ "$(qget "$qs" fp)"      = "$C_FP"   ] \
       && [ "$(qget "$qs" flow)"    = "$C_FLOW" ] \
       && [ "$(qget "$qs" type)"     = "tcp"     ] \
       && [ "$(qget "$qs" security)" = "reality" ] \
       && [ "$(qget "$qs" encryption)" = "none" ]; then
        match_found=1
        break
    fi
done < "$TMP_SUB"

if [ "$match_found" -eq 1 ]; then
    exit 0
fi

logger -t "$LOG_TAG" "params changed (${lines_for_host} строк(и) для текущего сервера, совпадений 0) — запускаю update-servers.sh" || true
"$UPD_SCRIPT"
