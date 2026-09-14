# openwrt-router-skills

Field-tested [Claude](https://claude.com/claude-code) **skills** — and equally
usable plain guides — for the **Netis NX62** / **Netcore N60 Pro** (MediaTek
**MT7986A / Filogic**, OpenWrt id `netcore_n60-pro`) and, beyond the flashing
one, for OpenWrt routers generally.

Everything here was written after doing it on real hardware, so the parts that
usually cost an evening — a bootloader that only talks on certain ports, a
tunnel that looks alive while being dead, a dashboard that draws nothing — are
the parts these documents spend their words on.

## One base skill, four optional add-ons

The flashing skill is the base: it turns a stock router into a blank OpenWrt.
The other four are **independent add-ons** — pick what you need, in any
combination. None of them requires the flashing skill, and each works on any
OpenWrt router, not only this board.

```
                       netis-nx62-openwrt-flash
                        stock firmware → OpenWrt
                                  │
        ┌─────────────────┬───────┴───────┬──────────────────┐
        ▼                 ▼               ▼                  ▼
 openwrt-remote-access  openwrt-vpn-client  openwrt-monitoring  openwrt-torrent
 reach it from away     tunnel + kill switch  metrics in Grafana   USB + Transmission
        1.                    2.                    3.                  4.
```

| Skill | What it does | Add it when |
|---|---|---|
| [`netis-nx62-openwrt-flash`](skills/netis-nx62-openwrt-flash/) | Stock firmware → OpenWrt via U-Boot TFTP recovery, checksum-gated at every write | you have the box and want OpenWrt on it |
| [`openwrt-remote-access`](skills/openwrt-remote-access/) | Two independent ways in from behind NAT: a WireGuard spoke and a reverse SSH tunnel, with the watchdog for the failure that survives procd | the router lives somewhere you are not |
| [`openwrt-vpn-client`](skills/openwrt-vpn-client/) | The whole network through WireGuard/AmneziaWG: policy routing as a kill switch, endpoint pinning, DNS, automatic failover | everyone behind the router should exit through a tunnel |
| [`openwrt-monitoring`](skills/openwrt-monitoring/) | Router metrics into an existing Grafana — exporter choice with measured footprints, and why community dashboards render blank | you already run Prometheus/VictoriaMetrics |
| [`openwrt-torrent`](skills/openwrt-torrent/) | Transmission on USB storage, including vetting the drive before trusting it | the router should also download things |

**Suggested order: remote access → VPN → monitoring → torrents.** Access first,
because every later change can lock you out of a box you cannot reach; monitoring
after the VPN, because the tunnel's handshake age is the metric worth alerting
on; storage last. Install one at a time — a problem then has exactly one
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
  a dead tunnel that procd happily leaves alone. The skill ships the watchdog and
  explains the honest `dbclient` vs `autossh` trade (450 KB against 40 lines).
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
├── openwrt-remote-access/      SKILL.md GUIDE.md scripts/{reverse-tunnel.init,tunnel-watchdog.sh}
├── openwrt-vpn-client/         SKILL.md GUIDE.md scripts/vpn-failover.sh
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
