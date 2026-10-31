# Security

## Reporting a vulnerability

Report security problems privately. Do not open a public issue.

- Preferred: [open a private report](https://github.com/levochkaa/OpenArc/security/advisories/new) on GitHub.
- Or write to [support@openarc.su](mailto:support@openarc.su).

Include the affected version, the steps to reproduce and what an attacker gains. We reply as soon as we can and tell you when the fix ships.

## Scope

- The Mac and iOS apps, including the Chromium overrides in `Chromium/chromium_src`.
- The sync and update server in `Backend` and its deployment at `api.openarc.su`.
- The update feed and release signing.

Report bugs in Chromium, CEF or WebKit to those projects, unless OpenArc's overrides or configuration cause them.

## Supported versions

OpenArc is in development. Only the latest release gets security fixes.
