# Supported format matrix

Status legend: **Expected** = supported by AVFoundation/ImageIO on iOS 17+, not yet verified on device. **Tested** = verified on real hardware (none yet).

| Container / codec | Status | Notes |
|---|---|---|
| MOV — HEVC (iPhone camera) | Expected | Imported without transcoding |
| MOV / MP4 — H.264 | Expected | |
| MP4 — HEVC 4K / HDR (Dolby Vision, HLG) | Expected | HDR display depends on device |
| M4V | Expected | DRM-protected iTunes files will not play |
| MKV, AVI, WMV, FLV, WebM | Not supported | Rejected at import with a message; would need a third-party engine (Phase 3 decision) |
| HEIC / HEIF, JPEG, PNG, TIFF | Expected | |
| GIF | Expected (first frame) | No animation yet |
| Live Photos | Partial | Still image only |
| ProRAW / DNG | Expected | Shown downsampled to 3200 px |

Update this table as each row is tested on an iPhone and iPad.
