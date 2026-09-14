---
name: openwrt-remote-access
description: >-
  Use this when an OpenWrt router has no public address — behind someone else's
  NAT, CGNAT, or a provider that refuses inbound — and must still be reachable
  for shell and web interfaces. Covers the two transports worth having (a
  WireGuard spoke to a hub you control, and a reverse SSH tunnel to any host
  with a public address), dbclient versus autossh with the real trade-off,
  restricting the key on the far side, the silent "process alive, forward dead"
  failure that survives procd supervision, and a watchdog for it. Trigger for:
  "reach my router from outside", "reverse ssh tunnel from a router", "autossh
  on OpenWrt", "router behind CGNAT", "ssh into my home router", "the tunnel is
  up but the port is dead", "port forwarding to a router web UI". Not for
  exposing services to the public internet — everything here stays on loopback
  and is reached through SSH.
---

# Reaching a router that has no public address

## Build two paths, not one

The single most useful decision here is not which transport to pick — it is to
run **two that fail differently**:

| | WireGuard spoke | Reverse SSH tunnel |
|---|---|---|
| Needs | a hub you control | any host with a public address |
| Terminates on | your hub | that host |
| Dies when | the hub, or the WireGuard path, is down | that host, or the SSH path, is down |
| Cost on the router | one interface, a few KB | one process, zero extra packages |
| Also gives you | a routed network (metrics, LAN access) | a port, and whatever you forward over it |

They terminate on different machines, so one being down does not take the other
with it. On a router that also runs a commercial VPN, decide deliberately
whether these paths go through the tunnel or beside it — see §6.

**Placeholders.** Substitute your own:

| Placeholder | Meaning |
|---|---|
| `<VPS>` | a host with a public address |
| `<RPORT>` | the port on `<VPS>` that will forward to the router's SSH |
| `<HUB_IP>` / `<ROUTER_IP>` | addresses inside your WireGuard network |

---

## 1. Path A — WireGuard spoke

```sh
apk add kmod-wireguard wireguard-tools luci-proto-wireguard
wg genkey > /etc/wireguard/priv && chmod 600 /etc/wireguard/priv
wg pubkey < /etc/wireguard/priv           # hand this to the hub
```

```sh
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$(cat /etc/wireguard/priv)"
uci add_list network.wg0.addresses='<ROUTER_IP>/24'
uci set network.wg0.nohostroute='1'
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key='<HUB_PUBKEY>'
uci set network.@wireguard_wg0[-1].endpoint_host='<VPS>'
uci set network.@wireguard_wg0[-1].endpoint_port='51820'
uci add_list network.@wireguard_wg0[-1].allowed_ips='<WG_NET>/24'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci commit network
```

Then a firewall zone for it, or SSH will not answer on that interface:

```sh
uci set firewall.mesh=zone
uci set firewall.mesh.name='mesh'
uci set firewall.mesh.network='wg0'
uci set firewall.mesh.input='ACCEPT'
uci set firewall.mesh.output='ACCEPT'
uci set firewall.mesh.forward='REJECT'
uci commit firewall && /etc/init.d/firewall restart
```

Three things that cost other people an evening:

- **`nohostroute='1'` matters** if the router already routes everything through a
  VPN. Without it netifd pins a host route to the hub endpoint via WAN, taking
  your management traffic outside the tunnel. Setting the flag afterwards does
  not remove the route that already exists — `ip route del <VPS> via <WAN_GW>
  dev <WAN_IF>`.
- **A named zone is invisible to `uci show firewall | grep '@zone'`.** Confirm
  the live state instead: `nft list chain inet fw4 input` should show
  `iifname "wg0" jump input_mesh`.
- **Restart netifd after installing a new proto package.** Until it restarts,
  `ubus call network.interface.wg0 status` reports `"proto": "none"` and the
  device never appears. `nohup` does not exist in busybox — detach with
  `setsid sh -c "sleep 3; /etc/init.d/network restart" >/dev/null 2>&1 &`.

---

## 2. Path B — reverse SSH tunnel

### dbclient or autossh?

Both work. The difference is one that only shows up months later:

| | `dbclient` (dropbear, already installed) | `autossh` + `openssh-client` |
|---|---|---|
| Size | 0 — it is already there | ~450 KB of overlay |
| Restart supervision | procd | autossh (`-M 0` leans on `ServerAliveInterval` anyway) |
| `ExitOnForwardFailure` | **not implemented** | yes |
| Consequence | a refused forward leaves a live process with a dead tunnel — needs the watchdog in §4 | the client exits on a refused forward and is restarted cleanly |

**Pick `dbclient` plus the watchdog** on a small-flash router, which is the usual
case: the watchdog is 40 lines and costs nothing. **Pick `autossh`** if you
already have `openssh-client` on the box for another reason, or if you would
rather spend 450 KB than run a watchdog. What you must not do is run `dbclient`
*without* the watchdog and assume procd has you covered — see §4.

### Keys, in the direction that keeps the far side safe

```sh
mkdir -p /root/.ssh && chmod 700 /root/.ssh
dropbearkey -t ed25519 -f /etc/dropbear/id_tunnel
dropbearkey -y -f /etc/dropbear/id_tunnel | grep ^ssh-ed25519    # → <VPS>
ssh-keyscan -t ed25519 <VPS> > /root/.ssh/known_hosts
```

On `<VPS>`, the router's key gets no shell at all:

```
restrict,port-forwarding,command="/bin/false" ssh-ed25519 AAAA... router-tunnel
```

`restrict` disables agent/X11/pty and everything else added in future versions;
`port-forwarding` adds back only what the tunnel needs. If the router is ever
compromised, that key is a port, not a login.

### The service

Install [`scripts/reverse-tunnel.init`](scripts/reverse-tunnel.init) as
`/etc/init.d/reverse-tunnel`, then `enable` and `start`.

**`HOME` is not set for procd services.** Without it dbclient cannot find
`~/.ssh/known_hosts`, rejects the host key with *"Host … is not in the trusted
hosts file"*, and dies in a restart loop. The init script sets
`procd_set_param env HOME=/root` — keep it.

The forward binds to `<VPS>`'s loopback (the sshd default, `GatewayPorts no`),
so the port is not exposed to the internet; you reach it by hopping through
`<VPS>` yourself.

### The client side

```
Host router-tunnel
  HostName localhost
  Port <RPORT>
  User root
  ProxyJump <VPS>
  HostKeyAlias router-tunnel
```

`HostKeyAlias` stops mattering only if you have exactly one such tunnel forever.
With two, `localhost:2221` and `localhost:2222` are the same host with different
keys to SSH, and `known_hosts` fights itself.

Reaching a web interface over it:

```sh
ssh -N -L 9091:127.0.0.1:9091 router-tunnel
```

If you use `ControlMaster` (many people do, via `Host *`), a plain `-L` on an
already-multiplexed connection silently does nothing. Add the forward to the live
channel instead:

```sh
ssh -O forward -L 9091:127.0.0.1:9091 router-tunnel
ssh -O cancel  -L 9091:127.0.0.1:9091 router-tunnel
```

---

## 3. Tune the far side's sshd, or the tunnel comes back to a busy port

When the router's connection dies without a FIN — a power cut, a dead uplink —
`<VPS>` keeps the socket and the forwarded port for as long as its keepalive
policy allows. The router reconnects, asks for the same `<RPORT>`, is refused
because the old listener still holds it, and you have a live SSH session with no
tunnel in it.

```
# /etc/ssh/sshd_config on <VPS>
ClientAliveInterval 30
ClientAliveCountMax 3
```

Ninety seconds to reap a dead peer, rather than the ten minutes the defaults give
you. Reload sshd after changing it. This is not a substitute for the watchdog —
it shortens the window, the watchdog closes it.

---

## 4. The failure that survives supervision

`dbclient` has no `ExitOnForwardFailure`. When the remote forward is refused it
logs the refusal and **keeps running** as an ordinary SSH session. procd sees a
healthy process and has nothing to respawn. The result is a tunnel that is up by
every naive measure and dead in fact — in one documented case, for three days.

[`scripts/tunnel-watchdog.sh`](scripts/tunnel-watchdog.sh), from cron every five
minutes, closes it:

```
*/5 * * * * /usr/bin/tunnel-watchdog.sh
```

Two design decisions in it are worth keeping:

- **The check is local.** It reads `logread` for dbclient's own refusal line
  rather than asking `<VPS>` whether the port is listening. The router's key over
  there is restricted to port forwarding and cannot run `ss` — and weakening that
  restriction to please a watchdog would be the wrong trade.
- **It touches a stamp file on every run.** A watchdog that is silent when
  healthy is indistinguishable from a watchdog that is not running at all.
  `ls -l /tmp/tunnel-watchdog.stamp` answers "is it alive?" in one command.

---

## 5. Verify, from outside

```sh
ssh router-tunnel 'uptime'                        # path B works end to end
ssh <VPS> 'ss -ltnp | grep <RPORT>'               # the forward is actually bound
ssh root@<ROUTER_IP> 'wg show wg0 latest-handshakes'   # path A is fresh
ssh router-tunnel 'ls -l /tmp/tunnel-watchdog.stamp'
```

A handshake older than three minutes, or a stamp older than ten, means the thing
you are looking at is stale — not that you typed the command wrong.

---

## 6. Where these paths sit relative to a VPN

If the router sends everything through a commercial VPN, both management paths
leave through that tunnel by default. That can be deliberate — "if the VPN is
down, remote access is down too" is a defensible policy, and it keeps the
router's traffic uniform. Just make it a decision rather than a surprise, and
know that it makes the VPN a single point of failure for access as well.

The alternative is to mark the management traffic so it uses WAN directly. It
costs a rule and gives up the uniformity; on a router at someone else's house,
where a power-cycle needs a phone call, it is often worth it.

## Checklist

```
[ ] path A: wg handshake fresh, firewall zone accepts input on the wg interface
[ ] path A: nohostroute set if the router routes through a VPN
[ ] path B: key on <VPS> carries restrict,port-forwarding,command="/bin/false"
[ ] path B: /root/.ssh/known_hosts present, HOME=/root in the init script
[ ] path B: forward bound to loopback on <VPS>, reached via ProxyJump
[ ] client config uses HostKeyAlias
[ ] sshd on <VPS>: ClientAliveInterval 30 / CountMax 3
[ ] watchdog installed, cron line present, stamp file fresh
[ ] both paths tested from outside the house, on the same day
```
