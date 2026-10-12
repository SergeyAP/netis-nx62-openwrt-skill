#!/bin/sh
# usb-bench.sh — profile a USB drive for torrent-shaped load.
# Usage: usb-bench.sh [mountpoint]        default /mnt/usb
#
# Torrents are sustained RANDOM writes in small blocks from many connections at
# once. Sequential throughput says little; test 4 is the one that matters, and
# in test 4 the SECOND figure matters — the first still rides the controller's
# cache.
#
# Every write uses oflag=direct. Without it busybox dd returns as soon as the
# data is in the page cache and you end up timing RAM: results swing 15-50x
# between runs. Each test is also cross-checked against /proc/diskstats, which
# counts what the kernel actually issued to the device.
#
# Run it two or three times. On a cheap controller the spread between runs is
# itself the verdict.

MP=${1:-/mnt/usb}
DIR="$MP/.bench"

grep -q " $MP " /proc/mounts || { echo "ERROR: $MP is not mounted"; exit 1; }

DEV=$(grep " $MP " /proc/mounts | awk '{print $1}')
BASE=$(basename "$DEV" | sed 's/[0-9]*$//')
FS=$(grep " $MP " /proc/mounts | awk '{print $3}')

now()   { awk '{printf "%d", $1*100}' /proc/uptime; }
dstat() { awk -v d="$BASE" '$3==d {print $8" "$11}' /proc/diskstats; }
ms()    { awk -v d=$1 -v n=$2 'BEGIN{printf "%.1f", d*10/n}'; }
iops()  { awk -v n=$1 -v d=$2 'BEGIN{printf "%.1f", n*100/d}'; }

T0=0; W0=0; M0=0
tstart() { sync; S=$(dstat); W0=${S% *}; M0=${S#* }; T0=$(now); }
tend() {
	sync
	D=$(( $(now) - T0 )); [ $D -eq 0 ] && D=1
	S=$(dstat); DW=$(( ${S% *} - W0 )); DM=$(( ${S#* } - M0 ))
	printf "  time %s.%02ds" $((D/100)) $((D%100))
	[ -n "$1" ] && printf ", %s MB/s" "$(awk -v m=$1 -v d=$D 'BEGIN{printf "%.2f", m*100/d}')"
	printf "\n"
	[ "$DW" -gt 0 ] && printf "  kernel: %s writes, %s ms each\n" "$DW" \
		"$(awk -v m=$DM -v w=$DW 'BEGIN{printf "%.1f", m/w}')"
}

mkdir -p "$DIR" || exit 1
trap 'rm -f "$DIR"/many/* "$DIR"/* 2>/dev/null; rmdir "$DIR"/many "$DIR" 2>/dev/null' EXIT

echo "=============================================================="
echo " $DEV -> $MP ($FS)     $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo
echo "--- USB descriptor ---"
for d in /sys/bus/usb/devices/*-*; do
	[ -e "$d/idVendor" ] || continue
	printf "  %-20s %s:%s\n" "VID:PID"       "$(cat $d/idVendor)" "$(cat $d/idProduct)"
	printf "  %-20s %s\n"    "vendor"        "$(cat $d/manufacturer 2>/dev/null || echo '(none reported)')"
	printf "  %-20s %s\n"    "model"         "$(cat $d/product 2>/dev/null)"
	printf "  %-20s %s\n"    "serial"        "$(cat $d/serial 2>/dev/null)"
	printf "  %-20s %s\n"    "USB version"   "$(cat $d/version 2>/dev/null | tr -d ' ')"
	printf "  %-20s %s Mbit/s\n" "link speed" "$(cat $d/speed 2>/dev/null)"
	printf "  %-20s %s\n"    "current draw"  "$(cat $d/bMaxPower 2>/dev/null)"
done
echo
echo "--- block device ---"
Q=/sys/block/$BASE/queue
printf "  %-20s %s\n" "size"        "$(awk -v s=$(cat /sys/block/$BASE/size) 'BEGIN{printf "%.1f GiB", s*512/1073741824}')"
printf "  %-20s %s / %s\n" "sector log/phys" "$(cat $Q/logical_block_size)" "$(cat $Q/physical_block_size)"
printf "  %-20s %s\n" "scheduler"   "$(cat $Q/scheduler)"
printf "  %-20s %s\n" "queue depth" "$(cat /sys/block/$BASE/device/queue_depth 2>/dev/null || echo '1 (BOT, no UASP)')"
printf "  %-20s %s\n" "free"        "$(df -h $MP | tail -1 | awk '{print $4" of "$2}')"
echo

echo "--- TEST 1: sequential write, 128 MB in 1 MB blocks ---"
tstart; dd if=/dev/zero of="$DIR/seq" bs=1M count=128 oflag=direct 2>/dev/null; tend 128
echo

echo "--- TEST 2: sequential read, 128 MB ---"
tstart; dd if="$DIR/seq" of=/dev/null bs=1M iflag=direct 2>/dev/null
D=$(( $(now) - T0 )); [ $D -eq 0 ] && D=1
printf "  time %s.%02ds, %s MB/s\n" $((D/100)) $((D%100)) "$(awk -v d=$D 'BEGIN{printf "%.2f", 128*100/d}')"
echo

echo "--- TEST 3: 8 MB in 4 KB blocks, sequential ---"
tstart; dd if=/dev/zero of="$DIR/small" bs=4k count=2048 oflag=direct 2>/dev/null; tend 8
echo

echo "--- TEST 4: RANDOM 4 KB writes, 500 ops  <<< THE ONE THAT MATTERS ---"
dd if=/dev/zero of="$DIR/rand" bs=1M count=64 oflag=direct 2>/dev/null; sync
randwrite() {
	i=$1
	while [ $i -lt $2 ]; do
		off=$(( (i * 7919) % 16384 ))
		dd if=/dev/zero of="$DIR/rand" bs=4k seek=$off count=1 conv=notrunc oflag=direct 2>/dev/null
		i=$((i+1))
	done
}
TA=$(now); randwrite 0 100;   TB=$(now)
randwrite 100 400
TC=$(now); randwrite 400 500; TD=$(now)
DA=$((TB-TA)); [ $DA -eq 0 ] && DA=1
DB=$((TD-TC)); [ $DB -eq 0 ] && DB=1
echo "  first 100 ops, controller cache still free:"
printf "     %s ms/op, %s IOPS\n" "$(ms $DA 100)" "$(iops 100 $DA)"
echo "  last 100 of 500, sustained  <<< COMPARE THIS ONE"
printf "     %s ms/op, %s IOPS\n" "$(ms $DB 100)" "$(iops 100 $DB)"
printf "  degradation once the cache is spent: %sx\n" "$(awk -v a=$DA -v b=$DB 'BEGIN{printf "%.1f", b/a}')"
echo

echo "--- TEST 5: one hundred 64 KB files ---"
mkdir -p "$DIR/many"
tstart
i=0
while [ $i -lt 100 ]; do
	dd if=/dev/zero of="$DIR/many/f$i" bs=64k count=1 oflag=direct 2>/dev/null
	i=$((i+1))
done
tend
D=$(( $(now) - T0 )); [ $D -eq 0 ] && D=1
printf "  %s files/s\n" "$(iops 100 $D)"
echo

echo "=============================================================="
echo " Reference — sustained random write (test 4, second figure)"
echo "   SSD over USB      0.1 - 1 ms      IOPS 1000+"
echo "   good flash drive    5 - 20 ms     IOPS 50-200"
echo "   weak flash drive   50 - 200 ms    IOPS 5-20    won't run torrents"
echo
echo " Run this 2-3 times. A large spread between runs is itself a verdict:"
echo " a good drive is consistent, a cheap controller is not."
echo "=============================================================="
