# netis-nx62-openwrt-flash

A safety-gated, cross-platform guide for flashing a **Netis NX62** (the hardware
twin of the **Netcore N60 Pro**, MediaTek **MT7986A / Filogic**, OpenWrt id
`netcore_n60-pro`) from stock firmware to **OpenWrt**, via the U-Boot **TFTP
recovery** path.

It ships as a [Claude](https://claude.com/claude-code) **skill** — so Claude can
walk you through the flash one careful step at a time — but the same files are
also a perfectly good **human-readable guide**. Start with
[`GUIDE.md`](GUIDE.md) for the checklist, or [`SKILL.md`](SKILL.md) for the full
explained procedure.

> ⚠️ **Flashing can brick your router.** Writing to NAND (`mtd write`,
> `ubiformat`, `sysupgrade`) is risky. This guide verifies every image checksum,
> backs up all flash partitions first, and gates the one irreversible step
> behind a live packet-capture check — but you use it **at your own risk**. There
> is **no warranty**. If you are not comfortable, stop and find help.

## What makes this different

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
