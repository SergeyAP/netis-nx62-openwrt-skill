# When the download looks stuck

## Decide first: drive, or software?

```sh
# average write latency the kernel has actually observed
awk '/ sda /{printf "%.1f ms per write\n", $11/$8}' /proc/diskstats

# iowait share, and load with an idle CPU
top -bn1 | head -3

# daemon threads in uninterruptible sleep = blocked on I/O
grep State /proc/$(pgrep transmission-daemon)/task/*/status | grep -c 'D (disk'
```

Over 100 ms per write and a thread in **D** means the drive. No Transmission
setting fixes a device managing 21 random writes per second.

Observed on a counterfeit-grade drive during a real download: 158 ms per write,
57 % iowait, load 4.5 on four cores, the RPC port accepting connections but
never answering — the RPC thread was waiting on a mutex held by the thread stuck
in the write.

## Disk filling but nothing downloading

That is preallocation, not a download.

```sh
df -h /mnt/usb        # gigabytes consumed
# meanwhile percentDone is near zero
```

`preallocation` on ntfs3 writes **real zeros**, not a sparse file. A 30 GB
torrent means 30 GB written before a single byte arrives. Set it to 0.

## The torrent is simply paused

Status `0` is stopped. Added without "start immediately" is a common cause and
looks exactly like a broken setup.

```sh
SID=$(curl -s -D- -o/dev/null localhost:9091/transmission/rpc \
      | awk '/X-Transmission-Session-Id/{print $2}' | tr -d '\r')
curl -s -H "X-Transmission-Session-Id: $SID" \
  -d '{"method":"torrent-get","arguments":{"fields":["id","name","status","percentDone","corruptEver"]}}' \
  localhost:9091/transmission/rpc
```

## Corrupted pieces accumulating

`corruptEver` climbing means the medium. A healthy setup downloads hundreds of
megabytes with zero corruption; a failing drive corrupted half of the first
33 MB in one observed case.

## The drive was pulled while running

Expected consequences, all handled by the guard:

- **Cached data is lost** and re-downloaded. Transmission verifies piece hashes
  on restart, so nothing is silently wrong.
- **NTFS is marked dirty** and ntfs3 refuses it:
  `volume is dirty and "force" flag is not set`. `ntfsfix -d` clears it. This is
  not cosmetic — the first hot-unplug in testing produced a genuine `$MFTMirr`
  mismatch that ntfsfix repaired.
- **The device name changes.** If the old name was still held, the same drive
  returns as `sdb`. Anything hard-coded to `/dev/sda1` stops working until
  reboot. Look the device up by UUID.

To detach cleanly instead:

```sh
/etc/init.d/transmission stop && sync && umount /mnt/usb
```

## Filesystem full but files are missing

Classic counterfeit-drive signature: the allocation table records the space as
used while the data never landed. Run `usb-capacity-check.sh`. Reformatting
does not help — the fault is in the controller.

## Things that look like bugs but are not

**`node_scrape_collector_success{collector="nft_counters"} 1` with no metrics**
— the collector reads *named* nftables counters and `fw4` creates none.

**Wi-Fi metrics missing** — they are `wifi_network_*` and `wifi_station_*`, not
`node_wifi_*`.

**Swap panels empty** — routers have no swap. Honest zero.

**`/` missing from filesystem metrics** — on OpenWrt the root is an overlayfs
the exporter does not publish. The writable filesystem is `/overlay`.
