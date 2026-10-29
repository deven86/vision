# VISION — private photo & video vault (iPhone + iPad)

Cinematic, Netflix-style browsing over an encrypted on-device vault. Swift / SwiftUI, iOS 17+.

**Status: Phase 1 (secure local MVP) — code complete, NOT yet compiled or run.**
It was written without access to Xcode. Expect a handful of compile errors on the first build; paste them back and they'll be fixed.

## What's in Phase 1

| Area | Done |
|---|---|
| Lock | 6-digit PIN (PBKDF2, rate-limited), Face ID / Touch ID, auto-lock, app-switcher privacy cover |
| Vault | Chunked AES-256-GCM, per-file keys wrapped by a device-only master key in Keychain; encrypted thumbnails; decrypted data only in memory |
| Playback | Decrypt-on-the-fly streaming into AVPlayer (no plaintext on disk), instant seek, live frame scrubbing, double-tap ±10s, speed 0.5–2×, fit/fill, resume position |
| UI | Home with hero banner + muted autoplay preview, filter chips, Continue Watching / Recently Added / Favorites / per-folder rows; folder grid with covers; multi-select; zoomable photo viewer; details sheet |
| Import | Photos library (original encoding, no transcoding) and Files; progress banner; per-item errors; originals never deleted |
| Bin | Soft delete, restore to previous folder, timed purge (7/30/60 days), permanent delete |

**Not in Phase 1 (by design, per spec phases):** Share Extension, iCloud sync, encrypted backup/restore, PiP, subtitles/audio tracks, duplicate detection, export, folder reordering.

## Build it

### Option A — you have a Mac
```bash
brew install xcodegen
xcodegen generate
open VISION.xcodeproj      # set your Team under Signing & Capabilities, run on your iPhone
```

### Option B — no Mac (GitHub Actions does the building)
1. Push this folder to a **private** GitHub repo. The **CI** workflow builds and runs tests on every push.
2. In App Store Connect: create the app with bundle ID `com.jondhale.vision` (change it in `project.yml` first if you want a different one).
3. App Store Connect → Users and Access → Integrations → create an API key with **Admin** role (needed for cloud signing). Download the `.p8` once.
4. In GitHub → Settings → Secrets and variables → Actions, add:
   - `APPLE_TEAM_ID` — 10-character Team ID
   - `ASC_KEY_ID`, `ASC_ISSUER_ID` — from the key page
   - `ASC_KEY_P8_BASE64` — `base64 -i AuthKey_XXXX.p8` output
5. Actions → **TestFlight** → Run workflow → type `UPLOAD`. After Apple processes the build (~10–30 min) it appears in TestFlight for internal testers.

Never paste these secrets into chat or commit them. Uploading to TestFlight is not App Store approval.

## Layout
```
VISION/App        app entry, root/lock routing, theme
VISION/Security   VaultCrypto (file format), Keychain, PIN, AuthService
VISION/Storage    SwiftData models, VaultStore (paths), Library (mutations), ThumbnailCache
VISION/Import     MediaIngestor, ImportCoordinator, ImportSheet
VISION/Playback   VaultAssetLoader (streaming decrypt), PlayerModel, PlayerScreen, hero preview
VISION/UI         Home, Folders, Viewer, Lock, Bin, Settings, shared components
VISIONTests       crypto + PIN unit tests
docs/             architecture, threat model, format matrix
```

## Important limitation right now
The master key never leaves the device and there is no backup yet. **If the phone is lost, reset, or VISION is deleted, the vault cannot be recovered.** Keep originals elsewhere until Phase 2 (encrypted backup + key recovery) ships.
