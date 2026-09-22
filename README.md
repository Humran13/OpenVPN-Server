# OpenVPN Server Manager

A production-ready installer and management CLI/TUI for running your own
**OpenVPN Community Edition** server on Ubuntu — built for self-hosters who
want a secure, modern VPN server without a web panel, without a hosted
subscription, and without giving up control of their own box.

This project is an independent installer/management layer. It is **not**
affiliated with or endorsed by OpenVPN Inc. See [LICENSE](LICENSE).

## Install (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/OpenVPN-Server/main/install.sh | sudo bash
```

The installer works whether you run it via that piped one-liner or from a
local clone — prompts are read from `/dev/tty`, so the interactive setup
wizard still works even though the script itself arrived over a pipe.

Prefer to review before running it as root? That's a good instinct:

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/OpenVPN-Server/main/install.sh -o install.sh
less install.sh
sudo bash install.sh
```

## What you get

- **OpenVPN Community Edition 2.7.7**, installed from the official OpenVPN
  apt repository where available, or built from verified upstream source
  (checksum + GPG signature, pinned in [`config/upstream.conf`](config/upstream.conf))
  where it isn't yet.
- **Easy-RSA 3.2.7** PKI: a private CA, a unique certificate per client,
  revocation, and CRL enforcement — no shared credentials.
- A polished manager, `sudo ovpn`, for everything day-to-day: clients,
  status, diagnostics, logs, backup/restore, updates, repair, uninstall.
- Modern, secure defaults: AES-256-GCM/ChaCha20-Poly1305, `tls-crypt`,
  TLS 1.2 minimum, EC certificates — no legacy ciphers, no static keys.
- Safe firewall handling: it tracks exactly the rules it adds and never
  touches your existing UFW/iptables configuration otherwise.

## Supported platforms

| Ubuntu release | Status |
|---|---|
| 18.04 LTS (bionic) | Supported, **EOL** — see warning below |
| 20.04 LTS (focal) | Supported and tested |
| 22.04 LTS (jammy) | Supported and tested |
| 24.04 LTS (noble) | Supported and tested |
| 26.04 LTS (resolute) | Supported and tested |
| Newer Ubuntu releases | Detected and allowed (Ubuntu ≥ 18.04), with a note that the exact release wasn't part of the explicitly tested matrix |

Architectures: **amd64** (x86_64) and **arm64** (aarch64).

> **Ubuntu 18.04 is end-of-life** outside paid Extended Security Maintenance.
> The installer will still work — engine install automatically falls back to
> the official OpenVPN apt repository's OpenVPN 2.6.x package, since 18.04's
> system OpenSSL predates an API OpenVPN 2.7.x itself requires — but for an
> Internet-facing production server, use a currently supported Ubuntu LTS
> release.

> **Existing OpenVPN setup detected?** The installer checks for a
> pre-existing, unrelated OpenVPN deployment before doing anything. It never
> modifies or removes configuration it didn't create — it uses its own
> config directory, its own systemd unit names, and whatever ports you
> choose, so it can coexist. You'll get a clear warning and a chance to
> abort if something unrelated is already there.

## Using the manager

```bash
sudo ovpn                       # interactive menu
sudo ovpn status                # server status
sudo ovpn diagnostics           # PASS/WARN/FAIL health checks
sudo ovpn client add alice      # create a client + export its profile
sudo ovpn client list
sudo ovpn client show alice
sudo ovpn client revoke alice
sudo ovpn client renew alice
sudo ovpn client export alice   # re-export a profile
sudo ovpn logs [-f]
sudo ovpn restart
sudo ovpn backup [path]
sudo ovpn restore <path>
sudo ovpn update [--manager|--engine]
sudo ovpn repair
sudo ovpn uninstall [--full] [-y]
sudo ovpn version
```

`ovpn` is the manager. It does not replace or shadow the real
`/usr/sbin/openvpn`/`openvpn` binary.

## Connection modes

Chosen interactively during install (or via `OVPN_*` environment variables
for unattended installs — see below):

- **UDP** (default, port 1194) — fastest, recommended for most servers.
- **TCP** (e.g. port 443) — useful where UDP is blocked.
- **Dual UDP + TCP** — both listeners at once; client profiles list both
  `remote` entries with a short `connect-timeout`, so a client that can't
  reach the UDP listener automatically falls back to TCP.
- **Custom/advanced** — pick your own set of listeners.

Plus, independent of transport:

- **IP family**: IPv4-only, or dual-stack IPv4+IPv6 (only offered if your
  server actually has working outbound IPv6 — a present interface alone
  isn't enough).
- **Routing**: full tunnel (all client traffic via the VPN) or split tunnel
  (only the networks you specify).
- **DNS**: your server's current resolver, Cloudflare, Google, Quad9, or
  custom.

## Creating and importing a client

```bash
sudo ovpn client add alice
```

This creates a unique certificate for `alice` and writes a single, portable
`.ovpn` file (CA, certificate, key and `tls-crypt` key all inline) to:

```
/root/openvpn-clients/alice.ovpn
```

Copy that file to the client device (`scp`, a USB stick, whatever you're
comfortable with — it contains private key material, treat it like a
password) and import it into:

- **OpenVPN Connect** (Windows, macOS, Android, iOS)
- Any standard Linux `openvpn` client (`sudo openvpn --config alice.ovpn`,
  or via NetworkManager's OpenVPN plugin)

## Ports and firewall

The installer opens exactly the ports you chose (e.g. UDP/1194, TCP/443) and
sets up NAT/forwarding for the VPN subnet. It detects and uses UFW if it's
already active on your server (injecting into `/etc/ufw/before.rules`, the
standard supported extension point, so `ufw reload` doesn't wipe the rule);
otherwise it manages iptables/ip6tables rules directly, tagged so they're
individually trackable and reversible. It never flushes your existing
firewall or touches rules it didn't create.

## Backup, restore, update

```bash
sudo ovpn backup                # -> /var/lib/openvpn-server-manager/backups/...
sudo ovpn restore /path/to/backup.tar.gz
sudo ovpn update --manager      # update this tool from GitHub releases
sudo ovpn update --engine       # update the OpenVPN engine itself
```

Restore takes an automatic safety snapshot of the current state first, and
rolls back if the restored configuration fails to come up cleanly.

## Uninstall

```bash
sudo ovpn uninstall            # removes the manager, services, firewall
                                # rules; keeps your PKI/config as a backup
sudo ovpn uninstall --full     # also deletes the CA and all certificates
                                # (irreversible)
```

Either way, only files/rules this project created are touched. The
`openvpn` package itself (if installed via apt) is left in place, since it's
a normal system package, not something this project owns.

## Unattended / scripted install

For automation (CI, provisioning tools), skip the interactive wizard:

```bash
sudo OVPN_NONINTERACTIVE=1 \
  OVPN_MODE=udp \
  OVPN_UDP_PORT=1194 \
  OVPN_IP_FAMILY=ipv4 \
  OVPN_ROUTING=full \
  OVPN_DNS=cloudflare \
  OVPN_PUBLIC_HOST=vpn.example.com \
  bash install.sh
```

See `install.sh` for the full list of `OVPN_*` variables (mode, ports,
routing/split networks, DNS, public host).

## Troubleshooting

- `sudo ovpn diagnostics` — PASS/WARN/FAIL across OS support, the OpenVPN
  binary, PKI, systemd units, listening sockets, firewall, DNS, DCO
  availability, public-IP/hostname consistency, and recent service errors.
- `sudo ovpn logs -f` — tail the systemd journal for your listeners.
- `sudo ovpn repair` — reconstructs missing project-owned pieces (symlink,
  systemd units, firewall rules, directories) without touching your PKI.

## Security notes

- Every upstream download (OpenVPN source, Easy-RSA source, the official
  apt repository's signing key) is verified by SHA-256 checksum and/or GPG
  signature against a fingerprint pinned in `config/upstream.conf` — see
  that file and [SECURITY.md](SECURITY.md) for details.
- The CA and all private keys are generated locally, root-owned, and
  permission-restricted (`0700`/`0600`). They are never logged, never
  committed anywhere by this project, and never leave your server unless
  you copy a client's exported profile off it yourself.
- See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Development / testing

```bash
tests/unit/           # Bats unit tests — validation, config generation,
                       # state persistence, backup safety, etc.
tests/integration/     # Docker-based, real end-to-end OpenVPN connection
                        # tests (actual TLS handshake, actual tunnel, actual
                        # ping through it) across UDP/TCP/dual-fallback/
                        # revocation/idempotency/backup-restore/uninstall-
                        # reinstall/multi-client scenarios.
```

Run the unit tests:

```bash
docker run --rm -v "$PWD:/code" -w /code bats/bats:latest tests/unit/
```

Run a real end-to-end connection test (needs Docker with a privileged,
systemd-capable container and `/dev/net/tun`):

```bash
BASE_IMAGE=ubuntu:22.04 SCENARIO=udp bash tests/integration/run.sh
```

`SCENARIO` is one of `udp tcp dual revoke idempotent backup_restore
uninstall_reinstall multi_client`.

## Issues

Found a bug or have a feature request? Please open an issue at
<https://github.com/Humran13/OpenVPN-Server/issues>.
