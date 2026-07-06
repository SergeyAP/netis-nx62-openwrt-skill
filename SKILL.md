---
name: netis-nx62-openwrt-flash
description: >-
  Use this when someone wants to install, flash, or recover/de-brick OpenWrt on a
  Netis NX62 or Netcore N60 Pro — the same MediaTek MT7986A / Filogic board,
  OpenWrt id `netcore_n60-pro`. Covers the full U-Boot TFTP recovery flash:
  sha256-checking images, host setup on macOS/Linux/Windows (static IP without
  losing internet, TFTP server, the exact recovery filename U-Boot requests,
  packet-capture verification), a shell on stock firmware, backing up MTD
  partitions, and the ordered writes of preloader/`bl2`, `bl31-uboot.fip`,
  `ubiformat`, and `sysupgrade`. Leads the user one flash-write at a time with
  checksum verification before every irreversible step. Trigger for: which TFTP
  server/filename to use, `mtd write` says read-only, the order to write
  preloader/FIP, recovery without a UART console, the link flapping every ~30 s
  after `mtd erase ubi`, or a nervous first-timer who only says "I have a Netis
  NX62 and want OpenWrt." Do not trigger for other router models.
---

# Flashing a Netis NX62 / Netcore N60 Pro to OpenWrt

## What this is and who it's for

The **Netis NX62** and **Netcore N60 Pro** are the same board: MediaTek **MT7986A
(Filogic)**, 512 MB RAM, 128 MB SPI-NAND, OpenWrt target `mediatek/filogic`,
device id `netcore_n60-pro`. This skill installs stock → OpenWrt using the
**U-Boot TFTP recovery** method. Every write to flash is checksum-verified, and
the one irreversible moment is gated behind a live packet-capture check.

**Golden rule — repeat it to the user:** any write to NAND (`mtd write`,
`ubiformat`, `sysupgrade`) can brick the device. Never write an image whose
`sha256` you have not personally verified, never continue past a failed
verification, and never skip the backup. While the `ubi` partition is empty the
device is *not* bricked — U-Boot still runs and can always re-enter TFTP
recovery.

**Guide the user ONE step at a time. Stop and get an explicit "go" before every
command that writes to flash.** The user is often a nervous non-expert; your job
is to be the careful co-pilot, explain *why* each step matters, and never rush.

## Security — never leak the sudo password

Several host-side steps need `sudo` (setting a static IP, running a TFTP server,
packet capture). Always use a **bare `sudo`** so the OS prompts the user
interactively. **Never** embed, echo, log, or write a password into any command,
script, file, or example — not even a placeholder that looks like a real one. If
the user pastes their password to you, do not store it anywhere; use it only for
the immediate command and never persist it.

## The bootchain (why the steps are ordered the way they are)

The MT7986A boots: **BootROM → BL2 (preloader) → FIP (U-Boot + BL31) → kernel in
UBI**. We install in this order for a reason:

1. Write the OpenWrt **FIP** while still on stock (stock BL2 can load it) — this
   is *reversible* until the first reboot.
2. Erase **UBI** and reboot → OpenWrt's U-Boot finds nothing to boot and
   **auto-requests the recovery image over TFTP** from the host. This is the
   **point of no return**.
3. Boot the RAM-only recovery OpenWrt, then write the OpenWrt **BL2** (the most
   dangerous single write) and finally `sysupgrade` the permanent image.

Because BL2 is written *last* (from a known-good recovery we can always
re-trigger), a failed BL2 write is recoverable, and a failed FIP write is
reversible. That ordering is the whole safety story.

## Prerequisites (minimum viable setup)

- The router, its power supply, and **one Ethernet cable**.
- A host computer (macOS / Linux / Windows) with a working Ethernet port or a
  **USB-Ethernet adapter**. Keep the host's internet on Wi-Fi.
- `ssh`, `scp`, a **TFTP server**, and a **packet sniffer** on the host. See the
  matching `references/host-<os>.md` for exact tools per OS.
- Basic terminal comfort. No UART/serial is required for this path, **but** a
  UART adapter is the only guaranteed rescue if BL2 is ever corrupted — mention
  this risk honestly.
- 30–60 minutes and patience.

See `GUIDE.md` for the condensed checklist version of all requirements.

## Step 0 — Download and verify the images

From the OpenWrt firmware selector / downloads for your chosen release
(`https://downloads.openwrt.org/releases/<VERSION>/targets/mediatek/filogic/`),
get these **four** files for `netcore_n60-pro` plus the `sha256sums` file:

| File | Role |
|---|---|
| `openwrt-<VER>-mediatek-filogic-netcore_n60-pro-preloader.bin` | **BL2** |
| `openwrt-<VER>-mediatek-filogic-netcore_n60-pro-bl31-uboot.fip` | **FIP** |
| `openwrt-<VER>-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb` | recovery (RAM) |
| `openwrt-<VER>-mediatek-filogic-netcore_n60-pro-squashfs-sysupgrade.itb` | final firmware |

Verify every file against `sha256sums` and refuse to continue on any mismatch:

```sh
# from the download folder
grep netcore_n60-pro sha256sums | sed 's/ \*/  /' | shasum -a 256 -c   # macOS
# on Linux use: sha256sum -c
```

Also download `kmod-mtd-rw` for your exact kernel from the release's `kmods/`
directory — you'll install it offline inside recovery to unlock the BL2 write.
Its integrity is guaranteed by the HTTPS download and `apk`'s own checks.

## Step 1 — Host network (static IP, NO gateway)

Give the host `192.168.1.254/24` on the wired interface, **with no default
gateway**. This is the trick that keeps your internet working: without a gateway,
the wired link can carry traffic to the router (`192.168.1.0/24`) but can never
become the host's default route, so the internet stays on Wi-Fi. Setting a
gateway here — or letting the interface take DHCP from the router — is exactly
what makes people lose internet and get confused.

Confirm afterwards that the default route is still your Wi-Fi interface. Exact
commands per OS are in `references/host-<os>.md`.

## Step 2 — Host TFTP server serving the recovery image

Run a TFTP server whose root contains the recovery image **renamed without the
version** — this is the filename U-Boot's built-in default environment requests:

```
openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
```

Then **prove the server actually serves it** before trusting it (fetch it back
over TFTP and compare `sha256`). U-Boot on this board requests `blksize 1468`;
make sure your server honors it — the macOS built-in `tftpd` does. Per-OS setup
and the self-test are in `references/host-<os>.md`.

Also ensure the host firewall allows inbound **UDP/69** (or is off), or the
router's TFTP request never reaches you.

## Step 3 — Get a shell on the stock router

Stock Netis NX62 already runs Dropbear SSH. Log in as **`useradmin`** with the
**web-panel password** (same credentials). `useradmin` has `uid=0`.

- Forgot the password? Factory-reset (hold `RESET` ~10 s), walk the setup wizard,
  set a new admin password. The WAN mode you pick in the wizard is irrelevant.
- After a reset the router's SSH host key changes; clear the stale one with
  `ssh-keygen -R 192.168.1.1` before reconnecting.
- To drive the flash unattended, install a key so no password is needed:
  ```sh
  ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/nx62_key           # host, no passphrase
  cat ~/.ssh/nx62_key.pub | ssh useradmin@192.168.1.1 \
      'mkdir -p /etc/dropbear && cat >> /etc/dropbear/authorized_keys'
  ```

## Step 4 — Read the partition map and back up EVERYTHING

Never assume partition numbers — read them live:

```sh
ssh -i ~/.ssh/nx62_key useradmin@192.168.1.1 'cat /proc/mtd'
```

On **stock** you'll typically see (numbers can shift between firmwares — trust
the *names*, not the digits):

```
mtd0 spi0.1 (whole 128MB)   mtd1 BL2   mtd2 u-boot-env
mtd3 Factory (WiFi cal+MAC) mtd4 FIP   mtd5 ubi
```

Note: on stock **`ubi` is `mtd5`**, not `mtd4` (`mtd4` is `FIP`). The `mtd write`
/ `mtd erase` commands take the partition **name**, so they're safe. But
`ubiformat` later takes a **number**, and in recovery the numbering is different
— always re-read `/proc/mtd` there.

Back up **all** partitions to the host and verify each with a checksum computed
on **both** sides. Use `scripts/backup-mtd.sh` (streams each partition over SSH
straight to the host, so it never fills the router's RAM, and compares `md5` on
router vs host):

```sh
scripts/backup-mtd.sh useradmin@192.168.1.1 ~/.ssh/nx62_key ~/nx62-backup
```

`Factory` (MAC + WiFi calibration) and the full-chip `spi0.1` dump are the ones
you cannot recreate — make sure they're saved and copied somewhere off the host.

## Step 5 — Flash, one gated write at a time

Do a **pre-flight** first (all read-only): static IP still set and link up,
router reachable, internet still on Wi-Fi, TFTP self-test passes, firewall
allows UDP/69, all image `sha256`s good, disk space free.

### 5A/5B — Write FIP (reversible until reboot) — needs a "go"

```sh
scp -O -i ~/.ssh/nx62_key openwrt-<VER>-...-bl31-uboot.fip useradmin@192.168.1.1:/tmp/
# verify md5 on the router equals the local file, THEN:
ssh -i ~/.ssh/nx62_key useradmin@192.168.1.1 'mtd write /tmp/openwrt-<VER>-...-bl31-uboot.fip FIP'
# verify: read back the first <filesize> bytes of the FIP partition and compare md5
```

### 5C — Erase UBI + reboot — THE POINT OF NO RETURN — needs an explicit "go"

```sh
ssh -i ~/.ssh/nx62_key useradmin@192.168.1.1 'mtd erase ubi'
ssh -i ~/.ssh/nx62_key useradmin@192.168.1.1 'reboot'
ssh-keygen -R 192.168.1.1     # recovery will present a new host key
```

Now watch for the router to auto-load recovery over TFTP. **This is where the
single most common failure happens** — see the packet-capture gate below.

### 5D — Confirm recovery actually loaded (packet-capture gate)

After the reboot the host's wired link will flap. Capture traffic on the wired
interface to see what the router is really doing (macOS/Linux `tcpdump`, Windows
Wireshark — see `references/host-<os>.md`):

- **Good:** you see the router send `ARP who-has <host-ip>` and a
  `TFTP RRQ "openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb"`,
  followed by a real data transfer; within a minute SSH (port 22) comes up and
  stays up.
- **Bad (the classic gotcha):** the link flaps up/down roughly **every ~30 s**
  and you see **no** TFTP request from the router. On this board **U-Boot's
  recovery TFTP only works on a specific LAN port.** Move the cable to a
  different LAN port (LAN4 is known to work when LAN1 didn't) and watch again.
- Fallback trigger: power off, hold `RESET`, power on, keep holding ~10 s to
  force U-Boot into recovery.

Do **not** proceed until you can SSH into the recovery system. See
`references/troubleshooting.md` for more failure modes.

### 5E — In recovery: write BL2 (most dangerous write) — needs an explicit "go"

Recovery runs OpenWrt from RAM; log in as **`root` with no password**. Re-read
`/proc/mtd` — in recovery it's usually `mtd0 bl2, mtd1 u-boot-env, mtd2 factory,
mtd3 fip, mtd4 ubi` (so here **`ubi` is `mtd4`**). Then:

```sh
scp -O -i ~/.ssh/nx62_key openwrt-<VER>-...-preloader.bin  root@192.168.1.1:/tmp/
scp -O -i ~/.ssh/nx62_key kmod-mtd-rw-<...>.apk            root@192.168.1.1:/tmp/
# verify preloader md5 host vs router, then:
ssh -i ~/.ssh/nx62_key root@192.168.1.1 \
  'apk add --allow-untrusted --no-network --force-missing-repositories --force-non-repository /tmp/kmod-mtd-rw-<...>.apk'
ssh -i ~/.ssh/nx62_key root@192.168.1.1 \
  'insmod mtd-rw i_want_a_brick=1 && mtd write /tmp/openwrt-<VER>-...-preloader.bin bl2'
# verify: read back the first <filesize> bytes of bl2 and compare md5
```

Tell the user: do not touch power or cable during this write. It finishes in a
second or two, but a power loss here is the worst-case scenario.

### 5F — Format UBI and sysupgrade the final image — needs a "go"

Use the `ubi` **number you just read in recovery** (usually `mtd4`):

```sh
scp -O -i ~/.ssh/nx62_key openwrt-<VER>-...-squashfs-sysupgrade.itb root@192.168.1.1:/tmp/
ssh -i ~/.ssh/nx62_key root@192.168.1.1 '
  ubidetach -p /dev/mtd4;
  ubiformat -y /dev/mtd4 &&
  ubiattach -p /dev/mtd4 &&
  ubimkvol /dev/ubi0 -n 0 -N ubootenv  -S 2 &&
  ubimkvol /dev/ubi0 -n 1 -N ubootenv2 -S 2'
ssh -i ~/.ssh/nx62_key root@192.168.1.1 'sysupgrade -n /tmp/openwrt-<VER>-...-squashfs-sysupgrade.itb'
```

`sysupgrade` closes the SSH session and reboots — a dropped connection here is
expected, not an error.

## Step 6 — Confirm the permanent install

After the reboot, SSH back in (host key changes again) and confirm it booted
from flash, not RAM:

```sh
ssh-keygen -R 192.168.1.1
ssh -o StrictHostKeyChecking=no root@192.168.1.1 \
  'uptime; mount | grep -E "overlay|/rom"; cat /etc/openwrt_release | grep DESCRIPTION'
```

Success looks like: `uptime` near zero, `/dev/root on /rom` (squashfs) **and** an
`overlay` mounted from `ubi` — that overlay is the tell-tale of a real on-flash
install (recovery has only tmpfs). LuCI is at `http://192.168.1.1`, `root` has no
password.

**First thing after success:** have the user set a `root` password (LuCI → System
→ Administration, or `passwd` over SSH). Keep the stock backup safe off-host as
the road back to stock.

## Reference material

- `references/host-macos.md` — macOS host setup (verified end-to-end)
- `references/host-linux.md` — Linux host setup (`tftpd-hpa`, NetworkManager/ip)
- `references/host-windows.md` — Windows host setup (tftpd64 / WSL, Wireshark)
- `references/troubleshooting.md` — link flap, no TFTP, wrong port, brick paths
- `scripts/backup-mtd.sh` — stream-and-verify MTD backup (macOS/Linux host)
- `GUIDE.md` — condensed requirements + quick checklist
