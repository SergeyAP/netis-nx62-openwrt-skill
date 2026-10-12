#!/bin/sh
# test-client.sh — behave like a phone on the LAN and show which way each site goes.
#
# Podkop only handles traffic that arrives on br-lan, so a request from the router
# itself proves nothing. This attaches a network namespace to br-lan through a veth
# pair, gives it an unused LAN address, uses the router for DNS like any client, and
# reads the tunnel's byte counter around every request. It removes everything it
# created when it finishes, or when interrupted.
#
# Needs kmod-veth ("Unknown device type" without it) and curl.
#
#   VPN_IF=awg0 LAN_IP=192.168.1.1 TEST_IP=192.168.1.250 sh test-client.sh [site ...]

VPN_IF=${VPN_IF:-awg0}
LAN_IP=${LAN_IP:-192.168.1.1}
TEST_IP=${TEST_IP:-192.168.1.250}
PREFIX=${PREFIX:-24}
NS=podtest
SITES=${*:-www.youtube.com www.instagram.com x.com web.telegram.org web.whatsapp.com \
	gemini.google.com ya.ru gosuslugi.ru}

cleanup() {
	ip link del vcl-br 2>/dev/null
	ip netns del "$NS" 2>/dev/null
	rm -f "/etc/netns/$NS/resolv.conf"; rmdir "/etc/netns/$NS" 2>/dev/null
}
trap cleanup EXIT INT TERM

[ -d "/sys/class/net/$VPN_IF" ] || { echo "no interface $VPN_IF"; exit 1; }
cleanup
set -e
ip netns add "$NS"
ip link add vcl type veth peer name vcl-br
ip link set vcl-br master br-lan up
ip link set vcl netns "$NS"
ip -n "$NS" link set lo up
ip -n "$NS" addr add "$TEST_IP/$PREFIX" dev vcl
ip -n "$NS" link set vcl up
ip -n "$NS" route add default via "$LAN_IP"
mkdir -p "/etc/netns/$NS"
echo "nameserver $LAN_IP" > "/etc/netns/$NS/resolv.conf"
set +e
sleep 2

rx() { cat "/sys/class/net/$VPN_IF/statistics/rx_bytes"; }
printf "%-22s %-16s %-28s %s\n" site resolves-to result "via $VPN_IF"
for s in $SITES; do
	ip=$(ip netns exec "$NS" nslookup "$s" "$LAN_IP" 2>/dev/null | sed -n '/^Name/,$p' | awk '/^Address/{print $2; exit}')
	a=$(rx)
	r=$(ip netns exec "$NS" curl -s -m 10 -o /dev/null -w '%{http_code} %{size_download}B %{time_total}s' "https://$s/")
	b=$(rx)
	printf "%-22s %-16s %-28s %s KB\n" "$s" "${ip:-?}" "$r" $(( (b - a) / 1024 ))
done
echo "198.18.x = a fake address: the name is on a list and the traffic goes through $VPN_IF"
