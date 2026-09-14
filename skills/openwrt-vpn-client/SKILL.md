---
name: openwrt-vpn-client
description: >-
  Use this when someone wants an OpenWrt router to send its whole network
  through a VPN — WireGuard or AmneziaWG — rather than just tunnelling one
  device. Covers the policy-routing model that makes it a kill switch instead of
  a leak, pinning the tunnel's own endpoints so it cannot route through itself,
  MTU, DNS, keeping your management path alive when the tunnel dies, and
  automatic failover between provider endpoints. Trigger for: "route all traffic
  through VPN on OpenWrt", "wireguard client on my router", "amneziawg on
  OpenWrt", "kill switch on a router", "my VPN drops and traffic leaks", "the
  router loses internet when the tunnel goes down", "vpn endpoint failover",
  "DPI blocks my wireguard". Not for running a VPN *server* on the router, and
  not for site-to-site links between two of your own networks.
---

# Routing an entire OpenWrt network through a VPN — without locking yourself out

## The shape of the problem

Tunnelling one laptop is easy. Making a router send *everyone's* traffic through
a tunnel raises three problems that only appear at the router level:

1. **The tunnel must not route through itself.** Its encrypted packets have to
   leave via WAN, or the first handshake kills the tunnel that carries it.
2. **A dead tunnel must not silently leak.** "VPN down" should mean no internet,
   not "everything continues in the clear".
3. **You must keep a way in.** If your own management path rides the tunnel, the
   tunnel's death is also your lockout.

Everything below exists to solve those three. The order matters: build the
routing first, prove the leak behaviour second, and only then automate failover.

**Placeholders.** Substitute your own:

| Placeholder | Meaning |
|---|---|
| `<IF>` | the VPN interface name, e.g. `vpn0` |
| `<TABLE>` | routing table number for VPN traffic, e.g. `51820` |
| `<MARK>` | firewall mark the tunnel's own packets carry, e.g. `0xca6c` |
| `<EP1> <EP2> <EP3>` | your provider's endpoint addresses |
| `<WAN_GW>` | the upstream gateway on your WAN, e.g. `192.168.1.1` |
| `<WAN_IF>` | the WAN interface, e.g. `eth1` |
| `<INSIDE_HOST>` | a host reachable **only** through the tunnel (see §5) |

---

## 1. WireGuard or AmneziaWG

| | WireGuard | AmneziaWG |
|---|---|---|
| Packages | `kmod-wireguard wireguard-tools luci-proto-wireguard` | `kmod-amneziawg amneziawg-tools luci-proto-amneziawg` |
| Handshake visible to DPI | yes — a fixed, fingerprintable pattern | obfuscated by junk/header parameters |
| Config surface | keys, endpoint, allowed_ips | the same **plus** `awg_jc`, `awg_jmin`, `awg_jmax`, `awg_s1`, `awg_s2`, `awg_h1..h4` |
| Use it when | nothing is blocking you | WireGuard connects and then dies, or never handshakes, on a network that filters it |

Both can be installed at once and coexist: the modules load side by side and
share the crypto libraries. That combination is normal — an obfuscated tunnel for
the household's traffic, plain WireGuard for your own management spoke.

**The obfuscation parameters must match the server exactly.** A single wrong
value does not produce an error: the handshake simply never completes. When
debugging AmneziaWG, verify the parameter set before suspecting keys or routing.

---

## 2. The routing model: policy routing, not a default route

Do **not** let the tunnel install a default route into the main table. Use three
objects instead — one route in a private table and two rules:

```sh
uci set network.<IF>=interface
uci set network.<IF>.proto='amneziawg'            # or 'wireguard'
uci set network.<IF>.private_key="$(cat /etc/<IF>/priv)"
uci add_list network.<IF>.addresses='<ADDR>/32'
uci set network.<IF>.mtu='1412'
uci set network.<IF>.dns='<DNS_INSIDE_TUNNEL>'

uci add network amneziawg_<IF>                    # or wireguard_<IF>
uci set network.@amneziawg_<IF>[-1].public_key='<SERVER_PUBKEY>'
uci set network.@amneziawg_<IF>[-1].endpoint_host='<EP1>'
uci set network.@amneziawg_<IF>[-1].endpoint_port='51820'
uci add_list network.@amneziawg_<IF>[-1].allowed_ips='0.0.0.0/0'
uci add_list network.@amneziawg_<IF>[-1].allowed_ips='::/0'
uci set network.@amneziawg_<IF>[-1].route_allowed_ips='0'   # ← do not auto-route
uci set network.@amneziawg_<IF>[-1].persistent_keepalive='25'
```

```sh
# the VPN default route lives in its own table
uci add network route
uci set network.@route[-1].interface='<IF>'
uci set network.@route[-1].target='0.0.0.0/0'
uci set network.@route[-1].table='<TABLE>'

# rule 1: specific prefixes (LAN, mesh, on-link) still resolve through main
uci add network rule
uci set network.@rule[-1].priority='32764'
uci set network.@rule[-1].lookup='main'
uci set network.@rule[-1].suppress_prefixlength='0'

# rule 2: everything NOT carrying the tunnel's own mark goes to the VPN table
uci add network rule
uci set network.@rule[-1].priority='32765'
uci set network.@rule[-1].mark='<MARK>'
uci set network.@rule[-1].invert='1'
uci set network.@rule[-1].lookup='<TABLE>'
uci commit network
```

Read the result top-down:

```
prio 32764   lookup main, suppress_prefixlength 0   → connected/specific routes win,
                                                      the main DEFAULT is skipped
prio 32765   not mark <MARK> → lookup <TABLE>       → ordinary traffic into the VPN
prio 32766   lookup main                            → the tunnel's own packets (marked)
                                                      leave via WAN
```

`suppress_prefixlength 0` is the piece people omit. It means "use `main`, but
ignore its default route": LAN, the mesh, and any on-link network keep working
normally, while ordinary internet traffic falls through to the VPN table. Without
it you either bypass the tunnel or break local routing.

### Pin the endpoints to the WAN gateway

The tunnel's own packets are marked and therefore use `main` — but `main` no
longer has a usable default for them in every failure mode. Pin each endpoint you
might use:

```sh
for ep in <EP1> <EP2> <EP3>; do
  uci add network route
  uci set network.@route[-1].interface='wan'
  uci set network.@route[-1].target="$ep"
  uci set network.@route[-1].gateway='<WAN_GW>'
done
uci commit network && /etc/init.d/network restart
```

Skipping this is the classic "the tunnel comes up, then instantly dies" bug: the
handshake packet is routed into the tunnel it is trying to establish.

### MTU

Start at `1412` for WireGuard over a 1500-byte path and lower it if large packets
stall while small ones pass — the symptom is "SSH works, web pages hang".
The WAN zone should keep `mtu_fix` enabled.

---

## 3. Firewall zones

| Zone | Networks | input | output | forward | masq |
|---|---|---|---|---|---|
| `lan` | lan | ACCEPT | ACCEPT | ACCEPT | — |
| `wan` | wan, wan6 | REJECT | ACCEPT | DROP | yes (+`mtu_fix`) |
| `<IF>` | `<IF>` | REJECT | ACCEPT | REJECT | **yes** |

Masquerading on the VPN zone is what makes LAN clients usable through a tunnel
that owns a single address. `forward REJECT` on the VPN zone means nothing from
the tunnel side can reach into the LAN.

Forwarding is then `lan → <IF>`, and **not** `lan → wan`. That single omission is
most of the kill switch: with no lan→wan forwarding, a dead tunnel cannot leak
into the clear — it drops.

---

## 4. Prove the kill switch before you trust it

Testing from the router itself proves nothing: the router's own traffic follows
different rules than a forwarded client's. Test the forwarded path:

```sh
# from the router — what a LAN client's packet would do
ip route get 1.1.1.1 from <LAN_CLIENT_IP> iif br-lan

# with the tunnel down, the same command must fail or resolve into the dead
# tunnel — never into <WAN_IF>
ifdown <IF> && ip route get 1.1.1.1 from <LAN_CLIENT_IP> iif br-lan ; ifup <IF>
```

Also check what the router itself does, because updates and package installs go
that way: `ip route get 1.1.1.1` should resolve `dev <IF>`.

---

## 5. Failover between endpoints

One endpoint will eventually stop answering — after a provider maintenance, or
after your own reboot. [`scripts/vpn-failover.sh`](scripts/vpn-failover.sh),
run from cron every minute, rotates to the next endpoint in the list.

Three details in it are not decoration:

- **Probe a host that exists only inside the tunnel.** Pinging a public resolver
  tells you nothing: it answers whether or not the traffic went through the VPN.
  Use `<INSIDE_HOST>` — the provider's internal DNS is usually the easiest one.
- **Do nothing during the first 90 seconds of uptime.** Otherwise the script
  races netifd while the interface is still coming up on boot and starts
  rotating endpoints for no reason.
- **Take a lock.** A minute-cron plus an `ifup` that takes longer than a minute
  is how two instances end up fighting over the same uci section.

```
* * * * * /usr/bin/vpn-failover.sh
```

Failover changes `endpoint_host` and runs `ifup <IF>`; it never touches keys or
the obfuscation parameters, which belong to the provider's server configuration.

---

## 6. DNS

A tunnel that carries traffic but not DNS is a leak with good intentions. Set
`option dns` on the VPN interface to a resolver reachable inside the tunnel, and
make sure dnsmasq does not keep using WAN-provided servers:

```sh
uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].server='<DNS_INSIDE_TUNNEL>'
uci commit dhcp && /etc/init.d/dnsmasq restart
```

Verify from a LAN client, not from the router: `nslookup whoami.akamai.net`
should report the tunnel's exit, and a DNS-leak test page should show only the
provider's resolvers.

---

## 7. Keep your own way in

This is the part that turns a good setup into an unreachable one. Decide
explicitly:

- **Management over the tunnel** — simple, and the tunnel's death costs you
  access. Acceptable when someone can power-cycle the box.
- **Management beside the tunnel** — a second, plain WireGuard spoke to a hub of
  your own, or a reverse SSH tunnel. Then a VPN outage is visible but not
  blinding.

If you run a second WireGuard interface for management **on a router that already
routes everything through the VPN**, set `nohostroute='1'` on it. Without that,
netifd pins a host route to the management hub through WAN, which quietly pulls
your management traffic outside the tunnel; some providers then refuse the
address entirely and SSH starts returning `Connection refused`, which looks
exactly like a ban and is not one. Changing the flag later does not delete the
route that already exists — remove it by hand:

```sh
ip route del <HUB_ENDPOINT> via <WAN_GW> dev <WAN_IF>
```

The companion skill `openwrt-remote-access` covers both management paths in
full; `openwrt-monitoring` covers alerting on the tunnel's handshake age, which
is how you learn the VPN died before the household does.

---

## Verification checklist

```
[ ] handshake fresh:            wg show <IF> latest-handshakes   (< 180 s old)
[ ] endpoints pinned:           ip route | grep <EP1>            (via <WAN_GW>)
[ ] rules in place:             ip rule show                     (32764 + 32765)
[ ] VPN table has the default:  ip route show table <TABLE>
[ ] router egress:              ip route get 1.1.1.1             (dev <IF>)
[ ] client egress:              ip route get 1.1.1.1 from <LAN_CLIENT_IP> iif br-lan
[ ] kill switch:                same command with the tunnel down never says <WAN_IF>
[ ] DNS:                        leak test from a client shows only tunnel resolvers
[ ] failover:                   cron line present, lock and uptime guards in place
[ ] management path:            reachable with <IF> down (or accepted as lost)
```

## Failure modes

| Symptom | Cause |
|---|---|
| Tunnel comes up, dies within seconds | endpoint not pinned to the WAN gateway — handshake routed into itself |
| Handshake never completes, no error | AmneziaWG parameters do not match the server, or wrong key |
| Small packets fine, web pages hang | MTU too high; lower `<IF>` MTU, keep `mtu_fix` on WAN |
| Traffic leaks to WAN when the tunnel dies | `lan → wan` forwarding still exists, or `route_allowed_ips='1'` put a default in `main` |
| LAN cannot reach the internet at all | masquerade missing on the VPN zone, or `lan → <IF>` forwarding not added |
| SSH to your own hub starts refusing | missing `nohostroute` on the management interface (see §7) |
| Failover flaps after every reboot | the uptime guard was removed |
