# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [1.0.1] - 2026-10-20

### Fixed

- TCP listeners on privileged ports (e.g. TCP 443) failed to bind under
  systemd: the generated unit's `CapabilityBoundingSet` omitted
  `CAP_NET_BIND_SERVICE`, so OpenVPN could not open any port below 1024
  even when it was free. Confirmed on a production Ubuntu 24.04 dual
  UDP 1194 + TCP 443 install (UDP passed, TCP 443 failed repeatedly).
  `lib/systemd.sh` now grants `CAP_NET_BIND_SERVICE` alongside the
  existing hardened capability set. Existing installs get the corrected
  unit from `sudo ovpn repair` (and the next `sudo ovpn update`).
- Settings changes that removed a listener (`sudo ovpn settings`) left
  the old systemd instance enabled and running. Removed listeners are
  now stopped, disabled and have their generated config deleted
  (`systemd_sync_listeners` in `lib/systemd.sh`); listeners that are new
  or kept are (re-)enabled and restarted.
- The setup wizard and non-interactive installer now check whether a
  requested TCP/UDP port is already in use before configuring a
  listener on it (via `ss`, independently per protocol so e.g. TCP 443
  in use never blocks UDP 443). A port already held by one of our own
  listeners (e.g. during reconfiguration) is treated as reusable rather
  than a conflict; a port held by an unrelated process shows what's
  using it and prompts for another port interactively, or fails with a
  non-zero exit non-interactively.

### Changed

- OpenVPN upstream pin: 2.7.7 -> 2.7.8 (released 2026-10-07). Source
  tarball checksum independently recomputed and the GPG signature
  verified against the pinned release-signing key; see
  `config/upstream.conf`. This also stops the manager from warning that
  an apt-installed 2.7.8 engine "differs from pinned" on current Ubuntu
  releases.
- Reviewed removing the deprecated `persist-key` directive (OpenVPN 2.7+
  enables this behavior unconditionally and only logs a notice). Kept it
  in generated configs: the project's apt-repo fallback path for EOL
  Ubuntu releases can still install a pre-2.7 engine where the directive
  is not a no-op, and removing it there would silently change restart
  behavior. The 2.7+ deprecation notice is cosmetic log noise, not a bug.

## [1.0.0] - 2026-09-22

Initial public release.

### Added

- `install.sh`: one-line installer for Ubuntu 18.04–26.04+ (amd64/arm64),
  interactive via `/dev/tty` even when piped through `curl | sudo bash`.
- OpenVPN Community Edition 2.7.7 engine install via the official OpenVPN
  apt repository (jammy/noble/resolute), with a verified (checksum + GPG
  signature) source-build fallback for older releases.
- Easy-RSA 3.2.7 PKI: CA, server certificate, per-client certificates,
  revocation, CRL, and renewal, all checksum/signature-verified against
  pinned upstream releases.
- `ovpn` manager CLI/TUI (`/usr/local/bin/ovpn`): status, diagnostics, logs,
  client management, settings, backup/restore, update, repair, uninstall.
- Connection modes: UDP, TCP, dual UDP+TCP with automatic client-side
  transport fallback, and custom/advanced multi-listener mode.
- Full-tunnel and split-tunnel routing, IPv4-only and dual-stack IPv4/IPv6
  (with verified outbound IPv6 usability before offering it).
- Modern crypto defaults: AES-256-GCM/AES-128-GCM/ChaCha20-Poly1305,
  tls-crypt, TLS 1.2 minimum, EC certificates.
- Safe, tracked firewall management (UFW-aware via `before.rules`, or
  direct iptables/ip6tables) that never touches unrelated rules.
- Project-scoped backup/restore with archive validation and automatic
  pre-restore safety snapshots.
- Bats unit test suite and Docker-based real end-to-end connection tests
  (UDP, TCP, dual/fallback, revocation, idempotent reinstall,
  backup/restore, uninstall/reinstall, multi-client).

[1.0.1]: https://github.com/Humran13/OpenVPN-Server/releases/tag/v1.0.1
[1.0.0]: https://github.com/Humran13/OpenVPN-Server/releases/tag/v1.0.0
