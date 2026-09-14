#!/bin/sh
# vpn-failover: rotate the tunnel's endpoint when the tunnel stops carrying data.
#
# Run from cron every minute:
#   * * * * * /usr/bin/vpn-failover.sh
#
# Three guards that are not decoration:
#
#   1. The probe targets a host reachable ONLY inside the tunnel. Pinging a
#      public resolver proves nothing — it answers whether or not the packet
#      went through the VPN.
#   2. Nothing happens during the first 90 s of uptime, so the script cannot
#      race netifd while the interface is still coming up after a boot.
#   3. A lock file, because `ifup` can take longer than the cron interval and
#      two instances would fight over the same uci section.
#
# Adjust the five settings below; nothing else is device-specific.

IFACE="vpn0"                       # the VPN interface name in /etc/config/network
SECTION="@amneziawg_vpn0[0]"       # uci peer section; "@wireguard_vpn0[0]" for plain WG
ENDPOINTS="203.0.113.10 203.0.113.20 203.0.113.30"
TARGET="10.0.0.20"                 # a host that exists only inside the tunnel
LOCK="/tmp/vpn-failover.lock"

up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
[ -n "$up" ] && [ "$up" -lt 90 ] && exit 0

[ -f "$LOCK" ] && exit 0
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

check() { ping -c1 -W3 "$TARGET" >/dev/null 2>&1; }

# Two consecutive failures, not one: a single lost packet is not an outage.
check && exit 0
sleep 3
check && exit 0

current=$(uci -q get "network.$SECTION.endpoint_host")

next=""
found=0
for ep in $ENDPOINTS; do
	[ "$found" = "1" ] && { next="$ep"; break; }
	[ "$ep" = "$current" ] && found=1
done
# past the end of the list, or the current endpoint is not in it at all
[ -z "$next" ] && next=$(echo "$ENDPOINTS" | cut -d' ' -f1)

logger -t vpn-failover "tunnel down (endpoint=$current) -> switching to $next"
uci set "network.$SECTION.endpoint_host=$next"
uci commit network
ifup "$IFACE"
