#!/bin/sh
# Reverse SSH tunnel carried INSIDE the router's VPN interface — the twin of
# reverse-tunnel.init, which goes over the bare WAN. See SKILL.md §6.
#
# Both tunnels go to the same <VPS> address, so routing by destination cannot split
# them. This one binds dbclient to the VPN interface's own address, and a source
# rule sends that address through the interface. Rule and route are re-applied before
# every attempt: the route vanishes whenever the interface is deleted (a tunnel
# restart, a reboot), and procd respawns this script whenever dbclient exits.
#
# After a tunnel restart the old connection is dead but dbclient does not know yet: it
# leaves on its keepalive timeout, comes back to a forward still held by the stale
# session on <VPS> (refused, exits again), and wins on the next try — about two minutes
# in all. Restart this service from wherever the tunnel is brought up if that is too slow.
#
# Install as /usr/bin/reverse-tunnel-via-vpn.sh and run it from a procd service that
# is a copy of reverse-tunnel.init with:
#     procd_set_param command /usr/bin/reverse-tunnel-via-vpn.sh
# and START above the VPN's own init script.

IF=vpn0                   # <VPN_IF>
TABLE=51822               # a table number nothing else uses
PRIO=31000                # below main (32766), above nothing that matters here
HOST=vps.example.com      # <VPS>
KEY=/etc/dropbear/id_tunnel
RPORT=2226                # a DIFFERENT port on <VPS> from the WAN tunnel's

ADDR=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [ -z "$ADDR" ]; then
	logger -t reverse-tunnel-vpn "$IF has no address yet, retrying"
	sleep 15
	exit 1
fi

while ip rule del lookup "$TABLE" 2>/dev/null; do :; done
ip rule add from "$ADDR" lookup "$TABLE" priority "$PRIO"
ip route replace default dev "$IF" table "$TABLE"

# ExitOnForwardFailure needs dropbear 2025.x; see SKILL.md §4 for older builds.
exec /usr/bin/dbclient -o ExitOnForwardFailure=yes -K 30 -I 0 -i "$KEY" \
	-b "$ADDR" -N -R "${RPORT}:localhost:22" "root@${HOST}"
