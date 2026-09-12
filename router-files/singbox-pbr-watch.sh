#!/bin/sh
# Event-driven watcher: detects tun0 state changes and updates PBR table 100.
# Polls every 10s. Runs tun-healthcheck.sh every ~1 hour (360 iterations at 10s).
# Channel self-heal ("works — don't touch"): every ~60s (6 iterations), ladder:
#   consumers on br-lan? -> youtube demand counter grows? -> tun0 TX frozen?
#   -> probe 204 + bulk -> only then update-servers.sh (cooldown 30 min).
# All signals are tunnel-scoped: direct traffic (VK etc.) is invisible by design.

check_health() {
	[ $ITER -lt 360 ] && return
	ITER=0
	[ "$CUR" != "up" ] && return
	/etc/sing-box/tun-healthcheck.sh 2>/dev/null
}

check_singbox_alive() {
	[ $ITER -lt 6 ] && return
	[ "$CUR" != "up" ] && return
	if ! pgrep sing-box >/dev/null 2>&1; then
		logger -t singbox-pbr "WARN: sing-box не запущен"
	fi
}

trigger_heal() {
	COOLDOWN=30
	SUSPECT=0
	/etc/sing-box/update-servers.sh >/dev/null 2>&1 &
}

# Repair the channel ONLY on confirmed symptoms. Counter deltas every 6
# ticks (60s). Suspicion = demand grew while tun0 TX delta < 10000 B/min
# (~170 B/s; TROUBLESHOOTING И documents bulk 0-585 B/s on throttled nodes).
# Two consecutive windows confirm; probe (204, then bulk >=50 KB/s) decides.
check_channel() {
	CH=$((CH + 1))
	[ $CH -lt 6 ] && return
	CH=0
	[ "$CUR" != "up" ] && return
	[ "$COOLDOWN" -gt 0 ] && COOLDOWN=$((COOLDOWN - 1))

	# 0: no live consumers on br-lan -> nobody needs the tunnel, touch nothing
	if ! ip neigh show dev br-lan 2>/dev/null | grep -qE 'REACHABLE|DELAY|PROBE'; then
		SUSPECT=0
		DEMAND_PREV=""
		return
	fi

	# 1: youtube demand (sum of mark-set rule counters in prerouting)
	DEMAND=$(nft list chain inet proxy_tun prerouting 2>/dev/null \
		| grep 'mark set' | grep -o 'packets [0-9]*' \
		| awk '{s+=$2} END{print s+0}')
	# 2: tunnel counters (/proc/net/dev tun0: $2=RXbytes ${10}=TXbytes)
	set -- $(grep -m1 'tun0:' /proc/net/dev 2>/dev/null)
	TX=${10}

	[ -n "$DEMAND" ] && [ -n "$TX" ] || { DEMAND_PREV=""; return; }

	if [ -n "$DEMAND_PREV" ] && [ "$DEMAND" -ge "$DEMAND_PREV" ] && [ "$TX" -ge "$TX_PREV" ]; then
		DEMAND_D=$((DEMAND - DEMAND_PREV))
		TX_D=$((TX - TX_PREV))
		if [ "$DEMAND_D" -gt 0 ] && [ "$TX_D" -lt 10000 ]; then
			SUSPECT=$((SUSPECT + 1))
		else
			SUSPECT=0
		fi
		# 3: suspicion confirmed twice -> probe before touching anything
		if [ "$SUSPECT" -ge 2 ] && [ "$COOLDOWN" -le 0 ] \
			&& ! pgrep -f update-servers.sh >/dev/null 2>&1; then
			CODE=$(curl --interface tun0 -m 8 -sS -o /dev/null \
				-w '%{http_code}' https://www.youtube.com/generate_204 2>/dev/null)
			if [ "$CODE" != "204" ]; then
				logger -t singbox-pbr "channel dead (204=$CODE, tx_d=$TX_D) -> update-servers.sh"
				trigger_heal
			else
				BULK=$(curl --interface tun0 -m 15 -sS -o /dev/null \
					-w '%{speed_download}' \
					'https://speed.cloudflare.com/__down?bytes=300000' 2>/dev/null | cut -d. -f1)
				if [ -z "$BULK" ] || [ "$BULK" -lt 50000 ]; then
					logger -t singbox-pbr "channel throttled (bulk=${BULK:-timeout}B/s) -> update-servers.sh"
					trigger_heal
				else
					logger -t singbox-pbr "probe ok (204, bulk=${BULK}B/s) -> no action"
					SUSPECT=0
				fi
			fi
		fi
	fi
	DEMAND_PREV=$DEMAND
	TX_PREV=$TX
}

LAST=""
ITER=0
CH=0
SUSPECT=0
COOLDOWN=0
DEMAND_PREV=""
TX_PREV=0
while true; do
	if [ -d /sys/class/net/tun0 ] && ip link show tun0 2>/dev/null | grep -q "UP,LOWER_UP"; then
		CUR="up"
	else
		CUR="down"
	fi
	if [ "$CUR" = "$LAST" ] && [ -n "$LAST" ]; then
		sleep 10
		ITER=$((ITER + 1))
		check_health
		check_singbox_alive
		check_channel
		if [ -d /sys/class/net/tun0 ] && ip link show tun0 2>/dev/null | grep -q "UP,LOWER_UP"; then
			if ! ip route show table 100 2>/dev/null | grep -q "default dev tun0"; then
				ip rule add pref 100 fwmark 0x64 lookup 100 2>/dev/null
				ip route replace default dev tun0 scope link table 100
				ip route replace 192.168.1.0/24 dev br-lan scope link table 100
				logger -t singbox-pbr "route missing -> restored"
			fi
		else
			ip route flush table 100 2>/dev/null
		fi
		continue
	fi
	# первый запуск: если tun0 уже UP — добавляем маршруты
	if [ -z "$LAST" ] && [ "$CUR" = "up" ]; then
		ip rule add pref 100 fwmark 0x64 lookup 100 2>/dev/null
		ip route replace default dev tun0 scope link table 100
		ip route replace 192.168.1.0/24 dev br-lan scope link table 100
		logger -t singbox-pbr "tun0 already UP on start -> routes added"
	fi
	LAST="$CUR"
	if [ "$CUR" = "up" ]; then
		sleep 1
		ip rule add pref 100 fwmark 0x64 lookup 100 2>/dev/null
		ip route replace default dev tun0 scope link table 100
		ip route replace 192.168.1.0/24 dev br-lan scope link table 100
		logger -t singbox-pbr "tun0 UP -> routes added"
	else
		ip route flush table 100 2>/dev/null
		logger -t singbox-pbr "tun0 DOWN -> routes flushed"
	fi
	ITER=$((ITER + 1))
	check_singbox_alive
	check_channel
done
