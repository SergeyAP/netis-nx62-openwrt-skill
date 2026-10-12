# Diagnosing what the network blocks — and how far zapret gets

A companion to the VPN skill. Before choosing a tool, find out **which kind** of
blocking you are facing: they look identical in a browser ("the site does not
open"), they are told apart in seconds with the router's own conntrack table, and
each one has a different remedy.

Measured on a Russian residential ISP in October 2026, from an OpenWrt 25.12 router,
with zapret2 v1.0.5.2. The categories are general; which sites fall into which
category changes from network to network and month to month.

---

## The four kinds

| Kind | What the router sees | Typical targets |
|---|---|---|
| **SNI filter** | TCP connects; the TLS ClientHello is never answered. One reply packet (the SYN-ACK) and 11–12 retransmits in conntrack. The *same IP* with no SNI answers normally | big foreign platforms by name |
| **Volume freeze** | Once the SNI filter is bypassed, the transfer starts and stops for good after 8–16 KB | sites on foreign hosting and CDNs |
| **IP block** | the SYN is never answered: `SYN_SENT [UNREPLIED]` | messengers' server ranges, some VPN providers |
| **Tunnel recognition** | a VPN handshake completes, then the flow is dropped in both directions | WireGuard, OpenVPN, AmneziaWG profiles not made for this network |

Not the network: a `403` or a redirect from the service itself is the service
refusing the country, and nothing on the router changes it. DNS can be tampered with
as well — a public resolver answering `NXDOMAIN` for a name that plainly exists.

### Reading conntrack

Make one request, then look at its entry:

```sh
curl -s -m 8 -o /dev/null https://<NAME>/
grep "dst=<IP> " /proc/net/nf_conntrack | grep "dport=443 "
```

- `ESTABLISHED … packets=12 … src=<IP> … packets=1` — connected, ClientHello ignored:
  **SNI filter**.
- `SYN_SENT … [UNREPLIED]` — **IP block**.
- Many packets both ways, then the transfer stalls at a few KB — **volume freeze**.

> **Trap: some curl builds report `time_connect=0` for a connection that did
> connect.** With curl and libcurl from different releases (seen on OpenWrt 25.12),
> the connect time is zero whenever the TLS stage then stalls, which reads as "TCP
> never connected". Judge by conntrack and bytes received, not by curl's timings.

### Proving tunnel recognition from the far side

If you run the server, do not stop at "no reply": capture on the server while the
router pings through the tunnel.

```sh
# on the server
tcpdump -nni any "host <ROUTER_PUBLIC_IP> and port <PORT>"
```

The tell is a handshake in both directions, then **no packets from the router at all**
while it is busy sending, and the server's own segments retransmitted with growing gaps
(1, 2, 4, 9, 18 s). A short SSH transfer to the same server keeping a steady rate proves
the address itself is not blocked — what is recognised is the protocol.

---

## zapret against each kind

zapret (`nfqws`/`nfqws2`) rewrites the *first packets* of a connection — splitting,
reordering or prefixing the ClientHello with fakes — so a DPI box misreads it. Only the
first ~12 packets of a flow need to pass through it, which is why it costs almost
nothing.

| Kind | zapret | Measured |
|---|---|---|
| SNI filter | **works** | `multidisorder:pos=1,midsld` or `hostfakesplit:tcp_md5` opened YouTube (957 KB page) and Instagram; throughput unchanged at 55 Mbit/s; `nfqws2` 1.3 MB RSS, CPU ≈ 0 |
| Volume freeze | **no** | the freeze counts bytes per connection after the handshake; every strategy still stopped at 8–16 KB |
| IP block | **no** | nothing to rewrite if the SYN never gets an answer |
| Tunnel recognition | **no** | four strategies on OpenVPN, three on WireGuard (including fakes before the handshake initiation), two on AmneziaWG — no data in any case. The drop happens after the first packets, which is the only part zapret touches |

Two-sided obfuscation in zapret2 (`wgobfs`, `udp2icmp`, `ippxor` — they need `nfqws2`
on the server as well) was not measured here.

### Messengers

On the bare WAN, with and without zapret:

| | without | with zapret | why |
|---|---|---|---|
| Instagram | nothing | API and media CDN answer; the main page loaded 1 time in 3 | SNI filter |
| Telegram | nothing | nothing | IP block on the server ranges and the website |
| WhatsApp | nothing | nothing | IP block on the addresses it uses |

zapret cannot help either messenger; they need a tunnel.

### A harness that leaves nothing behind

Running `nfqws2` by hand, without installing zapret as a service, is enough to test a
strategy. Queue only the first packets of each flow, mark what `nfqws2` sends so it is
not queued again, and keep it out of conntrack:

```sh
nft add table inet zr
nft 'add chain inet zr post { type filter hook postrouting priority 102; }'
nft 'add rule inet zr post meta nfproto ipv4 tcp dport {80,443} ct original packets 1-12 meta mark and 0x10000000 == 0 queue num 200 bypass'
nft 'add chain inet zr predefrag { type filter hook output priority -402; }'
nft 'add rule inet zr predefrag meta mark and 0x10000000 != 0 notrack'
<ZAPRET>/nfq2/nfqws2 --uid 1:3003 --fwmark=0x10000000 --qnum=200 \
  --lua-init=@<ZAPRET>/lua/zapret-lib.lua --lua-init=@<ZAPRET>/lua/zapret-antidpi.lua \
  --payload=tls_client_hello --lua-desync=multidisorder:pos=1,midsld &
# undo: killall nfqws2; nft delete table inet zr
```

`blockcheck2.sh` finds strategies automatically, but budget for it: a standard scan
took 3.5 hours for **one** domain on a router.

---

## What this means for the router

- Sites behind an SNI filter only: zapret alone may be enough, at no cost.
- Anything frozen by volume or blocked by IP: it needs a tunnel.
- The tunnel itself recognised and dropped: get a profile made for this network
  (SKILL.md §8). Once one works, zapret adds nothing inside it — there is nothing for
  the DPI box to read.
- Usually the household needs both kinds of destination, which is the case for
  `openwrt-selective-routing`: blocked services through the tunnel, the rest direct.
