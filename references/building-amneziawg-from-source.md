# Building AmneziaWG packages for OpenWrt yourself

Written 2026-09-20 from a real attempt on OpenWrt 25.12.5, `mediatek/filogic`,
Netcore N60 Pro. **The build works.** `kmod-amneziawg` 3.1.20260906 compiles
cleanly against kernel 6.12.94 — the earlier conclusion that 3.1 was incompatible
with that kernel was wrong, and is corrected below. The single thing that blocked
it was the host: on Apple Silicon the cross compiler crashes.

Read the two traps first — the host and the silent compiler — because every other
symptom in this file is downstream of them.

## When you need this at all

Most people never do: `apk add kmod-amneziawg amneziawg-tools luci-proto-amneziawg`
is the whole story. Two situations break that.

**The package disappears from the feed.** On 25.12.5 the three packages were in the
official `base` feed and then were withdrawn. A router flashed earlier still has
them installed; a router flashed later cannot find them at all, from the identical
feed list. Check with `apk add --simulate amneziawg-tools` — if it says
`no such package` while `wireguard-tools` resolves, the feed is fine and the
package is simply gone.

**The feed version is older than your provider's config.** This is the sharper
one. AmneziaWG has two generations and the OpenWrt feed shipped the first:

| Parameter | in `awg` 1.0.2026xxxx | in your provider's `.conf`? |
|---|---|---|
| `Jc`, `Jmin`, `Jmax` | yes | usually |
| `S1`, `S2`, `S3`, `S4` | yes | usually |
| `H1`–`H4`, `I1`–`I5` | yes | sometimes |
| `HeaderProtectionKey` | **no** | 2.0 configs, yes |
| `ContentPaddingAddition` | **no** | 2.0 configs, yes |
| `RekeyAfterTime`, `RejectAfterTime` | **no** | 2.0 configs, yes |
| `KeepaliveTimeout`, `MaxHandshakeAttempts` | **no** | 2.0 configs, yes |

Read the supported set off the binary itself, never off a wiki:

```sh
awg set --help
```

If your config has keys that are not in that usage string, the tunnel will fail in
the most confusing way available: `wg show` lists the peer, your side sends, and
**no handshake ever appears** — no error, no log line. We watched 35 KiB go out
and 0 B come back for 70 seconds before concluding.

Source of truth for what the newer line supports (clone and grep, do not use
GitHub code search — it does not index these repos and returns 0 for terms that
demonstrably exist):

```sh
git clone --depth 1 --branch v3.1.20260812 https://github.com/amnezia-vpn/amneziawg-tools
git clone --depth 1 --branch v3.1.20260906 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module
grep -ril header_protection */src
```

Both 3.1 trees contain `HeaderProtectionKey`, `ContentPaddingAddition`,
`MaxHandshakeAttempts`, `RekeyAfterTime` and friends. So building is worthwhile —
it is the only way to get them.

## The trap that decides where you build

**There are two architectures in this problem and they are not the same one.**

The package runs on the router: `aarch64`. But the cross-compiler that produces it
is itself a program, and OpenWrt publishes the SDK built for exactly one host:

```
openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64.tar.zst
                                                       ^^^^^^^^^^^^
                                             what the compiler runs on
```

So a powerful ARM server does not help — it hurts. You are compiling *for* ARM
with an *Intel* tool. Check the published list before choosing a machine:

```sh
curl -s https://downloads.openwrt.org/releases/<VER>/targets/<TARGET>/ | grep -o 'openwrt-sdk-[^"]*'
```

Host options, measured rather than guessed:

| Host | Verdict |
|---|---|
| Apple Silicon mac | **does not work.** Rosetta 2 runs ordinary amd64 binaries fine, but the OpenWrt cross-compiler segfaults. See below — this cost an entire evening. |
| Intel mac | **works.** Native x86_64 in a Lima/Docker VM. Proven 2026-09-20. |
| ARM server, however large | needs `qemu-user-static` + binfmt registration; pure software emulation |
| Small VPS | 1 core and <1 GB RAM is not enough; do not bother |

### The Apple Silicon trap, in full

Under Rosetta the *host* toolchain in the SDK image works — `gcc --version` in the
container answers normally. The *cross* compiler does not:

```sh
$ aarch64-openwrt-linux-musl-gcc --version
            # no output at all, exit 0
$ aarch64-openwrt-linux-musl-gcc -c t.c -o t.o
            # no output, no t.o
```

The kernel build system notices only indirectly, and the message is easy to
misread as a version mismatch rather than a crash:

```
Segmentation fault (core dumped)      ← repeated, once per compiler invocation
warning: the compiler differs from the one used to build the kernel
  The kernel was built by: aarch64-openwrt-linux-musl-gcc … 14.3.0
  You are using:                      ← empty because the compiler died
```

**Make the compiler prove itself before anything else.** One line at the top of
the build script turns an evening of false leads into an immediate verdict:

```sh
"$GCC" --version >/dev/null 2>&1 || { echo "cross compiler does not run here"; exit 9; }
```

## The build, with every rake marked

Use the **official SDK image**, not a hand-assembled Debian. It has the toolchain
and the prerequisites already correct.

```sh
docker run --rm --platform linux/amd64 -v "$PWD":/work \
  openwrt/sdk:mediatek-filogic-25.12.5 bash /work/build.sh
```

Recipes: the official feed no longer carries them, but
[`Slava-Shchipunov/awg-openwrt`](https://github.com/Slava-Shchipunov/awg-openwrt)
does — `kmod-amneziawg/`, `amneziawg-tools/`, `luci-proto-amneziawg/`. Copy them
into `package/` and bump `PKG_VERSION` plus `PKG_SOURCE_VERSION` to the tag you
want. Its own releases are **not** a shortcut: the `v25.12.5` release exists and
matches your target exactly, but the packages inside are the same old 1.0 the feed
had. The "AMNEZIA WIREGUARD V2" banner in its release notes is decoration. Verify
by installing and reading `awg set --help`, which takes two minutes and saves an
evening.

### Rakes, in the order we hit them

**Do not unpack the SDK onto a macOS bind mount.** `tar` fails with
`Cannot open: Permission denied` on every symlink in the kernel tree. Unpack
inside the VM filesystem or a Docker volume; mount the host directory only for
recipes in and artefacts out.

**A hand-built Debian image needs packages the prereq check names one at a time.**
We lost two iterations to `python3-distutils` and then `swig`. The official SDK
image has them; that is the main reason to use it.

**`uboot-mediatek` runs its prerequisite check once per board variant.** Under
emulation that is ~20 s each and there are dozens. It has nothing to do with your
package. Delete the symlink before building:

```sh
rm -f package/feeds/base/uboot-mediatek
```

**`./scripts/feeds update -a` is memory-hungry and usually unnecessary.**
Collecting metadata across every feed killed a container with 3.9 GB. Neither
`kmod-amneziawg` nor `amneziawg-tools` needs an external feed — skip the step
entirely. (`luci-proto-amneziawg` does need `luci`; build it separately if you
want it, or copy the three small files from a router that has it.)

**Watch for more than one build container.** Two emulated builds on four cores
halve each other. `docker ps` before every retry.

**Do not hand-write a minimal `.config`.** An incomplete one makes the build drop
into interactive `menuconfig`, which has no TTY in a container and dies with an
opaque `Error 1`. Use plain `make defconfig` and accept that it will package a few
hundred unrelated kernel modules on the way — about 900 for this target.

**Build the kernel module first, not the tools.** `amneziawg-tools` depends on
`kmod-amneziawg`, so a kmod failure is reported as a *tools* failure:

```
make[2] -C package/awg/kmod-amneziawg compile
   ERROR: package/awg/kmod-amneziawg failed to build.
make: *** [.../amneziawg-tools/compile] Error 1
```

Reading that as "the tools are broken" costs you an iteration.

**Always pass `V=s`.** Without it OpenWrt tells you to re-run with it, which means
another full pass through those 900 packages. Put the SDK in a named Docker volume
so retries do not start from zero:

```sh
docker volume create awg-sdk
docker run ... -v awg-sdk:/build ...
```

## Skip the ~900 kmods: compile the module directly

`make package/awg/kmod-amneziawg/compile` first runs `package/kernel/linux/compile`,
which packages every kernel module the target has — about 900 of them. Under
emulation that was **two hours before the awg module was even attempted**. The
dependency is nearly pointless here, because the SDK image already ships a built
kernel (`Module.symvers` is dated with the image).

Invoke the package Makefile directly instead and the same failure reproduces in
about ninety seconds:

```sh
make -C package/awg/kmod-amneziawg compile TOPDIR=/builder V=s -j1
```

Two caveats. It needs `make defconfig` to have run at least once, or it stops with
`Missing kernel version/hash file for .` — that file is written by defconfig, which
is a second reason never to hand-write a `.config`. And the final `.apk` packaging
step still wants the full path, so use the direct form to *diagnose* and the normal
form to *produce*:

```sh
make package/awg/kmod-amneziawg/compile V=s -j1     # yields the .apk
```

## The kmod and the tools must be the same tag, and the kmod moves faster

This one only shows up after everything builds. `kmod-amneziawg` 3.1.**20260906** with
`amneziawg-tools` 3.1.**20260812** — the newest of each — produces an interface that
refuses its own config:

```
$ awg setconf awg0 /etc/amnezia/awg0.conf
Unable to modify interface: Invalid argument
```

Applying parameters one at a time on a throwaway interface (no peer, so the provider
is never contacted) shows exactly where the two disagree:

```
  ok       jc/jmin/jmax          ok       s1/s2      ok  s3/s4      ok  h1..h4
  REJECTED i1
  REJECTED content-padding-addition
  REJECTED rekey-after-time
```

Note the two different error texts: `Unable to modify interface: Invalid argument`
is the **kernel** refusing an attribute the tool sent, while `Invalid argument:
<name>` is the **tool** not knowing the option at all. They point at opposite ends.

The kernel-module repository tags more often than the tools repository, so "latest of
each" is a version skew, not a pair. As of 2026-09-20 the newest tools tag is
`v3.1.20260812`, and the kernel module has a matching `v3.1.20260812` — build that.

`amneziawg-go` does not care: it takes its configuration over the UAPI text socket,
which tolerates unknown keys, whereas the kernel module's netlink attributes are
strict. That tolerance is a second, quieter reason the userspace path came up first.

## The tools recipe pins a tag that does not exist in the 3.1 line

`amneziawg-tools` fails at download, long after the kmod succeeded:

```
error: pathspec 'v3.1.20260812-2' did not match any file(s) known to git
```

The recipe builds its tag as `v$(PKG_VERSION)-2` — the `-2` is a re-tag that exists
only in the 1.0 series. Set the tag explicitly and skip the mirror hash:

```make
PKG_SOURCE_VERSION:=v3.1.20260812
PKG_MIRROR_HASH:=skip
```

## Where it stands

Built and packaged on 2026-09-20, on an Intel mac in a Lima VM:

```
kmod-amneziawg-6.12.94.3.1.20260906-r1.apk
amneziawg.ko                                 ← against kernel 6.12.94
```

## You may not need the kernel module at all

`amneziawg-go` is a userspace implementation of the same protocol and carries the
whole 2.0 parameter set. It needs no kernel module, no SDK, no cross toolchain and
no emulation — one `go build`:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" .
```

3.2 MB, static, runs unchanged on OpenWrt's musl userland; it only needs
`kmod-tun`, which *is* still in the feed. Pair it with an `awg` binary built for
aarch64-musl — a native arm64 Alpine container does that in a minute, with
`build-base` **and `linux-headers`**, the second of which the error message does
not name:

```
curve25519.c:22:10: fatal error: linux/types.h: No such file or directory
```

Measured on a Netcore N60 Pro (MT7986A, four A53 cores) against a German host:
**29 Mbit/s with load average 0.02** — indistinguishable from the kernel module on
the same hardware, because the link, not the CPU, is the limit at that speed. Build
the kernel module when you need the last bit of throughput; reach for userspace when
you need a working tunnel today.

## Related

- `SKILL.md` — flashing the board in the first place
- `references/troubleshooting.md` — recovery, ports, brick paths
- The operational side of a flash (host preparation, gates, backups) is documented
  per-site; this file is only about producing packages the feed will not give you.
