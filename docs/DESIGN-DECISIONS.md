# Design decisions

Notes on a few choices the project spec explicitly asked to be documented,
rather than silently included or silently dropped.

## TAP / bridged mode: excluded from v1.0.0

Routed **TUN** mode is the only mode this project supports. TAP/bridged mode
was deliberately left out.

Why: TAP requires a working host-side bridge (`brctl`/`ip link` bridge setup
that varies by cloud provider and network setup, and often doesn't work at
all on typical cloud VPS NAT'd/virtual networking), most modern OpenVPN
clients (notably OpenVPN Connect on iOS/Android, and increasingly desktop)
don't support or need TAP, and a bridge that's misconfigured is a much
messier thing to detect, repair, or cleanly uninstall than a routed TUN
device. Given the choice between "support TAP, but unreliably, with a
support burden that scales with every cloud provider's networking quirks"
and "leave it out, document why," the latter is more honest and more
reliable for a public installer aimed at a general audience. If there's
real demand for it later, it belongs behind an explicitly-labeled Advanced
option with its own testing, not bundled into v1.0.0.

## tls-crypt, not tls-crypt-v2

The control channel is protected with `tls-crypt` (a pre-shared key applied
to all TLS handshake packets, hiding them from unauthenticated network
observers and adding DoS resistance) rather than `tls-crypt-v2`.

`tls-crypt-v2` gives each client its own wrapped key instead of one key
shared by the whole server, which mainly matters at a scale where you want
to revoke a client's ability to even attempt a handshake without touching
everyone else's key. For a self-hosted single-admin server, that additional
per-client wrapped-key machinery adds real complexity (client-specific
key generation and a second key format in every exported profile) for a
property (`tls-crypt` already means an unauthenticated packet is dropped
before you ever process it) that already meaningfully protects the control
channel. Per the project's own instruction not to add complexity "merely
for a checkbox," `tls-crypt` was kept as the one well-tested default rather
than shipping two overlapping mechanisms.

## Data Channel Offload (DCO): auto, never forced

Neither the installer nor the generated server config force DCO on or off.
OpenVPN 2.7 detects and uses the `ovpn-dco` kernel module automatically
when it's present and compatible; when it isn't (older kernels, kernels
without the module, or — as found during testing — build toolchains where
`libnl-genl` is too old to compile DCO support at all), OpenVPN runs
correctly without it, just without kernel-level offload. `ovpn diagnostics`
reports whether DCO is available so you know which mode you're in; it's a
performance detail, not something that should ever block a working install.

## Why the official OpenVPN apt repository first, then a verified source build

`apt install openvpn` on Ubuntu often resolves to a build that's years
behind current stable (see the version table gathered in
`config/upstream.conf` — Ubuntu 18.04/20.04's own archives top out well
short of the current 2.7.x line). The official OpenVPN apt repository
(`build.openvpn.net`) carries current 2.7.x builds for some codenames
(verified at time of writing: jammy, noble, resolute) and is used there,
signed and verified. Where it doesn't have a current 2.7.x build, the
installer builds the exact pinned release from verified upstream source
(checksum + GPG signature against the release-signing key) instead of
silently settling for whatever older version the distro happens to ship.

One further, empirically-discovered wrinkle: Ubuntu 18.04's system OpenSSL
cannot build OpenVPN 2.7.x at all (it's missing `SSL_get_peer_tmp_key`,
added in OpenSSL 1.1.1a — Ubuntu's 18.04 package only ever backports CVE
fixes into the original 1.1.1 base, never new API surface). Rather than
fail outright on an explicitly-still-supported OS, or patch upstream
OpenVPN source, or replace the system OpenSSL (a "broad system change"
this project's scope explicitly avoids), the installer falls back one more
step on that specific, verified case: it installs the newest OpenVPN the
official apt repository actually has for that codename (2.6.x — still an
authentic, officially-signed release) with a clear warning explaining why.

## Per-listener /24 (or /64) subnet allocation

Every listener gets its own dedicated IPv4 `/24` (and, for dual-stack
listeners, its own `/64`), assigned in configured order starting at
`10.8.0.0/24`. This is what makes dual/multi-listener mode safe by
construction: two listeners can never hand out overlapping client IPs, so
there's no coordination needed between OpenVPN server processes that don't
otherwise know about each other. TUN devices are named `ovpnN` for the same
reason — it lets firewall/NAT rules match every VPN interface with one
wildcard (`ovpn+`) regardless of how many listeners are configured.
