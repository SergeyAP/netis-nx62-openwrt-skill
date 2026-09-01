# openwrt-router-skills

Field-tested [Claude](https://claude.com/claude-code) **skills** — and equally
usable plain guides — for the **Netis NX62** / **Netcore N60 Pro** (MediaTek
**MT7986A / Filogic**, OpenWrt id `netcore_n60-pro`) and, beyond the flashing
one, for OpenWrt routers generally.

| Skill | What it does |
|---|---|
| [`netis-nx62-openwrt-flash`](skills/netis-nx62-openwrt-flash/) | Stock firmware → OpenWrt via U-Boot TFTP recovery, checksum-gated at every write |
| [`openwrt-monitoring`](skills/openwrt-monitoring/) | Router metrics into an existing Grafana, plus remote access from behind NAT |
| [`openwrt-torrent`](skills/openwrt-torrent/) | Transmission on USB storage — including vetting the drive before trusting it |

Each folder holds a `SKILL.md` (the full procedure), a `GUIDE.md` (checklist),
plus `references/` and `scripts/`.

## Install

- **Import a package:** open the `.skill` file inside a skill's folder in
  Claude and click *Save skill*, **or**
- **Manual:** copy a skill's folder to `~/.claude/skills/<name>/`.

Then describe what you want — *"I have a Netis NX62 and want OpenWrt on it"*,
*"get my OpenWrt router into Grafana"*, *"set up torrents on my router"* — and
the matching skill triggers.

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
- **The LAN-port gotcha** — after `mtd erase ubi` the link may flap up/down every
  ~30 s with no TFTP request. On this board U-Boot's recovery TFTP only works on
  a **specific LAN port** (LAN4 worked when LAN1 didn't). A packet-capture step
  tells you exactly what's happening instead of guessing.
- **Write order that fails safe** — FIP first (reversible), then erase ubi (point
  of no return), then BL2 **last** from a re-triggerable recovery. Every write is
  checksum-verified by reading it back.
- **Correct partition numbering** — `ubi` is a different `mtd` number on stock vs
  in recovery; the guide reads `/proc/mtd` live instead of assuming.
- **No secrets** — every `sudo` is interactive; nothing hardcodes a password.

## Contents

| File | What |
|---|---|
| [`SKILL.md`](SKILL.md) | Full procedure: bootchain, ordered writes, safety gates |
| [`GUIDE.md`](GUIDE.md) | Minimum requirements + quick checklist |
| [`references/host-macos.md`](references/host-macos.md) | macOS host setup (verified) |
| [`references/host-linux.md`](references/host-linux.md) | Linux host setup |
| [`references/host-windows.md`](references/host-windows.md) | Windows host setup (tftpd64 / WSL2) |
| [`references/troubleshooting.md`](references/troubleshooting.md) | Link flap, no TFTP, wrong port, brick paths |
| [`scripts/backup-mtd.sh`](scripts/backup-mtd.sh) | Stream-and-verify MTD backup (macOS/Linux) |
| `netis-nx62-openwrt-flash.skill` | Packaged skill for one-click import into Claude |

## Use it as a Claude skill

- **Import the package:** open `netis-nx62-openwrt-flash.skill` in Claude and
  click *Save skill*, **or**
- **Manual install:** copy this folder to `~/.claude/skills/netis-nx62-openwrt-flash/`.

Then just tell Claude something like *"I have a Netis NX62 and want to put OpenWrt
on it from my Mac"* — the skill triggers automatically.

## Use it as a plain guide

You don't need Claude. Read [`GUIDE.md`](GUIDE.md) then [`SKILL.md`](SKILL.md) and
follow the steps yourself.

## Credits

- Command sequence and device research build on
  [SevenMaxs/netis-nx62-flash-tools](https://github.com/SevenMaxs/netis-nx62-flash-tools).
- OpenWrt images: the official
  [OpenWrt firmware selector](https://firmware-selector.openwrt.org/) /
  [downloads](https://downloads.openwrt.org/) for `mediatek/filogic`,
  `netcore_n60-pro`.

## License

MIT — see [LICENSE](LICENSE).
