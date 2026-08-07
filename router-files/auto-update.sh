#!/bin/sh
# auto-update.sh — ежедневное обновление списка серверов sing-box (cron 02:00)
# Запускает update-servers.sh (который сам рестартует sing-box и поднимает tun0),
# затем проверяет, что всё поднялось, и логирует итог в stdout (cron пишет в лог).

log() {
	echo "[$(date '+%F %T')] $*"
}

START=$(date '+%T')
log "старт автообновления"

# Примечание: update-servers.sh использует set -eu и из-за этого может вернуть
# ненулевой код (exit 2), если в момент ip rule add правило 100 уже создал
# watcher (только tun0 поднялся). Код выхода не берём за критерий успеха —
# смотрим фактическое состояние sing-box/tun0/table 100.
/etc/sing-box/update-servers.sh
RC=$?
if [ "$RC" -ne 0 ]; then
	log "WARN: update-servers.sh вернул код $RC (некритично, оценка ниже)"
fi

# ждём sing-box + tun0, затем ретраим table 100 / rule (watcher поднимает их на событии tun0)
for i in $(seq 45); do
	if pgrep sing-box >/dev/null 2>&1 && \
	   ip -4 addr show tun0 2>/dev/null | grep -q "inet "; then
		break
	fi
	sleep 2
done

# возвращает 1 при провале, 0 при успехе
check_state() {
	if ! pgrep sing-box >/dev/null 2>&1; then return 1; fi
	if ! ip -4 addr show tun0 2>/dev/null | grep -q "inet "; then return 1; fi
	if ! ip route show table 100 2>/dev/null | grep -q "default dev tun0"; then return 1; fi
	if ! ip route show table 100 2>/dev/null | grep -q "192.168.1.0/24 dev br-lan"; then return 1; fi
	if ! ip rule show | grep -q "fwmark 0x64 lookup youtube"; then return 1; fi
}

# таблица 100 поднимается watcher'ом с задержкой — пробуем до 40s
for i in $(seq 20); do
	check_state && break
	sleep 2
done

if check_state; then
	log "OK: автообновление прошло ($START → $(date '+%T')), sing-box/tun0/table 100 в порядке (rc=$RC)"
else
	log "ERR: sing-box/tun0/table100 не в порядке после обновления (rc=$RC)"
	log "  singbox_procs=$(pgrep sing-box | wc -l)"
	log "  tun0=$(ip -4 addr show tun0 2>/dev/null | grep -c 'inet ')"
	log "  table100:"; ip route show table 100
	exit 1
fi