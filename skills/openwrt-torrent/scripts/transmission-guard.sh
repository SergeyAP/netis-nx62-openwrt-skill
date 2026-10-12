#!/bin/sh
# transmission-guard.sh — run transmission only while the USB drive is mounted.
# Install to /usr/bin/, then in /etc/crontabs/root:
#     * * * * * /usr/bin/transmission-guard.sh
# and disable the service's own autostart: /etc/init.d/transmission disable
#
# WHY CRON AND NOT HOTPLUG
# OpenWrt runs hotplug handlers serially in one queue shared with network
# interface events. A handler that hangs — a slow umount, a failing drive —
# stalls netifd with it, and you lose the WAN because of a USB stick. This
# costs up to 60 s of latency and cannot take anything else down.
#
# WHY THE MOUNT CHECK IS NOT PARANOIA
# transmission's init script does `mkdir -p "$download_dir"` before starting.
# If /mnt/usb is an ordinary empty directory because the drive is absent, that
# lands in internal flash and the daemon downloads into the router's NAND.
#
# DEVICE NAMES ARE NOT STABLE. After a hot-unplug the old name may still be
# held and the same drive returns as sdb. Look it up by UUID.
#
# NTFS goes dirty on hot-unplug and ntfs3 refuses to mount it; ntfsfix clears
# that. The marker file stops us retrying the repair every single minute.

MP=/mnt/usb
UUID=CHANGE-ME                       # blkid / block info on the drive
LOCK=/tmp/transmission-guard.lock
FIXED=/tmp/transmission-guard.fixfail

[ -f "$LOCK" ] && exit 0
touch "$LOCK"; trap 'rm -f "$LOCK"' EXIT

finddev() { block info 2>/dev/null | grep "UUID=\"$UUID\"" | cut -d: -f1; }
mounted() { grep -q " $MP " /proc/mounts; }
running() { /etc/init.d/transmission running >/dev/null 2>&1; }

DEV=$(finddev)

# drive gone but the mount point is still listed: hot-unplug
if mounted && [ -z "$DEV" ]; then
	running && {
		logger -t transmission-guard "drive gone - stopping transmission"
		/etc/init.d/transmission stop
	}
	logger -t transmission-guard "detaching stale mount point"
	umount -l "$MP" 2>/dev/null
fi

# drive present but not mounted: mount it, repairing NTFS once if needed
if [ -n "$DEV" ] && ! mounted; then
	block mount 2>/dev/null
	if ! mounted; then
		logger -t transmission-guard "$DEV will not mount, trying ntfsfix"
		ntfsfix -d "$DEV" >/dev/null 2>&1
		block mount 2>/dev/null
		if mounted; then
			rm -f "$FIXED"
			logger -t transmission-guard "$DEV mounted after ntfsfix"
		elif [ ! -f "$FIXED" ]; then
			touch "$FIXED"
			logger -t transmission-guard "cannot mount $DEV, needs manual attention"
		fi
	else
		rm -f "$FIXED"
	fi
fi

# match the daemon to the state of the drive
if mounted; then
	running || {
		logger -t transmission-guard "drive present - starting transmission"
		/etc/init.d/transmission start
	}
else
	running && {
		logger -t transmission-guard "no drive - stopping transmission"
		/etc/init.d/transmission stop
	}
fi
