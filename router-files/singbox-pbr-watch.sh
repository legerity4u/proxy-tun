#!/bin/sh
# Event-driven watcher: detects tun0 state changes and updates PBR table 100.
# Also runs tun-healthcheck.sh every ~1 hour (1800 iterations at 2s).

check_health() {
	[ $ITER -lt 1800 ] && return
	ITER=0
	[ "$CUR" != "up" ] && return
	/etc/sing-box/tun-healthcheck.sh 2>/dev/null
}

check_singbox_alive() {
	[ $ITER -lt 30 ] && return
	[ "$CUR" != "up" ] && return
	if ! pgrep sing-box >/dev/null 2>&1; then
		logger -t singbox-pbr "WARN: sing-box не запущен"
	fi
}

LAST=""
ITER=0
while true; do
	if [ -d /sys/class/net/tun0 ] && ip link show tun0 2>/dev/null | grep -q "UP,LOWER_UP"; then
		CUR="up"
	else
		CUR="down"
	fi
	if [ "$CUR" = "$LAST" ] && [ -n "$LAST" ]; then
		sleep 2
		ITER=$((ITER + 1))
		check_health
		check_singbox_alive
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
done
