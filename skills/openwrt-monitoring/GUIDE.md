# Quick checklist — monitoring an OpenWrt router

Full explanation in [`SKILL.md`](SKILL.md).

## Requirements

- An existing Prometheus or VictoriaMetrics + Grafana that the router can reach
  (directly, over WireGuard, or through a tunnel).
- Root SSH on the router.
- 1 MB free in `/overlay` for the exporter; ~20 MB more if you place vmagent.

## Exporter

```sh
apk add prometheus-node-exporter-lua prometheus-node-exporter-lua-openwrt \
        prometheus-node-exporter-lua-netstat prometheus-node-exporter-lua-wifi \
        prometheus-node-exporter-lua-wifi_stations prometheus-node-exporter-lua-nat_traffic \
        prometheus-node-exporter-lua-thermal prometheus-node-exporter-lua-filesystem \
        prometheus-node-exporter-lua-textfile

uci set prometheus-node-exporter-lua.main.listen_interface='loopback'
uci commit && /etc/init.d/prometheus-node-exporter-lua enable
/etc/init.d/prometheus-node-exporter-lua restart

uclient-fetch -q -O - http://127.0.0.1:9100/metrics | grep -c '^[a-z]'   # expect ~900
```

## Transport — pick one

**WireGuard spoke** — see SKILL.md part 3A. Two things that bite:
`nohostroute='1'` if the router already routes through a VPN, and a full
`/etc/init.d/network restart` (via `setsid`, busybox has no `nohup`) after
installing the proto package.

**Reverse SSH** — see SKILL.md part 3B; the init script and the watchdog live in
the companion skill
[`openwrt-remote-access`](../openwrt-remote-access/). The two that bite:
`procd_set_param env HOME=/root`, and a refused forward that leaves dbclient
alive with a dead tunnel.

## Dashboards

Import [11147](https://grafana.com/grafana/dashboards/11147-openwrt/) or
[18153](https://grafana.com/grafana/dashboards/18153-asus-openwrt-router/), then
work through the five checks in SKILL.md part 4 **in order** — they all look
identical from the outside (an empty panel):

1. panel types your Grafana still renders (`graph`/`singlestat` are gone in 11+)
2. datasource as an object, not a string
3. leftover variable `regex` from upstream
4. label shape — `instance:port` vs bare hostname
5. variables with no default

Verify with [`scripts/check-dashboard.py`](scripts/check-dashboard.py), which
goes through Grafana rather than straight to the TSDB. Testing the TSDB proves
the data exists; it does not prove a panel will draw, and all five failures
above pass that test.

## Checklist

```
[ ] ~900 metrics on 127.0.0.1:9100, every collector reporting success
[ ] transport up: fresh handshake, or the tunnel port listening on the VPS
[ ] metrics arriving under the expected host label
[ ] dashboard verified through /api/ds/query, not just the TSDB
[ ] agent + key + init scripts listed in /etc/sysupgrade.conf
```
