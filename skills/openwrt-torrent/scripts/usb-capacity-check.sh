#!/bin/sh
# usb-capacity-check.sh — is the drive's reported capacity real?
#
# DESTRUCTIVE. Writes markers directly to the raw device. Use on an empty drive.
#
# Counterfeit drives report a large size, accept writes past their real
# capacity, RETURN SUCCESS, and discard the data. The kernel logs nothing. You
# discover it when files come back empty, possibly months later.
#
# Usage: usb-capacity-check.sh /dev/sda

DEV=${1:?usage: usb-capacity-check.sh /dev/sdX}
[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device"; exit 1; }

grep -q "^$(basename $DEV)" /proc/mounts && \
	{ echo "ERROR: $DEV appears mounted — unmount first"; exit 1; }

SECTORS=$(cat /sys/block/$(basename $DEV)/size)
TOTAL_MIB=$(( SECTORS / 2048 ))
echo "Device reports: $TOTAL_MIB MiB ($(awk -v s=$SECTORS 'BEGIN{printf "%.2f GiB", s*512/1073741824}'))"
echo "WARNING: this overwrites data on $DEV. Ctrl-C now if that is not intended."
echo
sleep 5

mark() { printf 'MARKER-AT-%08d-MIB-END' "$1"; }

probe() {
	off=$1
	mark $off | dd of="$DEV" bs=1M seek=$off count=1 conv=notrunc oflag=direct 2>/dev/null || return 1
	sync
	got=$(dd if="$DEV" bs=1M skip=$off count=1 iflag=direct 2>/dev/null | head -c 26 | tr -d '\000')
	[ "$got" = "$(mark $off)" ]
}

echo "--- coarse sweep ---"
LAST_OK=-1
FIRST_BAD=-1
for frac in 0 8 25 50 75 99; do
	off=$(( TOTAL_MIB * frac / 100 ))
	[ $off -ge $TOTAL_MIB ] && off=$(( TOTAL_MIB - 2 ))
	if probe $off; then
		printf "  %8d MiB (%2d%%): OK\n" "$off" "$frac"
		LAST_OK=$off
	else
		printf "  %8d MiB (%2d%%): LOST\n" "$off" "$frac"
		[ $FIRST_BAD -lt 0 ] && FIRST_BAD=$off
	fi
done

echo
if [ $FIRST_BAD -lt 0 ]; then
	echo "VERDICT: capacity looks genuine — data survives across the whole device."
	exit 0
fi

echo "--- binary search for the real boundary ---"
lo=$LAST_OK; hi=$FIRST_BAD
[ $lo -lt 0 ] && lo=0
while [ $(( hi - lo )) -gt 1 ]; do
	mid=$(( (lo + hi) / 2 ))
	if probe $mid; then lo=$mid; else hi=$mid; fi
	printf "  narrowed to %d..%d MiB\n" "$lo" "$hi"
done

echo
echo "VERDICT: COUNTERFEIT."
echo "  reported:      $TOTAL_MIB MiB"
echo "  actually holds: about $lo MiB"
echo "  overstated by:  $(awk -v t=$TOTAL_MIB -v r=$lo 'BEGIN{printf "%.0fx", t/(r>0?r:1)}')"
echo
echo "Reformatting will not fix this — the fault is in the controller's"
echo "firmware. Return it. Writing anything you care about to this drive"
echo "will lose it silently."
exit 1
