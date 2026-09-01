# Quick checklist — Transmission on OpenWrt with USB storage

Full explanation in [`SKILL.md`](SKILL.md).

## Do this first, before any configuration

```sh
# 1. is the capacity real?  DESTRUCTIVE, run on an empty drive
./scripts/usb-capacity-check.sh /dev/sda

# 2. is it fast enough?  run 2-3 times, compare
./scripts/usb-bench.sh /mnt/usb
```

Look at test 4's **second** figure — sustained random write:

```
                     won't do     tolerable    good
random write 4K       > 20 ms     5-20 ms      < 5 ms
IOPS                   < 50       50-200       > 200
spread between runs  several x    tens of %    a few %
```

A large spread between runs is itself a verdict. Cheap controllers pause for
garbage collection whenever they like; good drives are consistent.

## Storage

```sh
apk add kmod-usb-storage kmod-usb-storage-uas block-mount \
        kmod-fs-ntfs3 kmod-nls-utf8

mkntfs -f -c 65536 -L DATA /dev/sda1                                # 64K cluster
printf '\007' | dd of=/dev/sda bs=1 seek=450 count=1 conv=notrunc   # MBR type 0x07
```

fstab entry — by UUID, `iocharset=utf8`, explicit `ntfs3`:

```
config mount
	option uuid    '<UUID>'
	option target  '/mnt/usb'
	option fstype  'ntfs3'
	option options 'rw,noatime,umask=0000,iocharset=utf8'
	option enabled '1'
```

## Transmission

```sh
apk add transmission-daemon transmission-web luci-app-transmission
/etc/init.d/transmission disable          # the guard starts it, not procd
```

Settings that matter:

```
preallocation           0     ← on ntfs3 it writes real zeros; 30 GB torrent
                                = an hour of 100% iowait before any download
cache_size_mb           64    ← default 2; turns small peer writes into big ones
config_dir              /mnt/usb/torrents/config
download_dir            /mnt/usb/torrents/complete
incomplete_dir          /mnt/usb/torrents/incomplete
watch_dir               /mnt/usb/torrents/watch
port_forwarding_enabled false
```

Guard — set `UUID` inside it first:

```sh
cp scripts/transmission-guard.sh /usr/bin/ && chmod +x /usr/bin/transmission-guard.sh
echo '* * * * * /usr/bin/transmission-guard.sh' >> /etc/crontabs/root
/etc/init.d/cron restart
```

## Checklist

```
[ ] capacity verified across the whole device
[ ] benchmark run 2-3 times, sustained figure and spread both acceptable
[ ] mounted by UUID with iocharset=utf8
[ ] transmission autostart disabled, guard in cron
[ ] preallocation = 0, cache_size_mb = 64
[ ] watch_dir created, daemon restarted afterwards
[ ] guard + crontab in /etc/sysupgrade.conf
[ ] UUID updated in BOTH fstab and the guard after any reformat
```
