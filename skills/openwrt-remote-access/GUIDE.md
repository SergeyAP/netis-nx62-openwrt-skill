# Quick Guide — reaching a router with no public address

Condensed checklist. Read `SKILL.md` for the reasoning behind each item.

## What you need

- For the WireGuard path: a hub you control (any VPS running WireGuard) and its
  public key.
- For the reverse SSH path: any host with a public address and an SSH account you
  can add a key to. Nothing else — no ports opened at the router's side, no
  cooperation from the ISP.
- On the router: nothing extra for the SSH path (dropbear is already there);
  `kmod-wireguard wireguard-tools luci-proto-wireguard` for the other.

## Order of operations

1. Decide the transports. Two that terminate on **different** machines is the
   point; one is a single point of failure.
2. WireGuard: generate the key, register it on the hub, create the interface with
   `nohostroute='1'` if the router already routes through a VPN, add a firewall
   zone that accepts input on it, restart netifd.
3. Reverse SSH: generate `id_tunnel` with `dropbearkey`, put the public key on
   the far host with `restrict,port-forwarding,command="/bin/false"`, seed
   `/root/.ssh/known_hosts` with `ssh-keyscan`.
4. Install `scripts/reverse-tunnel.init` as `/etc/init.d/reverse-tunnel`; keep
   `HOME=/root` in it.
5. Tune sshd on the far host: `ClientAliveInterval 30`, `ClientAliveCountMax 3`.
6. Install `scripts/tunnel-watchdog.sh` and its cron line — unless you chose
   autossh, which handles that failure itself.
7. Add a `Host` block on your laptop with `ProxyJump` and `HostKeyAlias`.
8. Test **both** paths from outside the network, on the same day.

## The four things people get wrong

- **Assuming procd covers it.** dbclient survives a refused forward, so the
  process stays healthy while the tunnel is dead. Watchdog, or autossh.
- **Skipping `HostKeyAlias`.** The second tunnel you build will collide with the
  first in `known_hosts`, and the error will not mention either.
- **Forgetting `HOME=/root`** in the init script — restart loop with a host-key
  error that looks like a key problem and is not.
- **Only ever testing from inside the house.** Both paths exist precisely for the
  case you are not there; test them from where you will actually need them.
