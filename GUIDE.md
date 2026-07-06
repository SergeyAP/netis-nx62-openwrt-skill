# Quick Guide — what you need and the order of operations

A condensed checklist for flashing a **Netis NX62 / Netcore N60 Pro** to OpenWrt.
Read `SKILL.md` for the full, explained procedure — this page is the "do I have
everything?" summary.

## Minimum requirements

**Hardware**
- Netis NX62 (or Netcore N60 Pro) + its power supply.
- One Ethernet cable.
- A computer running macOS, Linux, or Windows.
- An Ethernet port or USB-Ethernet adapter on the computer. (Keep the computer's
  internet on Wi-Fi during the whole process.)
- Optional but the only guaranteed rescue for a corrupted BL2: a **USB-UART/serial
  adapter**. Not needed if all verifications pass.

**Software on the host** (see `references/host-<os>.md` for exact packages)
- `ssh` and `scp`.
- A **TFTP server** (macOS: built-in; Linux: `tftpd-hpa`; Windows: tftpd64 or WSL2).
- A **packet sniffer** (`tcpdump` on macOS/Linux, Wireshark on Windows) — this is
  not optional; it's the safety gate that tells you recovery actually loaded.
- `curl` (to self-test the TFTP server), and `sha256`/`md5` tools (built in).

**Files to download** (from the OpenWrt release for `mediatek/filogic`)
- `...netcore_n60-pro-preloader.bin` (BL2)
- `...netcore_n60-pro-bl31-uboot.fip` (FIP)
- `...netcore_n60-pro-initramfs-recovery.itb` (recovery)
- `...netcore_n60-pro-squashfs-sysupgrade.itb` (final)
- `sha256sums` (to verify all of the above)
- `kmod-mtd-rw` `.apk` for the matching kernel (from the release's `kmods/` dir)

**Network numbers used throughout**
- Router: `192.168.1.1`
- Host wired interface: `192.168.1.254/24`, **no gateway**
- TFTP filename U-Boot requests (recovery renamed without version):
  `openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb`

## The order of operations (each flash write needs a conscious "go")

1. Download images, **verify every `sha256`**.
2. Host: static IP `192.168.1.254/24` **without a gateway**; confirm internet is
   still on Wi-Fi.
3. Host: start TFTP with the versionless recovery file; **self-test** it with
   `curl --tftp-blksize 1468`.
4. SSH into stock router (`useradmin`, web password); read `/proc/mtd`.
5. **Back up all MTD partitions** and verify checksums (`scripts/backup-mtd.sh`).
   Copy the backup off the host.
6. `mtd write FIP` (verify) — reversible until reboot.
7. `mtd erase ubi` + `reboot` — **point of no return**.
8. **Packet-capture gate:** confirm the router sends a TFTP request and loads
   recovery. Link flapping every ~30 s with no TFTP = **move the cable to another
   LAN port (try LAN4)**.
9. In recovery (`root`, no password), re-read `/proc/mtd`; install `kmod-mtd-rw`
   offline; `insmod mtd-rw i_want_a_brick=1 && mtd write ... bl2` (verify).
10. `ubiformat` the ubi partition + create `ubootenv`/`ubootenv2`; `sysupgrade -n`
    the final image.
11. Confirm the permanent install (an `overlay` mounted from UBI); set a `root`
    password.

## The three things people get wrong

- **Setting a gateway on the wired interface** → they lose internet. Don't set one.
- **Cable in the wrong LAN port** → U-Boot recovery never TFTPs. Watch the capture;
  move to LAN4 if the link just flaps.
- **Skipping checksum/capture verification** → flashing a corrupt or wrong image.
  Every write is verified here for a reason; never skip a gate.
