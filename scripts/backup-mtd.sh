#!/usr/bin/env bash
#
# Stream-and-verify MTD backup for Netis NX62 / Netcore N60 Pro.
#
# Reads every MTD partition on the router and streams it over SSH straight to the
# host (so the router's RAM is never filled), then verifies each dump by comparing
# md5 computed ON THE ROUTER against md5 computed on the host. Any mismatch is a
# hard failure — do not flash until every partition matches.
#
# This script contains NO passwords. Use SSH key auth (recommended) or let SSH
# prompt you interactively. Never hardcode a password here.
#
# Usage:
#   backup-mtd.sh <user@router> <ssh_key_or_-> <output_dir>
# Examples:
#   backup-mtd.sh useradmin@192.168.1.1 ~/.ssh/nx62_key ~/nx62-backup
#   backup-mtd.sh useradmin@192.168.1.1 -            ~/nx62-backup   # '-' = no key, prompt
#
set -u

HOST="${1:?usage: backup-mtd.sh <user@router> <ssh_key|-> <output_dir>}"
KEYARG="${2:?missing ssh key path or '-'}"
OUTBASE="${3:?missing output dir}"

SSHOPT=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8)
[ "$KEYARG" != "-" ] && SSHOPT=(-i "$KEYARG" "${SSHOPT[@]}")

TS="$(date +%Y%m%d-%H%M%S)"
DIR="$OUTBASE/nx62-backup-$TS"
mkdir -p "$DIR" || { echo "cannot create $DIR"; exit 1; }
echo "Backup dir: $DIR"

# host-side helpers that differ between macOS (BSD) and Linux (GNU)
host_md5() { if command -v md5 >/dev/null 2>&1; then md5 -q "$1"; else md5sum "$1" | awk '{print $1}'; fi; }
host_size() { if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi; }

# capture metadata
ssh "${SSHOPT[@]}" "$HOST" 'cat /proc/mtd' > "$DIR/proc_mtd.txt" 2>/dev/null || { echo "SSH failed"; exit 1; }
ssh "${SSHOPT[@]}" "$HOST" 'cat /proc/partitions; echo; uname -a' > "$DIR/device_info.txt" 2>/dev/null
echo "Saved proc_mtd.txt and device_info.txt"
echo

SUMFILE="$DIR/checksums-md5.txt"; : > "$SUMFILE"
FAIL=0

# iterate over every mtdN listed in /proc/mtd
while read -r dev _ _ name; do
  case "$dev" in mtd*) ;; *) continue ;; esac
  dev="${dev%:}"
  name="$(printf '%s' "$name" | tr -d '"')"
  out="$DIR/${dev}_${name}.bin"
  echo "-> $dev ($name)"
  # NOTE: </dev/null on both ssh calls is REQUIRED. This loop reads its stdin
  # from proc_mtd.txt (see `done < ...` below); without </dev/null each ssh
  # would consume that list as its own stdin, so only mtd0 gets backed up.
  rmd5="$(ssh "${SSHOPT[@]}" "$HOST" "md5sum /dev/$dev" </dev/null 2>/dev/null | awk '{print $1}')"
  ssh "${SSHOPT[@]}" "$HOST" "cat /dev/$dev" </dev/null > "$out" 2>/dev/null
  lmd5="$(host_md5 "$out")"
  size="$(host_size "$out")"
  if [ -n "$rmd5" ] && [ "$rmd5" = "$lmd5" ]; then
    echo "   ok  md5=$lmd5  size=$size"
    echo "$lmd5  ${dev}_${name}.bin" >> "$SUMFILE"
  else
    echo "   FAIL  router=$rmd5  host=$lmd5  -- re-run this partition!"
    FAIL=$((FAIL+1))
  fi
done < "$DIR/proc_mtd.txt"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "All partitions backed up and verified. Copy $DIR somewhere off this host."
else
  echo "$FAIL partition(s) FAILED verification. Do NOT proceed to flashing."
  exit 1
fi
