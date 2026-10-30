# Supported format matrix

VISION has two playback engines:
- **Apple AVPlayer** (default): hardware decoding, lowest battery, smoothest. Used whenever it can play *every* track of a file.
- **VLC engine** (MobileVLCKit, LGPL): used for everything else. Chosen once at import (`MediaItem.usesVLC`).

Status: **Expected** = should work, not yet verified on a device. **Tested** = verified on real hardware.

| Container / codec | Engine | Status |
|---|---|---|
| MOV/MP4/M4V — H.264, HEVC, HDR | Apple | Tested (MOV/HEVC from iPhone camera) |
| MP4 with DTS/other audio Apple can't decode | VLC | Expected |
| MKV (H.264/HEVC/VP9/AV1 + AAC/AC3/DTS/Opus) | VLC | Expected |
| WebM (VP8/VP9/AV1) | VLC | Expected |
| AVI (DivX/Xvid/MJPEG), WMV/ASF, FLV/F4V | VLC | Expected |
| TS/MTS/M2TS, MPG/MPEG/VOB, 3GP, OGV, RM/RMVB, MXF | VLC | Expected |
| DRM-protected files (iTunes, Netflix downloads) | — | Not supported (by design) |

Limits of the VLC engine today: no scrub thumbnail bubble (the video frame itself follows your finger), no fill-screen toggle, hero autoplay preview disabled. Photos-library import only offers formats the Photos app holds; import other video formats from Files.
