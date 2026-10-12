---
name: openwrt-selective-routing
description: >-
  Use this when an OpenWrt router should send only blocked or geo-restricted
  services through a VPN tunnel and leave everything else on the normal
  connection — with Podkop (sing-box). Covers what the tunnel must and must not
  do first, installing Podkop and sing-box by hand on OpenWrt 24.10/25.12,
  VPN mode over an existing WireGuard/AmneziaWG interface, community lists
  (blocked sites, Telegram, Meta, AI services) and your own domains, how the
  fake-IP DNS works and why phones with "Private DNS" silently bypass it, a
  test client that behaves like a phone on the LAN, and rollback. Trigger for:
  "only blocked sites through VPN", "Podkop on OpenWrt", "split tunneling on my
  router", "Russian sites direct, the rest through VPN", "YouTube and Telegram
  through the tunnel, banks direct", "sing-box on OpenWrt for routing". Not for
  sending *all* traffic through the tunnel with a kill switch — that is
  `openwrt-vpn-client`, which also brings up the tunnel this skill needs. Not
  for bypassing DPI without any tunnel — see that skill's
  references/diagnosing-isp-blocking.md.
---

# Only blocked services through the tunnel — Podkop on OpenWrt

## Why not "everything through the VPN"

Sending a whole household abroad breaks things that matter at home: banks and
government services that refuse foreign addresses, local marketplaces, and fast
domestic CDNs that become slow ones. On one network measured in October 2026, the
direct path gave 90 Mbit/s to Google's CDN and 93 Mbit/s to a domestic speed test,
while the tunnel peaked around 30–65 Mbit/s. Selective routing keeps the direct
path for everything that works on it and uses the tunnel only where it must.

[Podkop](https://github.com/itdoginfo/podkop) does this on OpenWrt with sing-box:
domains from curated lists resolve to fake addresses, and traffic to those
addresses is diverted into the tunnel. Everything else never touches it.

**Placeholders.**

| Placeholder | Meaning |
|---|---|
| `<VPN_IF>` | the tunnel's device name as `ip link` shows it, e.g. `awg0` |
| `<LAN_IP>` | the router's LAN address, e.g. `192.168.1.1` |
| `<TEST_IP>` | an unused address on the LAN, for the test client |
| `<VER>` | the Podkop release you install |

---

## 1. What the tunnel must look like first

Bring the tunnel up with `openwrt-vpn-client` §1 and prove it carries data (its §8),
then make sure it does **not** route anything by default:

- no default route of its own: `route_allowed_ips='0'` on a netifd interface, and
  **not** the two policy rules of that skill's §2;
- `ip route get 8.8.8.8` on the router answers `via <WAN_GW> dev <WAN_IF>`.

The firewall changes meaning, deliberately:

```sh
f=$(uci add firewall forwarding)
uci set firewall.$f.src=lan; uci set firewall.$f.dest=wan; uci set firewall.$f.name=lan-wan-direct
uci commit firewall && /etc/init.d/firewall reload
```

`lan → wan` forwarding is exactly what the all-traffic kill switch forbids; here the
direct path *is* the default. What remains of the kill switch: listed traffic goes only
through sing-box, whose outbound is bound to `<VPN_IF>`, so when the tunnel is down
the blocked services stop opening rather than leaking out of the WAN.

---

## 2. Install by hand

Podkop needs OpenWrt 24.10 or newer and about 25 MB of free flash; sing-box is the
bulk of it (~29 MiB installed, ~20 MB on a compressed overlay). Check first:

```sh
df -h /overlay
apk add --simulate sing-box curl jq kmod-nft-tproxy coreutils-base64 bind-dig
```

The project's one-line installer pipes a remote script into a root shell; the same
result by hand:

```sh
apk add sing-box curl jq kmod-nft-tproxy coreutils-base64 bind-dig
cd /tmp && U=https://github.com/itdoginfo/podkop/releases/download/<VER>
for f in podkop-<VER>-r1.apk luci-app-podkop-<VER>-r1.apk luci-i18n-podkop-ru-<VER>.apk; do
  curl -sLO "$U/$f"; done
sha256sum *.apk
# compare with: gh api repos/itdoginfo/podkop/releases/tags/<VER> --jq '.assets[] | "\(.digest) \(.name)"'
apk add --allow-untrusted ./podkop-*.apk ./luci-app-podkop-*.apk ./luci-i18n-podkop-ru-*.apk
```

Right after installation Podkop tries to start with its empty default config and
logs `Outbound section not found`. Harmless: nothing is changed until it is configured.

---

## 3. Configure VPN mode

```sh
uci set podkop.main.connection_type=vpn
uci set podkop.main.interface='<VPN_IF>'
uci set podkop.main.domain_resolver_enabled=0
uci -q del podkop.main.proxy_config_type; uci -q del podkop.main.proxy_string
uci add_list podkop.main.community_lists=telegram     # russia_inside is in the default
uci add_list podkop.main.community_lists=meta
uci add_list podkop.main.community_lists=google_ai
uci set podkop.main.user_domain_list_type=dynamic
for d in chatgpt.com openai.com oaistatic.com oaiusercontent.com claude.ai anthropic.com; do
  uci add_list podkop.main.user_domains=$d; done
uci commit podkop && /etc/init.d/podkop restart
```

| List | What it brings |
|---|---|
| `russia_inside` | domains blocked in Russia or refusing Russian users — YouTube, Instagram, X, Discord, rutracker, LinkedIn, Hetzner and many more |
| `telegram` | Telegram's domains **and its server subnets** — the apps connect by IP, so domains alone are not enough |
| `meta` | Meta's subnets, which WhatsApp uses |
| `google_ai` | Gemini and AI Studio |
| own domains | anything a list misses; here ChatGPT and Claude with the CDNs their pages need |

The interface may be a netifd interface or a device created by your own init script —
sing-box binds its outbound to the device name either way.

### How it works, so you can debug it

```
client DNS ─► dnsmasq ─► sing-box
                │  listed domain?  yes ─► fake address from 198.18.0.0/15
                │                  no  ─► the real address, untouched
client traffic to 198.18.x / listed subnets
   ─► nft (table PodkopTable) marks it ─► ip rule 105: fwmark → table podkop
   ─► tproxy into sing-box ─► outbound bound to <VPN_IF> ─► the tunnel
everything else ─► ordinary NAT ─► WAN
```

```sh
pidof sing-box && nft list tables | grep -i podkop && ip rule | grep 'lookup podkop'
logread | grep -i podkop | tail
```

The lists refresh daily from `raw.githubusercontent.com/itdoginfo/allow-domains`.

---

## 4. Prove it with a client, not with the router

Podkop acts on traffic arriving on `br-lan`; the router's own `curl` bypasses it, so
testing from the router proves nothing. [`scripts/test-client.sh`](scripts/test-client.sh)
attaches a network namespace to `br-lan` through a veth pair — a "phone" that uses the
router for DNS like any other — runs a matrix, and removes itself:

```sh
apk add kmod-veth                       # 'Unknown device type' without it
VPN_IF=<VPN_IF> LAN_IP=<LAN_IP> TEST_IP=<TEST_IP> sh test-client.sh
```

Read the tunnel's byte counter around each request to see which way it went. Expected:

| Through the tunnel | Direct |
|---|---|
| YouTube, Instagram, X, Discord, rutracker, LinkedIn, Telegram, WhatsApp, Gemini, ChatGPT, Claude | Gosuslugi, Yandex, banks, VK, marketplaces, Google's CDN, OS updates |

Then reboot and run it again: the tunnel, Podkop and the lists must all come back on
their own.

---

## 5. Things that look like failures and are not — or are

- **Phones with their own DNS bypass Podkop entirely.** Android "Private DNS" and a
  browser's "secure DNS" never ask dnsmasq, so a blocked site resolves to its real
  address, goes direct and fails. Switch both off on the household's devices. This is
  the most likely cause of "it works on the laptop but not on the phone".
- **Unlisted means direct.** A foreign site no list knows goes over the WAN, where the
  network may filter or freeze it. Add it to `user_domains`.
- **ChatGPT and Claude answer `curl` with 403 even through the tunnel** — Cloudflare's
  bot check, not a geo block. Judge them in a real browser.
- **Some Russian banks fail in the router's curl** with an ASN.1 error even with `-k`:
  its mbedTLS cannot parse their Russian-CA certificate chain. Browsers and the banks'
  apps are not affected, and the traffic did go direct as intended.
- **A tunnel restart is survived** — sing-box binds to the device per connection — but
  listed services are unreachable while it is down, by design.
- **Podkop is beta.** After an upgrade, re-read the config: options can change between
  versions, and the project asks you to clear the LuCI browser cache.

---

## 6. Roll back

```sh
/etc/init.d/podkop stop; /etc/init.d/podkop disable
apk del luci-i18n-podkop-ru luci-app-podkop podkop
# sing-box and the dependencies can stay or go: apk del sing-box bind-dig jq …
```

Podkop rewrites dnsmasq's upstream servers when it starts; after removing it, check
`uci show dhcp` for leftovers pointing at sing-box and restart dnsmasq. If the
household should go back to *all* traffic through the tunnel, remove the
`lan-wan-direct` forwarding and restore the routing of `openwrt-vpn-client` §2.

## Checklist

```
[ ] tunnel carries data, and routes nothing by default (ip route get 8.8.8.8 -> WAN)
[ ] lan -> wan forwarding added, VPN zone with masquerade still present
[ ] packages: sing-box + deps from the feed, Podkop apks checked against the release digests
[ ] podkop.main: connection_type vpn, interface <VPN_IF>, lists, own domains
[ ] sing-box running, PodkopTable present, ip rule 105 present
[ ] test client: listed names resolve to 198.18.x, unlisted to real addresses
[ ] test client: listed sites move the tunnel's byte counter, unlisted do not
[ ] after a reboot: all of the above again, without touching anything
[ ] household devices: Private DNS / secure DNS off
```
