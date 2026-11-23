# Security Policy

## Cryptographic Design (`ODE1` Vault)

Open Drive provides optional client-side zero-knowledge encryption:

- **Master Key (`MK`)**: 256-bit random key generated via `SecRandomCopyBytes`.
- **Passphrase Key-Encryption Key (`KEK`)**: Derived from the user's passphrase via `PBKDF2-HMAC-SHA256` (`210,000` iterations, 16-byte random salt) and used to wrap `MK` with `AES-256-GCM` (`mkByPass` in `.od-meta`).
- **24-Word Recovery Key (`mkByRecovery`)**: Derived via `HKDF-SHA256` over the normalized 24-word recovery phrase and used to wrap an independent copy of `MK`.
- **Per-File Encryption (`ODE1`)**:
  - 72-byte header: `"ODE1"` (4 bytes) + `noncePrefix` (8 bytes) + `AES.GCM.seal(fileKey, using: masterKey).combined` (60 bytes).
  - Each `4 MiB` plaintext chunk `i` is encrypted with `AES-256-GCM` using `fileKey` and a deterministic 12-byte nonce `noncePrefix (8B) || UInt32(i).bigEndian (4B)`, producing `plaintextChunk.count + 16` bytes on the wire.
- **Filename Encryption (`ODNames`)**: Filenames are encrypted with `AES-256-GCM` using an `HKDF-SHA256` subkey (`info = "ODNames-v1"`) and encoded with unpadded Base64URL.

## Reporting a Vulnerability

Please report suspected security issues privately by opening a security advisory on GitHub rather than filing a public issue.
