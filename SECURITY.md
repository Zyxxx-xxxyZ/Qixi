# Security Policy

## Supported versions

Security fixes are applied on a best-effort basis to the default branch (`main`)
of this repository.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security-sensitive reports.**

Prefer one of:

1. [GitHub Private Vulnerability Reporting](https://github.com/Zyxxx-xxxyZ/Qixi/security/advisories/new) (if enabled on the repo), or
2. A private message to the repository owner via GitHub.

Include:

- A description of the issue and its impact
- Steps to reproduce or a proof of concept
- Affected platforms (iOS version, build configuration) if relevant

You should receive an acknowledgment when maintainers are available. We will
coordinate disclosure after a fix or mitigation is ready.

## Out of scope (typical)

- Issues that require physical access to an unlocked device with a debug build
- Denial of service against a local developer machine only
- Vulnerabilities solely in upstream KataGo that should be reported upstream

## Hardening notes for contributors

- Never commit signing certificates, provisioning profiles, API tokens, or device UDIDs
- Never commit neural network weights (`.bin`, `.mlmodel`, etc.)
- Treat persistence, sync, and bridge JSON as untrusted input (strict parsers already exist — keep them)
