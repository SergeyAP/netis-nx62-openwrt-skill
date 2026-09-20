# Getting AmneziaWG onto an OpenWrt router — which route to take

Written 2026-09-20 from a bring-up on OpenWrt 25.12.5, `mediatek/filogic`
(MT7986A, four Cortex-A53). This is the decision guide; the build itself, with
every rake marked, is in
[`building-amneziawg-from-source.md`](building-amneziawg-from-source.md).

The order below matters. Two of the three questions can be answered in under a
minute, and answering them first is the difference between an evening and a week.

---

## 1. Do you need AmneziaWG, or is WireGuard enough?

AmneziaWG is WireGuard plus obfuscation: junk packets, randomised handshake sizes,
rewritten packet headers. It exists because plain WireGuard has a recognisable
handshake that deep packet inspection can drop on sight.

If your provider handed you a `.conf` that contains `Jc`, `Jmin`, `Jmax`, `S1`,
`S2` or `H1`–`H4`, it is an AmneziaWG config and `wg` will not run it. If it
contains only the classic WireGuard keys, use `wireguard-tools` and stop reading.

## 2. Which generation does the config need?

**Read the parameter *names* out of your config. Never paste the file anywhere,
and you do not need to look at a single value to answer this:**

```sh
grep -oE '^[A-Za-z0-9]+[[:space:]]*=' provider.conf | tr -d ' =' | sort
```

Match the output against this table:

| Parameter | in `awg` 1.0 | meaning |
|---|---|---|
| `Jc`, `Jmin`, `Jmax` | yes | junk packets before the handshake |
| `S1`–`S4` | yes | junk prepended to handshake messages |
| `H1`–`H4` | yes | rewritten message-type headers |
| `I1`–`I5` | yes | tagged junk packets |
| `HeaderProtectionKey` | **no** | second generation |
| `ContentPaddingAddition` | **no** | second generation |
| `RekeyAfterTime`, `RekeyTimeout` | **no** | second generation |
| `RejectAfterTime`, `KeepaliveTimeout` | **no** | second generation |
| `MaxHandshakeAttempts` | **no** | second generation |

Anything from the lower half means you need the **3.x line**, and the OpenWrt feed
will not give it to you.

## 3. What does the router actually have?

Ask the binary, never a wiki or a release note:

```sh
awg set --help
```

If a parameter from your config is missing from that usage string, that build
cannot carry it. Also check whether the packages are installable at all — on
25.12.5 they were in the `base` feed and were later **withdrawn**, so a router
flashed earlier still has them while one flashed later cannot find them from the
identical feed list:

```sh
apk add --simulate amneziawg-tools     # "no such package"?
apk add --simulate wireguard-tools     # ...while this resolves = the feed is fine
```

## 4. Recognise the failure before you debug the wrong thing

A config with parameters the client does not implement fails in the most confusing
way available. There is **no error**. The peer is listed, your side sends, and:

```
peer: <key>
  endpoint: 203.0.113.10:51820
  transfer: 470.92 KiB sent, 0 B received      ← and no "latest handshake" line, ever
```

Tens of kilobytes leaving and nothing coming back, with no handshake line and
nothing in the log, is the signature of a **client too old for the config** — not
of a firewall, not of a NAT problem, not of a dead server. Before blaming the
network, prove the server answers by running the same config from any other
machine with a current client (see route B, which takes minutes).

## 5. The three routes

| Route | Use when | Cost | Needs |
|---|---|---|---|
| **A. feed packages** | the feed has them *and* your config is first-generation | `apk add`, two minutes | nothing |
| **B. userspace `amneziawg-go`** | you need 2.0 today, or you have no x86_64 Linux host | one `go build` | `kmod-tun` |
| **C. build the kernel module** | you want the lowest CPU, and you have a native x86_64 Linux host | an SDK build | matching tool/module tags |

B and C are not exclusive. Doing B first costs almost nothing and gives you a
working tunnel plus proof that the server and config are fine, which makes every
later failure in C unambiguous.

## 6. Route B — userspace, the short one

`amneziawg-go` implements the whole 2.0 parameter set and needs no kernel module,
no SDK, no cross toolchain and no emulation. Cross-compile it with nothing but Go:

```sh
git clone --depth 1 https://github.com/amnezia-vpn/amneziawg-go
cd amneziawg-go
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" .
```

About 3 MB, statically linked, runs unchanged on OpenWrt's musl userland.

You still need an `awg` binary to configure it. Build it for the router's libc in
a **native** Alpine container of the right architecture — no emulation, about a
minute:

```sh
git clone --depth 1 --branch <tag> https://github.com/amnezia-vpn/amneziawg-tools
docker run --rm --platform linux/arm64 -v "$PWD/amneziawg-tools":/src -w /src alpine sh -c '
  apk add --no-cache build-base linux-headers
  make -C src LDFLAGS="-static" -j4 && cp src/wg src/awg'
```

`linux-headers` is the one the error message does not name:

```
curve25519.c:22:10: fatal error: linux/types.h: No such file or directory
```

On the router, install `kmod-tun` (still in the feed), then bring the interface up
by hand. Keeping the peer's `AllowedIPs` while installing **no routes** is a safe
way to test: the handshake goes out over your normal default route, so you learn
whether the server answers without touching the box's routing at all.

```sh
awg-quick strip provider.conf > stripped.conf     # drops Address/DNS/MTU
amneziawg-go awg0
awg setconf awg0 stripped.conf
ip -4 addr add <Address> dev awg0
ip link set mtu 1412 up dev awg0
awg show awg0        # a "latest handshake" line within ~10 s means you are done
```

## 7. Route C — the kernel module

Worth it for CPU, not for speed. Measured on an MT7986A router, same file from the
same CDN, runs interleaved so link drift could not favour either:

| | median throughput | load average during transfer |
|---|---|---|
| kernel module | 60 Mbit/s | 0.65–0.75 |
| userspace | 66 Mbit/s | 1.10–1.64 |

Equal delivery; roughly half the CPU. On a four-core A53 at these speeds neither is
a constraint, so pick the kernel module when the box has other work to do, or when
your link is fast enough that a core becomes the limit.

Two things decide whether this route is even open to you:

**The host must be native x86_64 Linux.** The OpenWrt SDK is published for exactly
one host architecture, and on Apple Silicon the cross compiler **segfaults under
Rosetta** while ordinary amd64 binaries run fine — so the failure looks like a
source incompatibility rather than a broken host. Put this at the top of any build
script:

```sh
"$GCC" --version >/dev/null 2>&1 || { echo "cross compiler does not run on this host"; exit 9; }
```

**The module and the tools must be the same upstream tag.** The kernel-module
repository tags more often than the tools repository, so "newest of each" is a
version skew, not a pair, and it refuses its own config:

```
Unable to modify interface: Invalid argument
```

Check the tags of both before choosing, and pick the newest tag they share:

```sh
git ls-remote --tags --sort=-v:refname https://github.com/amnezia-vpn/amneziawg-tools
git ls-remote --tags --sort=-v:refname https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
```

The rest — recipes, the SDK image, and the shortcut that turns a two-hour iteration
into ninety seconds — is in
[`building-amneziawg-from-source.md`](building-amneziawg-from-source.md).

## 8. Lessons that generalise beyond AmneziaWG

**Ask the binary, not the documentation.** `awg set --help` settled in two seconds a
question that a release note answered wrongly: a third-party release advertising
"AMNEZIA WIREGUARD V2" shipped the old 1.0 packages.

**The help text can still lie.** That same usage string prints four options with
underscores (`rekey_timeout`, `reject_after_time`, `keepalive_timeout`,
`max_handshake_attempts`) that the parser only accepts with **dashes**. When an
option the help promises is rejected, try the other separator before concluding you
have a version problem.

**Read which end refused.** `Unable to modify interface: Invalid argument` is the
*kernel* rejecting an attribute the tool sent. `Invalid argument: <name>` is the
*tool* not knowing the option at all. They point at opposite fixes.

**Bisect configuration on a throwaway interface.** Applying parameters one at a time
to a second interface **with no peer** tells you exactly which one is refused, costs
nothing, contacts no server, and never disturbs a working tunnel.

**Do not restart a tunnel repeatedly while debugging.** Each restart is a burst of
handshake initiations; several inside a few minutes can get your address ignored by
the server for a while, which then looks exactly like the bug you were chasing.
Clients already retry on their own — wait instead of poking.

**Never benchmark a home uplink against one server.** A single test host capped
everything near 25 Mbit/s and produced a confident, wrong verdict that userspace was
25 % faster than the kernel module. Measured against the CDN the traffic actually
uses, both reached 60–70 and the difference vanished.

**GitHub code search returns 0 for these repositories.** Clone and grep. Searching
produced two wrong conclusions in one evening about parameters that demonstrably
exist in the source.

### OpenWrt-specific traps that cost time here

- **BusyBox has no `install`**, so copy scripts written on a desktop fail silently
  mid-way. Use `cp` + `chmod`.
- **`date +%N` returns nothing**, so any millisecond-resolution timing divides by
  zero. Time whole transfers with `date +%s`.
- **`scp` needs `-O`.** OpenWrt ships no `sftp-server`, so modern scp fails with
  `/usr/libexec/sftp-server: not found`.
- **`pgrep -f` matches the shell running your own command.** Checking for a daemon
  with a pattern you also typed on the command line will always find "it". Use
  `ps w | grep "[a]mneziawg-go"` or check for a socket instead.
- **Do not declare a hand-made tunnel interface in `/etc/config/network`.** Even
  `proto none` makes netifd take ownership and put the device *down* on the next
  config reload, taking its address and routes with it; the symptom is `Operation
  not permitted` on every send, which reads like a firewall block. Bind the firewall
  zone to the **device** instead.
- **Do not put a self-daemonising process under procd.** It inherits rc.common's
  service lock and holds it forever, after which every `stop` blocks on `flock` —
  and so does anything that calls `restart`, including your watchdog. Plain
  `start()`/`stop()` takes no such lock.
- **Start the tunnel late.** At a low `START=` value the service runs before the WAN
  lease and before any pinned route to the endpoint exists, so it comes up and never
  handshakes. Start after the network, and wait for a default route.
