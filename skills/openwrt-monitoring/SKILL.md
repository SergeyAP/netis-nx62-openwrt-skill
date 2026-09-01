---
name: openwrt-monitoring
description: >-
  Use this when someone wants to monitor an OpenWrt router from an existing
  Prometheus/VictoriaMetrics + Grafana stack, and/or reach that router remotely
  when it sits behind NAT with no public address. Covers choosing an exporter
  (prometheus-node-exporter-lua vs ucode vs collectd vs netdata, with measured
  footprints), wiring metrics out over a WireGuard spoke or a reverse SSH
  tunnel, running vmagent on a device with no package for it, and — the part
  that actually costs people days — getting community Grafana dashboards to
  render instead of showing blank panels. Trigger for: "monitor my OpenWrt
  router in Grafana", "node_exporter on OpenWrt", "reach my router from
  outside", "reverse ssh tunnel from a router", "the OpenWrt dashboard is
  empty", "grafana.com dashboard 11147 shows nothing". Not for setting up the
  Prometheus/Grafana server itself — this assumes one already exists.
---

# Monitoring an OpenWrt router, and reaching it from outside

## What this covers

Two related jobs that usually arrive together:

1. **Metrics** — get an OpenWrt router into an existing Grafana, next to your
   other hosts, with dashboards that actually draw.
2. **Access** — reach the router's shell and web interfaces from anywhere, when
   it has no public address and sits behind someone else's NAT.

Both assume you already run a metrics backend (VictoriaMetrics or Prometheus)
and Grafana somewhere reachable. This skill does not build that.

**Placeholders used throughout.** Substitute your own:

| Placeholder | Meaning |
|---|---|
| `<VPS>` | a host with a public address (jump host / WireGuard hub) |
| `<HUB_IP>` | that host's address inside your tunnel network, e.g. `10.10.0.1` |
| `<ROUTER_IP>` | the router's address inside that network, e.g. `10.10.0.8` |
| `<HOSTNAME>` | the label you want the router to carry in metrics |
| `<VM_URL>` | VictoriaMetrics write endpoint, e.g. `http://<HUB_IP>:8428` |

---

## Part 1 — Choosing an exporter

Measured on a Netcore N60 Pro (MT7986A, 512 MB RAM, 128 MB NAND) running
OpenWrt 25.12.5. Sizes are the real overlay growth, not package archive size.

| Agent | Overlay | RAM | Daemon | Writes to flash | Prometheus native |
|---|---|---|---|---|---|
| `prometheus-node-exporter-ucode` | +0.1 MB | few MB | no (uhttpd) | no | yes |
| `prometheus-node-exporter-lua` | +0.5 MB | few MB | no (uhttpd) | no | yes |
| `collectd` + write-prometheus | +0.5 MB | 10–20 MB | yes | no | yes |
| `zabbix-agentd` | +7.6 MB | — | yes | no | Zabbix only |
| `statsd-exporter` | +9.7 MB | — | yes | no | receives only |
| `fluent-bit` | +16.2 MB | — | yes | — | logs, not metrics |
| `netdata` | +25.8 MB | 60–150 MB | yes | **yes, own DB** | via endpoint |
| `telegraf` | +31.3 MB | — | yes | no | yes |

**Pick `prometheus-node-exporter-lua`** in almost every case. It runs through
uhttpd, so no process sits resident — it starts on scrape and exits. Nothing is
written to flash.

The ucode variant is four times smaller but ships 7 modules against lua's 22,
and lacks the three that matter most on a router: `thermal`, `nft-counters`,
and `textfile`.

**Do not pick netdata** if you already have Grafana. Its value is its own
dashboard and alerting, which you already have — and it keeps a time-series
database *on the router's NAND*.

### Modules worth installing

```sh
apk add prometheus-node-exporter-lua \
        prometheus-node-exporter-lua-openwrt \
        prometheus-node-exporter-lua-netstat \
        prometheus-node-exporter-lua-wifi \
        prometheus-node-exporter-lua-wifi_stations \
        prometheus-node-exporter-lua-nat_traffic \
        prometheus-node-exporter-lua-thermal \
        prometheus-node-exporter-lua-filesystem \
        prometheus-node-exporter-lua-nft-counters \
        prometheus-node-exporter-lua-textfile
```

Listen on loopback only:

```
uci set prometheus-node-exporter-lua.main.listen_interface='loopback'
uci set prometheus-node-exporter-lua.main.listen_port='9100'
uci commit && /etc/init.d/prometheus-node-exporter-lua enable
/etc/init.d/prometheus-node-exporter-lua restart
```

Verify — expect ~900 metric lines and every collector reporting success:

```sh
uclient-fetch -q -O - http://127.0.0.1:9100/metrics | grep -c '^[a-z]'
uclient-fetch -q -O - http://127.0.0.1:9100/metrics | grep '^node_scrape_collector_success'
```

### Two things that will surprise you

**Wi-Fi metrics are not `node_*`.** They are `wifi_network_*` and
`wifi_station_*`. If you grep only for `node_` you will conclude Wi-Fi is
missing.

**`nft-counters` reports success but emits nothing** unless your firewall has
*named* counters. `fw4` does not create any by default. The collector is
working; there is simply nothing to read.

---

## Part 2 — Getting metrics out

Two shapes, and which one you want depends on what your network already does.

### Push: vmagent on the router

Matches a fleet where every host runs an agent that remote-writes to a central
store. There is **no vmagent package for OpenWrt** — place the binary by hand:

```sh
# on a workstation: download vmutils for linux/arm64, verify the checksum
# published with the release, extract vmagent-prod, copy it over
cat vmagent-prod | ssh root@router 'cat > /usr/local/bin/vmagent-prod && chmod 0755 /usr/local/bin/vmagent-prod'
```

`/etc/vmagent/scrape.yml`:

```yaml
global:
  scrape_interval: 15s
  external_labels:
    host: <HOSTNAME>
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["127.0.0.1:9100"]
        labels:
          instance: <HOSTNAME>
```

Run it under procd — see [`scripts/vmagent.init`](scripts/vmagent.init).

**Put the remote_write queue in `/tmp`, not on flash.** It is rewritten
constantly; on NAND that is wear for no reason. The cost is losing the queue on
reboot, which for metrics is nothing.

### Pull: the server scrapes the router

Simpler if your backend can reach the router — no binary to place, nothing to
update. Have the exporter listen on the tunnel address instead of loopback and
point a scrape job at `<ROUTER_IP>:9100`.

---

## Part 3 — The transport

The router has no public address, so it must dial out.

### Option A — WireGuard spoke

Best if you already run a hub. OpenWrt's `wireguard` proto coexists fine with
`amneziawg` if the router already runs an obfuscated tunnel — both modules load
side by side and share the crypto libraries.

```sh
apk add kmod-wireguard wireguard-tools luci-proto-wireguard
wg genkey > /etc/wireguard/priv && chmod 600 /etc/wireguard/priv
wg pubkey < /etc/wireguard/priv          # give this to the hub
```

```sh
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.private_key="$(cat /etc/wireguard/priv)"
uci add_list network.wg0.addresses='<ROUTER_IP>/24'
uci set network.wg0.nohostroute='1'          # ← see below
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key='<HUB_PUBKEY>'
uci set network.@wireguard_wg0[-1].endpoint_host='<VPS>'
uci set network.@wireguard_wg0[-1].endpoint_port='51820'
uci add_list network.@wireguard_wg0[-1].allowed_ips='10.10.0.0/24'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci commit network
```

**`nohostroute='1'` is not optional if the router already routes everything
through a VPN.** Without it netifd pins a host route to the hub endpoint out
through the WAN, which quietly pulls your management traffic outside the VPN —
and can break access to that host entirely if your ISP treats it differently.
If you set the flag after the interface first came up, delete the stale route
by hand: `ip route del <VPS> via <GATEWAY> dev <WAN_IF>`.

**Restarting the network is not enough after installing a new proto package.**
netifd registers proto handlers at start; until it restarts, `ubus call
network.interface.wg0 status` reports `"proto": "none"` and the device never
appears. Restart it — and note **`nohup` does not exist in busybox**, so
detach with `setsid`:

```sh
setsid sh -c "sleep 3; /etc/init.d/network restart" >/dev/null 2>&1 < /dev/null &
```

### Option B — reverse SSH tunnel

No hub needed, just a host with a public address. Use dropbear's own client —
it is already installed, and procd handles restarts, so `autossh` (which needs
`openssh-client`, ~450 KB) buys nothing:

```sh
mkdir -p /root/.ssh && chmod 700 /root/.ssh
dropbearkey -t ed25519 -f /etc/dropbear/id_tunnel
dropbearkey -y -f /etc/dropbear/id_tunnel | grep ^ssh-ed25519   # → authorized_keys on <VPS>
ssh-keyscan -t ed25519 <VPS> > /root/.ssh/known_hosts
```

On `<VPS>`, restrict the key to forwarding only:

```
restrict,port-forwarding,command="/bin/false" ssh-ed25519 AAAA... router-tunnel
```

Install [`scripts/reverse-tunnel.init`](scripts/reverse-tunnel.init) as
`/etc/init.d/reverse-tunnel`, then `enable` and `start`.

**`HOME` is not set for procd services.** Without it dbclient cannot find
`~/.ssh/known_hosts`, rejects the host key with *"Host … is not in the trusted
hosts file"*, and dies in a restart loop. The init script sets
`procd_set_param env HOME=/root` — keep it.

Client side (`~/.ssh/config`):

```
Host router-tunnel
  HostName localhost
  Port 2221
  User root
  ProxyJump <VPS>
  HostKeyAlias router-tunnel
```

`HostKeyAlias` matters once you have more than one such tunnel: to SSH,
`localhost:2221` and `localhost:2222` are the same host with different keys,
and `known_hosts` will fight itself without it.

To reach a web interface through it:

```sh
ssh -N -L 9091:127.0.0.1:9091 router-tunnel
```

If you use `ControlMaster` (many people do, via `Host *`), a plain `-L` on an
already-multiplexed connection silently does nothing. Add the forward to the
live channel instead:

```sh
ssh -O forward -L 9091:127.0.0.1:9091 router-tunnel
ssh -O cancel  -L 9091:127.0.0.1:9091 router-tunnel
```

---

## Part 4 — Dashboards, and why yours is blank

This is where the time goes. Community OpenWrt boards
([11147](https://grafana.com/grafana/dashboards/11147-openwrt/),
[18153](https://grafana.com/grafana/dashboards/18153-asus-openwrt-router/))
need all five of these to line up. **Check them in this order** — each one
produces exactly the same symptom, an empty panel, so guessing is expensive.

### 1. Panel types your Grafana can still render

```sh
curl -s -u admin:PASS localhost:3000/api/dashboards/uid/<UID> \
  | python3 -c "import json,sys,collections; d=json.load(sys.stdin)['dashboard']; \
c=collections.Counter(); \
[c.update([o['type']]) for o in d['panels'] if 'type' in o]; \
print(d.get('schemaVersion'), dict(c))"
```

`graph` and `singlestat` are Angular. Grafana 11 ships with Angular **off** and
`singlestat` removed outright. A 2019-vintage board (schemaVersion 19) is
typically 80–90 % those two types, and **no amount of query fixing will make it
draw**. Either migrate the panels (`graph` → `timeseries`, `singlestat` →
`stat`) or use a board authored on schemaVersion 37+.

Check what your Grafana still has:

```sh
curl -s -u admin:PASS localhost:3000/api/frontend/settings \
  | python3 -c "import json,sys; d=json.load(sys.stdin); \
print('angular:', d.get('angularSupportEnabled')); \
print('singlestat present:', 'singlestat' in d.get('panels',{}))"
```

### 2. Datasource written as an object, not a string

```json
"datasource": { "type": "prometheus", "uid": "vm-system" }   ← correct
"datasource": "vm-system"                                     ← silently broken
```

In the old string form Grafana reads it as a datasource **name**. If you
substituted a *uid* there — which is what you get by replacing
`${DS_PROMETHEUS}` with your uid — Grafana looks for a source by that name,
finds none, and every query resolves to nothing with no error shown.

### 3. Variable regex left over from upstream

The one that cost me the most. Boards built for a pull setup often carry:

```json
"regex": "/([^:]+):.*/"
```

It strips the host out of an `instance` shaped `1.2.3.4:9100`. If your labels
are bare hostnames, **the pattern matches nothing and the whole list is
discarded** — the picker goes empty, and with it every panel. The query itself
tests perfectly clean, which is why this is so easy to miss.

Prove it before changing anything:

```sh
# raw values the variable query returns
curl -s -u admin:PASS -G --data-urlencode 'match[]=node_uname_info{job="node"}' \
  'localhost:3000/api/datasources/proxy/uid/<DS_UID>/api/v1/label/host/values'
# then apply the board's regex to that list by hand
```

### 4. Label shape: `instance:port` vs bare hostname

Upstream boards filter on `instance=~"$node:$port"`. If your agent sets
`instance` to a bare hostname — normal for push setups — that never matches.
Rewrite to whatever label you actually carry (`host=~"$node"`), and drop the
now-meaningless `$port` variable.

### 5. Variables with no default

`"current": {}` means nothing is selected on load. Panels then filter on an
empty string — and **in PromQL an empty regex matches series that lack the
label entirely**, so an unrelated job can appear to "work" while the correct
one shows nothing. Pin a default, and if only one value is ever valid, make the
variable a hidden `constant`.

### Verify like the browser does, not like curl does

Testing PromQL straight against VictoriaMetrics proves the data exists. It does
**not** prove a panel will draw, and every failure above passes that test. Go
through Grafana:

```sh
curl -s -u admin:PASS -X POST localhost:3000/api/ds/query \
  -H 'Content-Type: application/json' -d '{
    "queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"<DS_UID>"},
                "expr":"node_load1{host=\"<HOSTNAME>\"}","range":true,
                "intervalMs":60000,"maxDataPoints":200}],
    "from":"now-2h","to":"now"}'
```

[`scripts/check-dashboard.py`](scripts/check-dashboard.py) does this across a
whole board and prints, per panel, how many points came back.

---

## Part 5 — Router-specific metrics worth adding

The `textfile` collector turns any script into metrics. For a router whose
central job is a VPN tunnel, the tunnel itself is usually the one thing *not*
monitored:

```sh
#!/bin/sh
OUT=/var/lib/prometheus-node-exporter-lua/textfile/tunnel.prom
{
  now=$(date +%s)
  hs=$(wg show wg0 latest-handshakes | awk '{print $2}')
  echo "tunnel_handshake_age_seconds $((now - hs))"
  wg show wg0 transfer | awk '{print "tunnel_rx_bytes " $2 "\ntunnel_tx_bytes " $3}'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
```

Alert on `tunnel_handshake_age_seconds > 180` and you learn the VPN died before
the household does.

## Checklist

```
[ ] exporter installed, listening on loopback, ~900 metrics, all collectors ok
[ ] transport up (wg handshake fresh, or reverse tunnel port listening on <VPS>)
[ ] nohostroute set if the router already routes through a VPN
[ ] metrics visible in the backend under the expected host label
[ ] dashboard: panel types renderable by your Grafana version
[ ] dashboard: datasource in object form
[ ] dashboard: no leftover variable regex
[ ] dashboard: label filters match your label shape
[ ] dashboard: variables have defaults
[ ] verified through /api/ds/query, not just against the TSDB
```
