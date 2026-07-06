# macOS host setup (verified end-to-end)

macOS ships everything you need: `ssh`, `scp`, a built-in `tftpd`, and `tcpdump`.
All `sudo` commands prompt for **your** password interactively — never type it
into a script.

## 1. Find the wired interface

```sh
networksetup -listallhardwareports        # look for your USB/Ethernet adapter, e.g. en7
ifconfig <enX> | grep -E "status|inet"     # status should become "active" with a cable
```

## 2. Static IP, no gateway (keeps internet on Wi-Fi)

Run this in **your own Terminal** (it prompts for your password). The empty `""`
router is the whole point — it means "no gateway", so this interface can't steal
your default route:

```sh
sudo networksetup -setmanual "USB 10/100/1000 LAN" 192.168.1.254 255.255.255.0 ""
```

Use the exact service name from `networksetup -listnetworkserviceorder`. Setting
manual config here also enables the service, so you do **not** need to click
"Activate" in System Settings (that would trigger DHCP and can drop your
internet). Verify:

```sh
ifconfig <enX> | grep "inet "                 # 192.168.1.254
route -n get default | grep interface          # should still be your Wi-Fi (en0)
ping -c1 192.168.1.1                            # router reachable
```

## 3. Built-in TFTP server

```sh
sudo mkdir -p /private/tftpboot
sudo cp openwrt-<VER>-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb \
        /private/tftpboot/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
sudo chmod 644 /private/tftpboot/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
sudo launchctl enable  system/com.apple.tftpd
sudo launchctl bootstrap system /System/Library/LaunchDaemons/tftp.plist
```

If `bootstrap` says "service already bootstrapped" or an I/O error, run
`enable` first (as above) then `bootstrap`, then
`sudo launchctl kickstart -k system/com.apple.tftpd`. Confirm it listens:

```sh
sudo lsof -nP -iUDP:69        # launchd should hold UDP *:69
```

## 4. Prove TFTP actually serves it (with the router's blksize)

Do this before you trust it. `curl` on macOS speaks TFTP:

```sh
curl --tftp-blksize 1468 -o /tmp/rc.itb \
  tftp://192.168.1.254/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
shasum -a 256 /tmp/rc.itb    # must equal the recovery image's sha256
```

## 5. Firewall

macOS application firewall is usually off. Confirm it isn't blocking inbound:

```sh
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate   # State = 0 is best
```

## 6. Packet-capture gate (Step 5D)

When you erase UBI and reboot, watch what the router does on the wire. Show only
frames **from** the router by excluding your own MAC:

```sh
MYMAC=$(ifconfig <enX> | awk '/ether/{print $2}')
sudo tcpdump -i <enX> -n -c 10 -e "not ether src $MYMAC"
```

Good = an `ARP who-has 192.168.1.254` and a `TFTP RRQ "...initramfs-recovery.itb"`
from the router, then a data transfer. If instead the link flaps every ~30 s and
you see no router TFTP request, move the cable to another LAN port (see the main
SKILL and `troubleshooting.md`).

## Cleanup (optional, after success)

```sh
sudo launchctl bootout system/com.apple.tftpd        # stop tftpd
# restore the wired interface to DHCP if you like:
sudo networksetup -setdhcp "USB 10/100/1000 LAN"
```
