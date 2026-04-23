# Phase 3 — uFMF validation on macOS

Date: 2026-04-23. Build: `c955bbf` (fork `mbreiser/bias`, branch
`claude/review-fork-port-strategy-4iMKH`). This document captures the
end-to-end validation of BIAS's uFMF recording path on macOS using the
AVFoundation camera backend that landed in Phase 2.

## Summary

| Metric | Value |
|---|---|
| Camera | MacBook Pro built-in FaceTime (AVF uniqueID `6C707041-05AC-0011-0007-000000000001`) |
| Duration | 60 s |
| Resolution | 1920 × 1080 MONO8 |
| Sustained fps | 29.997 |
| uFMF file | 2,110,512,333 bytes (2.11 GB) |
| uFMF frames (reader) | 1783 |
| uFMF frames (BIAS `/?get-status`) | 1780 — delta −3, within the frame-queue-flush window |
| uFMF compression ratio | 0.5708 (file / raw) |
| uFMF keyframes | 2 (initial + one mid-stream background update) |
| uFMF timestamp span | first_ts 0.000 s, last_ts 59.406 s |
| AVI file | 29,901,716 bytes (29.9 MB, mpeg4) |
| AVI frames (ffprobe) | 1783 — parity with uFMF |
| External reader exit code | 0 (all invariants held, `--walk-all` verified every frame offset) |

All four Phase 3 exit criteria from the roadmap pass.

## Setup

- **Host:** macOS 26.4.1 (Tahoe) on Apple Silicon (arm64)
- **Homebrew:** Qt 5.15.18, OpenCV 4.13.0, CMake 4.3.0, Ninja 1.13.2
- **Compiler:** Apple Clang 21.0.0
- **Build:** `cmake -G Ninja -DCMAKE_PREFIX_PATH=...` per
  [docs/macos-dev-setup.md](macos-dev-setup.md); the result is an ad-hoc
  signed `build/test_gui.app` bundle with `NSCameraUsageDescription`
  baked into `Info.plist`.
- **Scene:** user's face in a dim room; background is dark non-varying
  wall. Not an ideal uFMF scene (see caveat below) but representative of
  a typical laptop-camera test shot.
- **uFMF parameters** (BIAS defaults, unchanged):
  - frameSkip = 1
  - backgroundThreshold = 40
  - boxLength = 30
  - compressionThreads = 15
  - medianUpdateCount = 100
  - medianUpdateInterval = 50
  - dilate = on, windowSize = 1

## Reproduce

One script does everything. Takes ~2 min (60 s uFMF + 60 s AVI). Uses
the C922 if it's plugged in (defaults to cam 0 at port 5010 by
alphabetical GUID sort), otherwise the MacBook camera.

```sh
cd $BIAS_REPO
scripts/phase3_record.sh --duration 60 --camera-port 5010 --out-base phase3_final
```

The script handles the three BIAS quirks documented in
[docs/macos-dev-setup.md](macos-dev-setup.md): uppercase-hex URL
encoding, logging-only partial `/?set-configuration` payload, and
connect-before-get-configuration.

To independently verify a recorded `.ufmf`:

```sh
python3 scripts/ufmf_read.py <path.ufmf> --verbose --walk-all \
    --save-bg /tmp/bg.pgm --save-first-frame /tmp/f0.pgm
```

Non-zero exit code means a specific failure (2 = bad magic/version,
3 = never-closed, 4 = chunk-ID mismatch, 5 = count mismatch,
6 = truncated). See the file header for the full exit-code map.

## Exit criteria results

Cross-reference to the roadmap's test plan table
([docs/macos-port-roadmap.md](macos-port-roadmap.md) tests 7–10).

### Test 7: 60 s `.ufmf` exists, non-zero

> `ls -la ~/Movies/phase3_final_ufmf_*.ufmf`
> `-rw-r--r--  1 ...  2110512333  ... phase3_final_ufmf_cam_0_date_2026_04_23_time_16_19_40_v001.ufmf`

2.11 GB, non-zero. ✓

### Test 8: External reader decodes all frames

```
ok=1 width=1920 height=1080 coding=MONO8 frames=1783 keyframes=2 \
  first_ts=0.000000 last_ts=59.406260 bytes=2110512333 compression_ratio=0.5708
```

With `--walk-all` the reader verifies the chunk ID at every frame offset
and every keyframe offset, not just the endpoints. Zero integrity
failures. ✓

### Test 9: Frame-count parity BIAS vs file

BIAS reports `frameCount = 1780` at the moment the script queries
`/?get-status`. The file contains 1783 frames. The −3 delta is the
grabber queue flushing after the status snapshot and before
`stop-capture` actually stops the writer thread; this is the same −2
to −5 range we've seen on the earlier 10 s and 5 s smoke runs. Within
the ±5 frames allowed by the roadmap. ✓

### Test 10 (partial, per this plan's scope): `.avi` also produced

```
ffprobe: mpeg4,1920,1080,1783
```

29.9 MB mpeg4 stream, same frame count as the uFMF (1783), plays in
QuickTime. ✓ (FMF and BMP-sequence paths intentionally out of scope
for this validation — can be added in a follow-up if needed.)

## Caveats and known non-blockers

1. **Compression ratio 0.57 is not "great" for uFMF.** uFMF is designed
   for scenes where <20 % of pixels change per frame
   ([src/gui/compressed_frame_ufmf.cpp:193-230](../src/gui/compressed_frame_ufmf.cpp)).
   A face in the frame is already near that threshold; when the user
   moves or when auto-exposure adjusts, frames fall into the
   whole-frame-fallback path and the file size balloons. Proper uFMF
   test scenes (fly in a dish, mouse in a box, etc.) typically land
   around 0.05–0.20. The ratio we measured is a correctness datapoint,
   not a benchmark.

2. **`/?close` doesn't terminate the Qt process**, only the camera
   window. The app lingers. `scripts/http_smoke_test.sh` treats this as
   a `KNOWN` (soft-pass) for the same reason. Cause is likely Qt's
   default `quitOnLastWindowClosed` behavior interacting with our
   AVCaptureSession teardown; not blocking any recording functionality.

3. **Auto-exposure is camera-controlled.** Our AVF backend doesn't
   override exposure / gain / focus yet (all `PropertyType`s report
   `supported=false`). That's fine for Phase 3 — the pipeline works —
   but Phase 5 (Spinnaker) will need real property control.

## Artifacts

Files produced by this run are kept in `~/Movies/` for posterity
(they're large — 2.1 GB + 30 MB — not committed to the repo):

- `phase3_final_ufmf_cam_0_date_2026_04_23_time_16_19_40_v001.ufmf`
- `phase3_final_avi_cam_0_date_2026_04_23_time_16_20_48_v001.avi`

The decoded background (PGM → PNG) and reconstructed first frame are in
`/tmp/phase3_bg.png` and `/tmp/phase3_first.png` respectively. Both show
the expected scene — a person (the user) silhouetted against a dark
background — confirming the end-to-end pixel pipeline.

## What Phase 3 unblocks

- **Phase 4**: `.app` bundling is already partway done (ad-hoc signed,
  `Info.plist` in place). Remaining work is dylib rewriting via
  `macdeployqt` / `fixup_bundle` / `dylibbundler` so the bundle runs on
  a second Mac without Homebrew.
- **Phase 5**: Spinnaker 4.1 backend. The uFMF pipeline is proven; all
  we need is a second `CameraDevice` subclass that delivers MONO8 and
  overrides the minimum reporting surface (the same Stage 4 we did for
  AVF). The backend interface, the pipeline, and the recording scripts
  all carry over.
