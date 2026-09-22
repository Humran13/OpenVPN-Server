# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/Humran13/OpenVPN-Server/releases/tag/v1.0.0
