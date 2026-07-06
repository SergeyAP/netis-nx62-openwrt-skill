# Linux host setup (adapted — verify each gate before the point of no return)

This mirrors the macOS flow. It is based on the reference project
`SevenMaxs/netis-nx62-flash-tools` (Debian/Ubuntu) and standard Linux tooling.
It was **not** independently verified in the session this skill came from, so
lean hard on the self-tests: a passing TFTP fetch and a real captured TFTP
request are your proof, not trust. All `sudo` prompts interactively — never put a
password in a script.

## 1. Packages (Debian/Ubuntu)

```sh
sudo apt update
sudo apt install -y openssh-client tftpd-hpa tftp-hpa tcpdump curl
```

Other distros: install the equivalents (`openssh`, `tftp-hpa`/`atftpd`,
`tcpdump`, `curl`).

## 2. Static IP, no gateway

Pick whichever your system uses.

NetworkManager (note: **no** `gw4`, so it never becomes the default route):

```sh
sudo nmcli con add type ethernet ifname <ethX> con-name nx62 ip4 192.168.1.254/24
sudo nmcli con up nx62
```

Or iproute2 directly (no gateway added):

```sh
sudo ip addr flush dev <ethX>
sudo ip addr add 192.168.1.254/24 dev <ethX>
sudo ip link set <ethX> up
```

Verify your default route is still your Wi-Fi/uplink and the router answers:

```sh
ip route get 1.1.1.1        # dev should be your Wi-Fi, not <ethX>
ping -c1 192.168.1.1
```

## 3. TFTP server

```sh
sudo mkdir -p /srv/tftp
sudo cp openwrt-<VER>-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb \
        /srv/tftp/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
sudo chmod 644 /srv/tftp/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
```

Configure `/etc/default/tftpd-hpa`:

```
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure"
```

```sh
sudo systemctl restart tftpd-hpa && sudo systemctl enable tftpd-hpa
```

## 4. Prove it serves (with blksize 1468)

```sh
curl --tftp-blksize 1468 -o /tmp/rc.itb \
  tftp://192.168.1.254/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
sha256sum /tmp/rc.itb     # must equal the recovery image's sha256
```

## 5. Firewall

Allow inbound UDP/69 (or the router's request never arrives):

```sh
sudo ufw allow 69/udp        # if you use ufw; otherwise open UDP/69 in your firewall
```

## 6. Packet-capture gate (Step 5D)

```sh
MYMAC=$(ip link show <ethX> | awk '/link\/ether/{print $2}')
sudo tcpdump -i <ethX> -n -c 10 -e "not ether src $MYMAC"
```

Good = router `ARP who-has 192.168.1.254` + `TFTP RRQ "...initramfs-recovery.itb"`
+ transfer. Link flapping ~every 30 s with no TFTP request = wrong LAN port; move
the cable (LAN4 is known-good) and re-watch.

## Notes

- The backup script `scripts/backup-mtd.sh` runs on Linux too (it uses `ssh`,
  `md5sum`, and stat). If your `stat` differs, the script auto-detects GNU vs BSD.
- `scp` to Dropbear may need the legacy protocol flag `-O`.
