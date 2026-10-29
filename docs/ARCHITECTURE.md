# VISION architecture (Phase 1)

## Decisions
| Decision | Choice | Why |
|---|---|---|
| Min OS | iOS / iPadOS 17 | SwiftData, Observation, ContentUnavailableView, scroll targeting |
| Project | XcodeGen (`project.yml`) | Reviewable, merge-friendly; no hand-edited `.pbxproj` |
| Persistence | SwiftData, CloudKit-compatible schema, CloudKit **off** | Phase 2 sync without a destructive migration |
| Crypto | CryptoKit AES-256-GCM, chunked | Authenticated, hardware-accelerated, random access |
| Playback | AVFoundation + `AVAssetResourceLoader` | Hardware decode, no plaintext on disk |
| Player engine | AVFoundation only | FFmpeg-class engines deferred (licensing, size, review risk) |

## Key hierarchy
```
Keychain (AfterFirstUnlockThisDeviceOnly)
 └─ Master key (256-bit, never leaves device)
     └─ wraps per-file key (256-bit random, stored in file header)
         └─ encrypts 512 KB chunks with AES-GCM
```
- Deleting a file deletes its wrapped key — the bytes are then unrecoverable even from flash remnants, as long as the master key is intact only on this device.
- `MasterKey.loadOrCreate(allowCreate:)` refuses to mint a new key if vault files exist, so a transient Keychain error can't orphan the vault.

## File format `VSN1`
128-byte header (magic, version, chunk size, plaintext length, wrapped key) followed by `ciphertext ‖ tag` per chunk.
Nonce = chunk index; AAD = `"VSN1" ‖ index ‖ isFinal`. Reordering, dropping, truncating, or editing any chunk fails authentication.

## Why playback is smooth
1. AVPlayer is given a custom-scheme URL (`vision-vault://`). It requests byte ranges; `VaultAssetLoader` decrypts only those chunks (≈1 GB/s with AES hardware), far faster than any video bitrate.
2. `isEntireLengthAvailableOnDemand` + `automaticallyWaitsToMinimizeStalling = false` tell AVFoundation the data is local, so it doesn't build a streaming-style buffer before starting.
3. Decoding stays on Apple's hardware H.264/HEVC path.
4. Scrubbing uses chase-seeking (Apple QA1820) for live, frame-accurate preview without seek pile-ups.
5. A 12-chunk LRU in `VaultFileReader` absorbs AVFoundation's overlapping reads.

**Must be measured on device before release:** time-to-first-frame, memory during a long 4K HEVC file, seek latency. Watch for memory growth on `requestsAllDataToEndOfResource` requests.

## Import pipeline
Photos → `PhotosPicker` (`preferredItemEncoding: .current`, so HEVC isn't transcoded) → staged copy in tmp → inspect (playable? size, duration) → thumbnails (1280 + 480 px) → encrypt → delete staged copy.
Files → security-scoped URL → encrypted directly from source (no plaintext copy).

## Data protection
- Entitlement default: `NSFileProtectionComplete` (SwiftData store, settings).
- Vault media: `completeUnlessOpen` (an import in progress survives a device lock).
- Thumbnails: `complete`.
- Vault directory is excluded from iCloud/iTunes backup (the key is device-only, so a backup copy would be useless and waste the user's iCloud space).

## Phase 2 hooks already in place
- Stable `UUID` ids on every model; optional relationships; defaults on all properties.
- `previousFolderID` for restore; `coverItemID` is a stable reference (survives sync).
- All mutations go through `Library`, the natural place to enqueue sync operations.
