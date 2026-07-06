# Windows host setup (adapted — verify each gate before the point of no return)

Two viable routes. **WSL2 is recommended** because it reuses the verified
Linux flow; native Windows works too but needs third-party tools. Nothing here
uses a stored password. This path was **not** independently verified — trust the
self-tests (a passing TFTP fetch and a real captured TFTP request), not luck.

## Option A (recommended): WSL2 + a native TFTP server

The reliability catch on Windows is the network stack, so split the roles:

- Do **SSH/scp and packet inspection** from WSL2 (Ubuntu) — follow
  `host-linux.md` for `ssh`, `scp`, the backup script, and `tcpdump`.
- Run the **TFTP server as a native Windows app** (tftpd64) bound to the
  Ethernet adapter, because WSL2's NAT makes it awkward to serve UDP/69 to
  physical hardware.

### Static IP, no gateway (native Windows, PowerShell as Administrator)

```powershell
# find the adapter name (e.g. "Ethernet 2")
Get-NetAdapter
New-NetIPAddress -InterfaceAlias "Ethernet 2" -IPAddress 192.168.1.254 -PrefixLength 24
# deliberately do NOT set -DefaultGateway, so this NIC can't take the default route
```

Leave your Wi-Fi as the default route. Confirm:

```powershell
Find-NetRoute -RemoteIPAddress 1.1.1.1     # InterfaceAlias should be your Wi-Fi
ping 192.168.1.1
```

### TFTP server (tftpd64, https://pjo2.github.io/tftpd64/)

1. Put the recovery image, renamed **without version**, in a folder:
   `openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb`
2. In tftpd64: set *Current Directory* to that folder, *Server interfaces* to the
   `192.168.1.254` adapter, enable the **TFTP Server** service.
3. In tftpd64 settings, make sure **block size negotiation is allowed** (the
   router asks for `blksize 1468`).

### Firewall

Allow inbound **UDP/69** for tftpd64 (Windows Defender Firewall → Inbound Rules),
or temporarily disable the firewall on that adapter.

### Prove it serves

From WSL2 (has `curl`):

```sh
curl --tftp-blksize 1468 -o /tmp/rc.itb \
  tftp://192.168.1.254/openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb
sha256sum /tmp/rc.itb
```

## Option B: fully native Windows

- SSH/scp: use the built-in OpenSSH client (`ssh`, `scp -O`) in PowerShell.
- TFTP server: tftpd64 as above.
- Packet capture: **Wireshark**. Capture on the Ethernet adapter with display
  filter `tftp || arp`.

## Packet-capture gate (Step 5D) with Wireshark

After you erase UBI and reboot the router, watch the capture:

- **Good:** the router (a `88:bd:...`-style MediaTek MAC) sends
  `ARP who-has 192.168.1.254` and a TFTP **Read Request** for
  `openwrt-mediatek-filogic-netcore_n60-pro-initramfs-recovery.itb`, then Data/ACK
  packets flow.
- **Bad:** the adapter link goes up/down roughly every ~30 s and Wireshark shows
  no TFTP request from the router. That means U-Boot recovery is on a **different
  LAN port** — move the cable (LAN4 is known-good when LAN1 wasn't) and watch
  again. Fallback: power off, hold `RESET`, power on, hold ~10 s.

## Notes

- tftpd64's log window also shows the incoming RRQ and transfer progress — a handy
  second confirmation that the router reached your server.
- If native Windows TFTP is flaky against the router, switch the TFTP role to a
  Linux/macOS box or a WSL2-adjacent setup; the flashing commands on the router
  are identical regardless of host OS.
