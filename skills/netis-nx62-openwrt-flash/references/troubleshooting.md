# Troubleshooting

## The wired link flaps up/down about every 30 seconds after `mtd erase ubi`

**Most common issue.** U-Boot is alive (the PHY comes up each cycle), but its
TFTP recovery isn't succeeding, so it resets and retries. Diagnose by capturing
traffic *from the router* (see the host reference for your OS):

- **You see NO TFTP request from the router** → U-Boot's recovery is bound to a
  **specific LAN port**. Move the Ethernet cable to another LAN port. On this
  board **LAN4 works when LAN1 does not**. Re-watch the capture.
- **You see the TFTP request but the transfer stalls** (router re-sends the same
  4-byte ACK repeatedly, then resets) → the TFTP server isn't delivering data.
  Check: firewall allows UDP/69; server honors `blksize 1468`; the file is
  present with the exact versionless name. Re-run the host-side "prove it serves"
  self-test with `--tftp-blksize 1468`.
- **Nothing at all on the wire** → wrong interface has the `192.168.1.254`
  address, or the cable is in the WAN port. WAN is a separate 2.5G port; use a
  LAN port.

Fallback recovery trigger (any time): power off, hold `RESET`, power on, keep
holding ~10 s to force U-Boot into failsafe/TFTP.

**Reassure the user:** while UBI is empty and U-Boot still runs, the device is
not bricked — you can retry the recovery trigger as many times as needed.

## `Permission denied` / `REMOTE HOST IDENTIFICATION HAS CHANGED` on SSH

Expected after a factory reset or after entering recovery — the router generated
a new SSH host key. Clear the stale entry and reconnect:

```sh
ssh-keygen -R 192.168.1.1
```

## Can't log into the stock web panel / forgot the password

Factory-reset (hold `RESET` ~10 s), then complete the setup wizard and set a new
admin password. The stock config doesn't matter — you're about to replace it.

## `scp` fails against the stock/recovery Dropbear

Add the legacy protocol flag: `scp -O ...`. Modern OpenSSH defaults to SFTP,
which minimal Dropbear builds may not provide.

## `apk add` prints "opening from cache ... No such file or directory"

Harmless. In recovery there's no internet, so `apk` fails to reach online repos
and then installs from your local `.apk`. Look for the final
`Installing kmod-mtd-rw ... OK`.

## Verifying a flash write when the partition is bigger than the file

`mtd write` erases the whole partition and writes your file at the start; the
remainder is erased (0xFF). So don't checksum the whole partition — compare only
the first *filesize* bytes:

```sh
dd if=/dev/mtdX bs=<filesize> count=1 2>/dev/null | md5sum   # on the router
```

Compare that to the local file's `md5`.

## After `sysupgrade`, is it really the permanent install?

Confirm an `overlay` is mounted from UBI (recovery has only tmpfs):

```sh
mount | grep -E "overlay|/rom"      # want /dev/root on /rom (squashfs) + overlay from ubi
uptime                               # near zero right after boot
```

## Worst case: corrupted BL2 / no boot at all

If BL2 itself is damaged and the device won't reach U-Boot (no PHY activity, no
recovery), the MediaTek BootROM download mode over **UART** (or the vendor's
USB/BootROM tooling) is the rescue path. This needs a UART/serial adapter and is
beyond this TFTP procedure — which is exactly why BL2 is written **last**, from a
recovery you can always re-enter, and why you keep the stock `BL2`/full-chip
backup.
