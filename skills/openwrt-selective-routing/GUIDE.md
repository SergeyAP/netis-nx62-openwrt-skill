# Quick Guide — only blocked services through the tunnel (Podkop)

Condensed checklist. Read `SKILL.md` for the reasoning behind each item.

## What you need

- OpenWrt 24.10 or newer, ~25 MB free on the overlay, ~50 MB of free RAM.
- A working tunnel interface from `openwrt-vpn-client` — proven to carry data, and
  routing **nothing** by default (no policy rules, no default route of its own).
- A way back in that does not depend on the change you are making (`openwrt-remote-access`).

## Order of operations

1. `ip route get 8.8.8.8` on the router must say WAN. If it says the tunnel, remove
   the all-traffic routing first.
2. Add `lan → wan` forwarding; keep the VPN zone with masquerade.
3. `apk add sing-box curl jq kmod-nft-tproxy coreutils-base64 bind-dig`.
4. Download the three Podkop `.apk` files from the release, check their sha256 against
   the release digests, `apk add --allow-untrusted` them. Ignore the first
   `Outbound section not found` — the config is still empty.
5. `uci`: `connection_type vpn`, `interface <VPN_IF>`, lists `russia_inside`,
   `telegram`, `meta`, `google_ai`, own domains for what the lists miss. Restart.
6. Check: `sing-box` running, `PodkopTable` in nft, `ip rule` 105.
7. `apk add kmod-veth` and run `scripts/test-client.sh`: listed names → `198.18.x`
   and the tunnel's counter moves; unlisted names → real addresses, counter still.
8. Reboot and run step 7 again.
9. Turn off Private DNS / secure DNS on the household's phones and browsers.

## The four things people get wrong

- **Testing from the router.** Podkop only handles traffic arriving on `br-lan`;
  the router's own requests always go direct. Use the test client.
- **Leaving the all-traffic routing in place.** Then everything already goes through
  the tunnel and Podkop has nothing to decide — including the banks.
- **Telegram by domain only.** The apps connect to server IPs; add the `telegram`
  subnet list, and `meta` for WhatsApp.
- **Phones with their own DNS.** They never ask the router, so blocked sites go direct
  and fail — on the phone only, which makes it look random.
