---
name: openwrt-torrent
description: >-
  Use this when someone wants to run Transmission on an OpenWrt router with USB
  storage, or when their router-plus-flash-drive setup is slow, stalling, or
  silently losing data. Covers vetting the drive BEFORE trusting it (fake
  capacity test, sustained random-write benchmark), mounting by UUID, running
  the daemon only while the drive is present so it can never fill the router's
  internal flash, and the single setting that makes downloads crawl on NTFS.
  Trigger for: "torrents on my router", "transmission on OpenWrt", "usb drive
  for my router", "my torrent is stuck", "is this flash drive any good", "the
  router freezes when downloading", "how do I check a USB drive for fake
  capacity". Not for seedbox setup on a real server — this is about a router
  with a few hundred MB of RAM and finite NAND.
---

# Transmission on an OpenWrt router, with a USB drive that deserves it

## The order that saves you a weekend

1. **Vet the drive first.** Ten minutes of testing, before any configuration.
2. **Mount it by UUID**, to a fixed path.
3. **Run the daemon only when the drive is mounted** — this is a safety
   mechanism, not a convenience.
4. **Turn off preallocation.** On NTFS it is the difference between a working
   setup and an hour of writing zeros.

Skipping step 1 is how people end up debugging Transmission when the actual
problem is a counterfeit flash drive.

**Golden rule:** never let the download directory resolve to internal flash.
The router has 60–100 MB of writable NAND with a finite write budget; a torrent
pointed at it will fill it and wear it out. Every safeguard here exists for
that one reason.

---

## Part 1 — Vet the drive before trusting it

### 1a. Is the capacity real?

Counterfeit drives report a large size, accept writes past their real capacity,
**return success**, and silently discard the data. No kernel error, no warning.
You find out when files come back empty months later.

Takes under a minute:

```sh
# WARNING: destructive. Do this on an empty drive.
for off in 0 1024 4096 8192 16384 24576; do
  printf 'MARKER-AT-%06d-MIB-END' "$off" \
    | dd of=/dev/sda bs=1M seek=$off count=1 conv=notrunc oflag=direct 2>/dev/null
done
sync
for off in 0 1024 4096 8192 16384 24576; do
  got=$(dd if=/dev/sda bs=1M skip=$off count=1 iflag=direct 2>/dev/null | head -c 24 | tr -d '\000')
  exp=$(printf 'MARKER-AT-%06d-MIB-END' "$off")
  [ "$got" = "$exp" ] && echo "  $off MiB: OK" || echo "  $off MiB: LOST"
done
```

`oflag=direct` is not optional — without it you are testing the page cache.

A real drive returns OK everywhere. A counterfeit returns OK for the first
marker or two and loses the rest. [`scripts/usb-capacity-check.sh`](scripts/usb-capacity-check.sh)
does this with a binary search for the real boundary.

Seen in the field: a drive reporting **31.25 GiB** that actually stored **17
MiB** — a factor of about 1800. It also corrupted data *within* those 17 MiB,
and no amount of reformatting fixed it, because the fault was in the controller.

Other tells, visible before any test:

```
speed=12 Mbit/s while the descriptor claims USB 2.0   ← negotiated at USB 1.1
bMaxPower=100mA                                        ← half of a normal drive
no partition table, filesystem written to the raw device
SCSI ANSI level 2
manufacturer string absent, model a generic "USB DISK 3.0"
```

### 1b. Is it fast enough?

Torrents are **sustained random writes from dozens of connections at once**.
Sequential speed on the packaging tells you almost nothing.

Run [`scripts/usb-bench.sh`](scripts/usb-bench.sh) **two or three times in a
row** and look at the fourth test's second figure — sustained random write,
after the controller's cache is exhausted.

```
                       won't do      tolerable     good
sequential write       < 15 MB/s     15–40 MB/s    > 40 MB/s
random write 4K         > 20 ms      5–20 ms       < 5 ms
IOPS                     < 50        50–200        > 200
queue depth               1            1           32 (UASP present)
spread between runs    several ×     tens of %     a few %
```

That last row is the one people miss. **Inconsistency is itself a verdict.** A
cheap controller runs garbage collection and wear levelling whenever it feels
like it, and those pauses land in one run but not the next. A good drive gives
you the same numbers every time.

Two real drives, same port, same test:

| | generic "USB DISK 3.0" 64 GB | Kingston DataTraveler 3.0 128 GB |
|---|---|---|
| sequential write | 4–6 MB/s | 48–113 MB/s |
| sequential read | 87–102 MB/s | 213–225 MB/s |
| random write, sustained | 2.4–47 ms | 3.6–19.3 ms |
| IOPS | 21–42 | 52–278 |
| spread between runs | up to 7× | under 2× |

The first one is not broken. It stores data faithfully. It simply cannot be a
torrent target — during a real download the router sat at **57 % iowait** with
a daemon thread stuck in uninterruptible sleep, and the web interface stopped
responding for over 90 seconds at a time.

### The benchmark's own trap

`busybox dd` with `conv=fsync` **returns before the data is on the device**.
Measure that and you are timing RAM: results jump by 15–50× between runs. Use
`oflag=direct`, and cross-check against `/proc/diskstats`, which counts what
the kernel actually issued. The bundled script does both.

---

## Part 2 — Storage setup

```sh
apk add kmod-usb-storage kmod-usb-storage-uas block-mount \
        kmod-fs-vfat kmod-fs-exfat kmod-fs-ntfs3 \
        kmod-nls-cp437 kmod-nls-iso8859-1 kmod-nls-utf8
```

`kmod-usb-storage-uas` costs 9 KB and is worth it: without UASP an SSD runs in
BOT mode, roughly 35 MB/s instead of 300.

ext4 and f2fs are usually built into the OpenWrt kernel — check
`/proc/filesystems` before installing anything for them.

### Filesystem choice

**ext4** if the drive stays in the router. **NTFS** if it also goes into a TV
or a Windows machine — FAT32 caps single files at 4 GB, which rules out most
video.

For NTFS use the in-kernel `ntfs3`, not `ntfs-3g` (FUSE, slower, heavier).
Specify it explicitly in fstab or `block` may pick the wrong one.

```sh
mkntfs -f -c 65536 -L DATA /dev/sda1
printf '\007' | dd of=/dev/sda bs=1 seek=450 count=1 conv=notrunc   # MBR type → 0x07
```

A 64 KB cluster instead of the default 4 KB measurably helps: in testing the
worst-case sustained random write improved threefold (19.3 → 6.5 ms) and the
run-to-run spread halved. Large media files do not care about the slack.

`mkntfs` only writes the filesystem; some devices read the **MBR partition
type** instead, so set it to `0x07` as well.

### Mounting

```
config mount
	option uuid    '<UUID>'
	option target  '/mnt/usb'
	option fstype  'ntfs3'
	option options 'rw,noatime,umask=0000,iocharset=utf8'
	option enabled '1'
```

**`iocharset=utf8` or non-Latin filenames turn to garbage** — ntfs3 otherwise
defaults to iso8859-1.

**`umask=0000` does less than it looks.** On ntfs3 it affects how existing
objects are *displayed*; newly created ones still follow the process umask. The
saving grace is that ntfs3 supports `chown` and `chmod`, so Transmission's own
init script fixes ownership when it creates its directories.

Reformatting changes the UUID, and it appears in **two** places — the fstab
entry and the guard script below. Miss one and the drive stops automounting.

---

## Part 3 — Transmission, gated on the drive

```sh
apk add transmission-daemon transmission-web luci-app-transmission
```

### Why it must be gated

Transmission's init script creates its directories before starting:

```sh
[ -d "$download_dir" ] || { mkdir -p "$download_dir"; ... }
```

If `/mnt/usb` is an ordinary empty directory because the drive is absent, that
`mkdir -p` lands **in internal flash**, and the daemon happily downloads into
the router's NAND. Nothing warns you.

So: disable autostart, and let a guard script decide.

```sh
/etc/init.d/transmission disable
```

Install [`scripts/transmission-guard.sh`](scripts/transmission-guard.sh) and
run it from cron every minute:

```
* * * * * /usr/bin/transmission-guard.sh
```

**Do not do this from a hotplug handler.** OpenWrt runs hotplug handlers
serially in one queue shared with network-interface events. A handler that
hangs — a slow `umount`, a failing drive — stalls netifd along with it, and you
lose your WAN because of a USB stick. cron costs you up to 60 seconds of
latency and cannot take anything else down with it.

### Configuration that matters

```
config_dir              /mnt/usb/torrents/config
download_dir            /mnt/usb/torrents/complete
incomplete_dir          /mnt/usb/torrents/incomplete
incomplete_dir_enabled  1
watch_dir               /mnt/usb/torrents/watch
watch_dir_enabled       1

preallocation           0      ← see below
cache_size_mb           64     ← default is 2
peer_limit_global       150
peer_limit_per_torrent  30
ratio_limit             1.0
ratio_limit_enabled     true
port_forwarding_enabled false
```

**`preallocation` must be 0.** This is the one that wastes an afternoon. On
ext4 preallocation is instant — a sparse file. **ntfs3 does not do sparse that
way and writes real zeros.** A 30 GB torrent means writing 30 GB of nothing
before a single byte arrives; on a slow drive that is over an hour of 100 %
iowait, during which the daemon appears hung and its web interface times out.
The symptom is unmistakable in hindsight: gigabytes on disk, almost nothing
downloaded.

**`cache_size_mb` 64 instead of 2** is what turns dozens of small peer writes
into a few large sequential ones. On a drive that does 2.9 MB/s at 4 KB blocks
but 48 MB/s at 1 MB, this is the difference between working and not.

**`port_forwarding_enabled false`** — behind CGNAT or a VPN, UPnP cannot help
and only announces you to the upstream router.

`watch_dir` is not created by the init script. Create it yourself, and restart
the daemon afterwards — it only picks up a watch directory that existed when it
started.

### If the router already routes everything through a VPN

Traffic follows the default route, so torrents go through the tunnel without
extra work — and a `forward`-based kill switch keeps LAN clients off the WAN.

But the daemon runs *on* the router, so its traffic goes through the `output`
chain, which a forward-only kill switch does not cover. If that matters, bind
Transmission to the tunnel address (`bind-address-ipv4`) so its sockets die
with the interface, or drop `meta skuid transmission oifname <wan>` in
nftables.

---

## Part 4 — When it looks stuck

Check in this order:

```sh
# 1. Is it actually the drive?
awk '/ sda /{printf "%.1f ms/write\n", $11/$8}' /proc/diskstats
top -bn1 | head -3          # iowait high? load climbing with idle CPU?
grep State /proc/$(pgrep transmission-daemon)/task/*/status | grep -c 'D (disk'

# 2. Is it preallocation rather than downloading?
df -h /mnt/usb              # disk filling …
# … while the RPC says percentDone is near zero → preallocation

# 3. Is the torrent simply paused?
# status 0 = stopped. Added without "start immediately" is a common cause.
```

A thread in state **D** plus 100+ ms per write means the drive, not the
software. Nothing in Transmission's settings will fix a drive that manages 21
random writes per second.

Corrupted pieces (`corruptEver` climbing) point at the medium too — a healthy
setup downloads hundreds of megabytes with zero corruption.

### Pulling the drive while it runs

The guard notices within a minute, stops the daemon and detaches the mount
point. The router itself is never at risk. But:

- data still in Transmission's cache is lost and re-downloaded — expected;
- NTFS is marked dirty, and **ntfs3 refuses to mount a dirty volume**, so the
  guard runs `ntfsfix` once and retries;
- the device may come back as a **different name** (`sda` → `sdb`) if the old
  name was still held. Never hard-code `/dev/sda1` — look the device up by
  UUID.

Both are handled in the bundled guard. Real damage does happen: on the first
hot-unplug, `ntfsfix` found and repaired a genuine `$MFTMirr` mismatch.

## Checklist

```
[ ] capacity verified with markers across the whole device
[ ] benchmark run 2–3 times; sustained random write and spread both acceptable
[ ] filesystem chosen for where the drive actually lives
[ ] mounted by UUID, iocharset=utf8, fixed path
[ ] transmission autostart DISABLED, guard in cron
[ ] guard verifies /proc/mounts before starting the daemon
[ ] preallocation = 0
[ ] cache_size_mb = 64
[ ] watch_dir created and daemon restarted after
[ ] guard script + UUID updated together after any reformat
[ ] guard script and cron listed in /etc/sysupgrade.conf
```
