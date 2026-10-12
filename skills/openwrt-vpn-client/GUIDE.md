# Quick Guide — routing an OpenWrt router through a VPN

Condensed checklist. Read `SKILL.md` for the reasoning behind each item.

## What you need

- An OpenWrt router you can still reach if the tunnel breaks (LAN cable counts).
- A VPN account whose provider gives you: server public key, endpoint addresses,
  your address inside the tunnel, and — for AmneziaWG — the obfuscation
  parameter set.
- Packages: `kmod-wireguard wireguard-tools luci-proto-wireguard`, or
  `kmod-amneziawg amneziawg-tools luci-proto-amneziawg`.
- A host reachable only inside the tunnel, for the failover probe.

## Order of operations

1. Install the packages, generate the key, hand the public key to the provider.
2. Create the interface with `route_allowed_ips='0'` — the tunnel must not
   install a default route of its own.
3. Add the VPN default route in its own table, plus the two rules
   (`suppress_prefixlength 0` at 32764, inverted mark at 32765).
4. Pin every provider endpoint to the WAN gateway as a static host route.
5. Firewall: VPN zone with masquerade, forwarding `lan → vpn`, and **no**
   `lan → wan` forwarding — that omission is the kill switch.
6. Point DNS at a resolver inside the tunnel; disable the WAN-provided ones.
7. Verify the forwarded path, not just the router's own: `ip route get 1.1.1.1
   from <LAN_CLIENT_IP> iif br-lan`.
8. Bring the tunnel down and repeat the check — it must never resolve to WAN.
9. Install `scripts/vpn-failover.sh` and its cron line.
10. Decide, explicitly, whether your management path rides this tunnel.

## The four things people get wrong

- **Endpoint not pinned to WAN** → the tunnel routes its own handshake into
  itself and dies seconds after coming up.
- **`route_allowed_ips='1'`** → a default route lands in `main` and the careful
  rule ordering stops meaning anything.
- **Testing the kill switch from the router** → the router's own traffic follows
  different rules than a forwarded client's. Test with `from ... iif ...`.
- **Management over the same tunnel, unnoticed** → the day the VPN dies you
  discover you had one path, not two.
