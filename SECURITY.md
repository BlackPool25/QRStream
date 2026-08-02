# Security Policy

QRStream is a same-room, offline visual broadcast: the transfer path never
touches a socket, and there is deliberately **no encryption** (anything the
camera can see can be read). Integrity is guaranteed by per-frame CRC-32C,
RaptorQ erasure resilience, and a whole-file SHA-256 gate before a file is
offered for saving. See [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) for the
full model.

## Supported versions

| Version         | Supported      |
| --------------- | -------------- |
| latest `main`   | ✅             |
| tagged releases | ✅             |
| older tags      | ⚠️ best-effort |

## Reporting a vulnerability

Do **not** open a public issue for security problems. Report privately:

- GitHub private vulnerability reporting (preferred): the repository's
  _Security → Report a vulnerability_ flow.
- Email the maintainer listed in the latest release.

Please include the QRStream version, the platform (Android / Linux / PWA), a
minimal repro, and the impact. You should expect an acknowledgement within
72 hours and a fix timeline.

## Scope

- **In scope:** memory-safety or logic flaws in the codec/protocol that could
  corrupt a received file past the SHA-256 gate; remote code execution via a
  crafted QR stream; data integrity bypass.
- **Out of scope (by design):** confidentiality of a broadcast (no
  encryption — documented); denial of service by pointing a camera at
  anything; social engineering.
