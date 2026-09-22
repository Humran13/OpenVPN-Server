# Security Policy

## Reporting a vulnerability

If you find a security issue in this project (the installer/manager code in
this repository — not OpenVPN itself), please report it privately rather
than opening a public issue:

- Open a [GitHub Security Advisory](https://github.com/Humran13/OpenVPN-Server/security/advisories/new)
  for this repository, or
- Open a regular issue if the report does not involve sensitive details and
  you're comfortable with it being public.

Please include:

- The affected version/commit
- Steps to reproduce
- The potential impact (e.g. privilege escalation, credential exposure,
  firewall bypass, remote code execution)

We aim to acknowledge reports within a few days.

## Reporting a vulnerability in OpenVPN or Easy-RSA themselves

This project installs upstream OpenVPN Community Edition and Easy-RSA.
Vulnerabilities in those projects should be reported directly to their
maintainers:

- OpenVPN: <https://openvpn.net/security-advisories/>
- Easy-RSA: <https://github.com/OpenVPN/easy-rsa/security>

## Scope

In scope:

- `install.sh` and everything under `bin/`, `lib/`, `config/`
- Command injection, path traversal, privilege escalation, insecure file
  permissions, insecure temp file handling, firewall bypass, PKI/private-key
  exposure, insecure defaults

Out of scope:

- Vulnerabilities in the OpenVPN or Easy-RSA binaries/source themselves
  (report upstream, see above)
- Issues that require the attacker to already have root on the server
- Social engineering

## Supply-chain / verification notes

- Every upstream download (OpenVPN source, Easy-RSA source, the official
  OpenVPN apt repository key) is verified by SHA-256 checksum and/or GPG
  signature against a fingerprint pinned in `config/upstream.conf` before
  it is used. See that file for exact pins and the sources they were
  verified against.
- This project never downloads or executes unverified third-party binaries.
- Private key material (CA key, server key, client keys) is generated
  locally on your server, is root-owned with restrictive permissions, and
  is never transmitted anywhere by this project.
