# Security Policy

## Reporting a vulnerability

Please report security issues privately by email to **czapkovicz@gmail.com**
with the subject line `fabulous security`. Do not open a public issue for
undisclosed vulnerabilities.

Include what you found, how to reproduce it, and the impact. We aim to
acknowledge within a few days.

## Scope

fabulous is an on-device macOS app with no server component. Relevant areas:

- Local data at rest: transcript history (`~/Library/Application Support/fabulous/history.sqlite`,
  opt-in, plaintext SQLite) and downloaded models.
- Text injection into other apps via the Accessibility API.
- On-device LLM cleanup and AX-harvested screen context (memory-only).

## Distribution integrity

Released builds are currently **unsigned** (no paid Apple Developer ID yet).
Each release attaches a `SHA-256` checksum file next to the `.dmg`; verify it
before opening:

```sh
shasum -a 256 -c fabulous-<version>.dmg.sha256
```

Signed + notarized builds are planned.

## Supported versions

Only the latest release is supported.
