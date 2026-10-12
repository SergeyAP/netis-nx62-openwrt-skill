# openwrt-router-skills

Field-tested [Claude](https://claude.com/claude-code) **skills** — and equally
usable plain guides — for the **Netis NX62** / **Netcore N60 Pro** (MediaTek
**MT7986A / Filogic**, OpenWrt id `netcore_n60-pro`) and, beyond the flashing
one, for OpenWrt routers generally.

Everything here was written after doing it on real hardware, so the parts that
usually cost an evening — a bootloader that only talks on certain ports, a
tunnel that looks alive while being dead, a dashboard that draws nothing — are
the parts these documents spend their words on.

## One base skill, five optional add-ons

The flashing skill is the base: it turns a stock router into a blank OpenWrt.
The other five are **independent add-ons** — pick what you need, in any
combination. None of them requires the flashing skill, and each works on any
OpenWrt router, not only this board. The one dependency between add-ons:
selective routing needs the tunnel that the VPN skill brings up.

```
                       netis-nx62-openwrt-flash
                        stock firmware → OpenWrt
                                  │
        ┌─────────────────┬───────┴───────┬──────────────────┐
        ▼                 ▼               ▼                  ▼
 openwrt-remote-access  openwrt-vpn-client  openwrt-monitoring  openwrt-torrent
 reach it from away     the tunnel; all       metrics in Grafana   USB + Transmission
                        traffic through it
        1.                    2.  │                 4.                  5.
                                  ▼
                       openwrt-selective-routing
                       only blocked services through it
                                  3. (instead of "all traffic")
```

### Which skill answers which question

Each skill's description claims its own questions and names its neighbours for the
rest, so they do not compete for the same request:

| Question | Skill |
|---|---|
| "Put OpenWrt on this box", "it is bricked" | `netis-nx62-openwrt-flash` |
| "Reach my router from outside", "is it CGNAT", "the tunnel is up but the port is dead" | `openwrt-remote-access` |
| "All traffic through a VPN", "AmneziaWG on OpenWrt", "handshake but no traffic" | `openwrt-vpn-client` |
| "Only blocked sites through the VPN", "Podkop", "local sites direct" | `openwrt-selective-routing` |
| "Router metrics in Grafana", "the dashboard is empty", "metrics stopped" | `openwrt-monitoring` |
| "Torrents on the router", "is this flash drive any good" | `openwrt-torrent` |

| Skill | What it does | Add it when |
|---|---|---|
| [`netis-nx62-openwrt-flash`](skills/netis-nx62-openwrt-flash/) | Stock firmware → OpenWrt via U-Boot TFTP recovery, checksum-gated at every write | you have the box and want OpenWrt on it |
| [`openwrt-remote-access`](skills/openwrt-remote-access/) | Independent ways in from behind NAT or CGNAT: a WireGuard spoke and reverse SSH tunnels, the fix for the failure that survives procd, and a three-channel layout for routers that also run a VPN | the router lives somewhere you are not |
| [`openwrt-vpn-client`](skills/openwrt-vpn-client/) | The tunnel itself, and the whole network through it: policy routing as a kill switch, endpoint pinning, DNS, failover, AmneziaWG 2.0 on 25.12, and what to do when the handshake completes but no data flows | everyone behind the router should exit through a tunnel — or you need the tunnel for the next row |
| [`openwrt-selective-routing`](skills/openwrt-selective-routing/) | Only blocked services through that tunnel, with Podkop: lists, own domains, the DNS trap on phones, a test client that leaves nothing behind | blocked sites and messengers need a tunnel, everything else should stay direct and fast |
| [`openwrt-monitoring`](skills/openwrt-monitoring/) | Router metrics into an existing Grafana — exporter choice with measured footprints, and why community dashboards render blank | you already run Prometheus/VictoriaMetrics |
| [`openwrt-torrent`](skills/openwrt-torrent/) | Transmission on USB storage, including vetting the drive before trusting it | the router should also download things |

**Suggested order: remote access → VPN → (selective routing) → monitoring →
torrents.** Access first, because every later change can lock you out of a box you
cannot reach; selective routing only after the tunnel carries data; monitoring after
both, because the tunnel's handshake age is the metric worth alerting on; storage
last. "All traffic through the VPN" and "only blocked services" are two policies for
the same tunnel — choose one. Install one at a time — a problem then has exactly one
candidate cause.

Each skill folder holds a `SKILL.md` (the full procedure), a `GUIDE.md`
(checklist), plus `references/` and `scripts/` where they apply, and a packaged
`.skill` file.

## Install

- **Import a package:** open the `.skill` file inside a skill's folder in
  Claude and click *Save skill*, **or**
- **Manual:** copy a skill's folder to `~/.claude/skills/<name>/`.

Then describe what you want — *"I have a Netis NX62 and want OpenWrt on it"*,
*"route all my traffic through a VPN on the router"*, *"reach my router from
outside"*, *"get my OpenWrt router into Grafana"*, *"set up torrents on my
router"* — and the matching skill triggers.

## Use them as plain guides

No Claude needed. Read the `GUIDE.md` in a skill's folder, then its `SKILL.md`.

> ⚠️ **Flashing can brick your router.** The flashing skill writes to NAND
> (`mtd write`, `ubiformat`, `sysupgrade`). It verifies every checksum, backs up
> all partitions first and gates the irreversible step behind a packet capture —
> but you use it **at your own risk**, with **no warranty**.

## Flashing — what makes it different

Real, field-tested lessons that trip people up (verified end-to-end on macOS):

- **Keep your internet while flashing** — set the wired NIC to a static
  `192.168.1.254/24` with **no gateway**, so it can never steal your default
  route. Internet stays on Wi-Fi.
- **The LAN-port rule is deterministic, not luck.** U-Boot's recovery TFTP works
  on **LAN2–LAN4** and never on LAN1: LAN1 and WAN hang off an external Maxlinear
  GPY211C PHY that U-Boot has no driver for, while LAN2–LAN4 sit on the MT7531
  switch's internal PHY. The symptom of getting it wrong is a link that flaps
  every ~30 s with no TFTP request.
- **Write order that fails safe** — FIP first (reversible), then erase ubi (point
  of no return), then BL2 **last** from a re-triggerable recovery. Every write is
  checksum-verified by reading it back.
- **Correct partition numbering** — `ubi` is a different `mtd` number on stock vs
  in recovery; the guide reads `/proc/mtd` live instead of assuming.
- **No secrets** — every `sudo` is interactive; nothing hardcodes a password.

## The add-ons — what makes them different

- **Remote access:** the failure nobody warns you about is not the tunnel
  dropping, it is `dbclient` surviving a *refused* forward — a live process with
  a dead tunnel that procd happily leaves alone, and it happens on every reboot.
  dropbear 2025.x finally takes `-o ExitOnForwardFailure=yes`; the skill uses it,
  and keeps the watchdog for older builds. For a router behind CGNAT that also
  runs a VPN, it lays out three channels that fail for different reasons.
- **Selective routing:** the household rarely wants *everything* abroad — banks
  and local services break, CDNs slow down. Podkop sends only listed services
  through the tunnel. The skill installs it by hand, explains why phones with
  "Private DNS" silently bypass it, and tests the result from a fake LAN client.
- **VPN client:** the kill switch is not a feature you enable, it is the absence
  of a `lan → wan` forwarding rule plus `suppress_prefixlength 0`. The skill also
  covers the mistake that makes a tunnel die seconds after coming up — an
  endpoint that is not pinned to the WAN gateway, so the handshake routes into
  the tunnel it is establishing.
- **Monitoring:** measured overlay footprints for eight agents on a 128 MB NAND
  router, and the five independent reasons a community Grafana board draws
  nothing — all of which look identical from the outside.
- **Torrent:** vet the flash drive before configuring anything, mount by UUID,
  and gate the daemon on the mount so it can never fill the router's own NAND.

## Contents

```
skills/
├── netis-nx62-openwrt-flash/   SKILL.md GUIDE.md references/ scripts/backup-mtd.sh
├── openwrt-remote-access/      SKILL.md GUIDE.md scripts/{reverse-tunnel.init,reverse-tunnel-via-vpn.sh,tunnel-watchdog.sh}
├── openwrt-vpn-client/         SKILL.md GUIDE.md scripts/vpn-failover.sh
│                               references/{choosing-an-amneziawg-implementation,building-amneziawg-from-source,diagnosing-isp-blocking}.md
├── openwrt-selective-routing/  SKILL.md GUIDE.md scripts/test-client.sh
├── openwrt-monitoring/         SKILL.md GUIDE.md references/ scripts/{vmagent.init,check-dashboard.py}
└── openwrt-torrent/            SKILL.md GUIDE.md references/ scripts/{transmission-guard.sh,usb-bench.sh,usb-capacity-check.sh}
```

## Credits

- Command sequence and device research build on
  [SevenMaxs/netis-nx62-flash-tools](https://github.com/SevenMaxs/netis-nx62-flash-tools).
- OpenWrt images: the official
  [OpenWrt firmware selector](https://firmware-selector.openwrt.org/) /
  [downloads](https://downloads.openwrt.org/) for `mediatek/filogic`,
  `netcore_n60-pro`.

## License

MIT — see [LICENSE](LICENSE).
