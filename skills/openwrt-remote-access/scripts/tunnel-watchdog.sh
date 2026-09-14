#!/bin/sh
# tunnel-watchdog: catch the state "process alive, forward dead".
#
# dbclient has no equivalent of OpenSSH's ExitOnForwardFailure: when the remote
# forward is refused it logs the refusal and keeps running as a plain session.
# procd sees a healthy process and respawns nothing, so the tunnel can stay dead
# for days while every naive check says it is up.
#
# Run from cron every five minutes:
#   */5 * * * * /usr/bin/tunnel-watchdog.sh
#
# The check is deliberately LOCAL. The router's key on the far side is
# restricted to port forwarding (restrict,port-forwarding,command="/bin/false")
# and cannot run `ss` there — and loosening that to please a watchdog would be
# the wrong trade. dbclient reports the refusal itself, and procd puts it in
# logread.

SERVICE="reverse-tunnel"                       # /etc/init.d/<SERVICE>
STAMP="/tmp/tunnel-watchdog.stamp"
PATTERN="Remote TCP forward request failed"

# Do not interfere during the first 90 s of uptime: the tunnel service is still
# coming up and a restart here would only add a race.
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
[ -n "$up" ] && [ "$up" -lt 90 ] && exit 0

# Liveness marker, written before any check — a watchdog that stays silent when
# healthy is indistinguishable from one that is not running at all. `ls -l` on
# this file answers "is the watchdog alive?" in one command.
touch "$STAMP"

# No process at all is procd's business, not ours.
pids=$(pgrep dbclient)
[ -z "$pids" ] && exit 0

for pid in $pids; do
	if logread | grep -q "dbclient\[$pid\].*$PATTERN"; then
		logger -t tunnel-watchdog "forward refused for pid $pid -> restarting $SERVICE"
		/etc/init.d/"$SERVICE" restart
		exit 0
	fi
done
