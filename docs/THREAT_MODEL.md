# Threat model (Phase 1)

## Protected against
| Threat | Control |
|---|---|
| Someone picks up the unlocked phone and opens VISION | PIN / Face ID gate, auto-lock on background |
| Private media visible in the app switcher | Neutral cover whenever the scene isn't active |
| PIN guessing | PBKDF2 210k rounds, timeouts 30s → 1m → 5m → 15m after 5 failures |
| Files copied out of the app container (backup tools, forensic copy of a locked phone) | AES-256-GCM; key in device-only Keychain; vault excluded from backups |
| Tampered or truncated vault files | GCM authentication per chunk + index/final-flag AAD |
| Plaintext left on disk | Playback and photo viewing decrypt to memory only; Photos imports use a tmp staging copy deleted right after encryption and purged at launch |
| Thumbnails leaking content | Thumbnails encrypted; decrypted cache in memory only, purged on lock |

## NOT protected against (stated honestly)
- A jailbroken or compromised OS, or malware with root.
- Someone who knows the PIN, or can pass Face ID.
- Screenshots / screen recording while the vault is open (iOS doesn't let apps fully block these).
- Copies the user exports or shares (Phase 3 feature).
- The app lock gates the UI; the master key is readable by the app after first unlock without Face ID. Binding the key to biometrics would break PIN fallback and background import — revisit in Phase 2.
- Lockout timing uses the wall clock; changing the device date can shorten a timeout.
- Wall-clock-independent counters and a "wipe after N failures" option are candidates for Phase 3.

## Data loss risks (user-facing)
- Lost / reset / replaced device, or deleting the app → vault is unrecoverable (no backup until Phase 2).
- Forgotten PIN + Face ID unavailable → vault inaccessible. There is intentionally no backdoor.
