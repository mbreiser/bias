# BIAS macOS dev setup

Reproducibility notes for the macOS port. If you're setting up a second Mac,
match the Homebrew formula versions here to keep behavior consistent.

## Host

| Field | Value |
|---|---|
| macOS | 26.4.1 (Tahoe) |
| Darwin kernel | 25.4.0 |
| Architecture | arm64 (Apple Silicon) |
| Xcode CLT path | `/Library/Developer/CommandLineTools` |
| Clang | Apple clang 21.0.0 |

## Homebrew

| Field | Value |
|---|---|
| Version | 5.1.7 |
| Prefix | `/opt/homebrew` |

## Required formulas

Install in one command:

```sh
brew install cmake qt@5 opencv pkg-config ninja
```

Versions verified for this setup:

| Formula | Version |
|---|---|
| `cmake` | 4.3.0 |
| `qt@5` | 5.15.18 |
| `opencv` | 4.13.0_8 |
| `pkgconf` (provides `pkg-config`) | 2.5.1 |
| `ninja` | 1.13.2 |

### Qt 5 vs Qt 6 symlink conflict

On a current (2026) Homebrew, `opencv` pulls in `qtbase` (Qt 6) as a
dependency. Both Qt 6's `qtbase` and Qt 5's `qt@5` want to own
`/opt/homebrew/bin/qmake`, `macdeployqt`, etc. Installing both in the same
command fails on the second one's link step.

Resolution: install `qt@5` first, then unlink it and let `qtbase` take the
bin symlinks:

```sh
brew install qt@5
brew unlink qt@5
brew install opencv ninja pkg-config
# qt@5 stays unlinked; we access it via $(brew --prefix qt@5)
```

Why this is safe: BIAS's CMake config passes Qt5's prefix explicitly via
`CMAKE_PREFIX_PATH`, not by resolving `qmake` from `PATH`. `brew --prefix
qt@5` returns `/opt/homebrew/opt/qt@5` whether or not qt@5 is linked, so
the build tooling finds Qt5 fine. The Qt 6 `qmake` in `PATH` is never
invoked.

## Build targets

This repo currently only builds the GUI (`test_gui`) on macOS. The fc2,
dc1394, and spin backends are disabled at configure time (see
`CMakeLists.txt` — they default OFF on `APPLE`). The AVFoundation backend
(`with_avf`) is ON by default on `APPLE` and provides live preview from
any AVF-visible camera (FaceTime built-in, USB webcams, iPhone Continuity
Camera).

## Configure + build

From the repo root:

```sh
mkdir -p build && cd build
cmake \
  -G Ninja \
  -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5);$(brew --prefix opencv)" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -Dwith_fc2=OFF -Dwith_spin=OFF -Dwith_dc1394=OFF \
  ..
cmake --build . -j
```

Artifacts land in `build/` (the repo sets `CMAKE_RUNTIME_OUTPUT_DIRECTORY`).
On macOS the executable is a proper `.app` bundle at
`build/test_gui.app`, ad-hoc signed as `org.janelia.bias.test_gui`. Launch
with `open build/test_gui.app`.

## Notes on deployment target and architecture

The CMake config sets, on `APPLE`:

- `CMAKE_OSX_DEPLOYMENT_TARGET = 15.0` (Sequoia floor)
- `CMAKE_OSX_ARCHITECTURES = arm64`

Both are overridable from the command line if you need a different target
(e.g. for universal builds later).

## Camera access (TCC) on first launch

The app bundle embeds an `Info.plist` with `NSCameraUsageDescription`.
On first launch, macOS shows a system prompt asking you to grant camera
access to "BIAS". Click Allow. The grant is keyed to the bundle's ad-hoc
signature identity, so it persists across rebuilds as long as the
signature (which happens in a CMake POST_BUILD step) is present.

If something looks wrong (prompt not appearing, or access silently
denied), inspect the relevant TCC entry:

```sh
sudo log show --last 2m --predicate 'subsystem == "com.apple.TCC"' --style compact | grep -i bias
```

You can reset the grant with:

```sh
tccutil reset Camera org.janelia.bias.test_gui
```

## Camera lineup verified on this workstation

Three AVF-visible cameras work with BIAS:

| Camera | AVF uniqueID | Notes |
|---|---|---|
| Logitech C922 USB webcam | `0x100000046d085c` | External, most reliable for automated tests |
| MacBook Pro FaceTime camera | `6C707041-05AC-0011-0007-000000000001` | Needs lid open; built-in |
| iPhone Continuity Camera | `882104FC-4CE5-4137-A499-2B2500000001` | Wireless, requires iPhone nearby |

All three deliver 1920×1080 BGRA at ~25–30 fps; the AVF backend converts
each frame to `CV_8UC1` (MONO8) via `cv::cvtColor(BGRA→GRAY)` inside the
sample-buffer delegate. `BIAS`'s uFMF writer requires MONO8, so the
backend does the conversion in the delegate queue (not in `grabImage`,
which stays O(1)).

## Env-var overrides for AVF

| Env var | Purpose |
|---|---|
| `BIAS_AVF_TRACE=1` | File-based per-frame delegate trace to `/tmp/bias_avf_delegate.log`. Useful for debugging pixel-format or delegate-not-firing issues. Default off, zero runtime cost when disabled. |
| `BIAS_AVF_PREFER_UID=<uid>` | Override camera sort order so this uniqueID lands at cam 0 (HTTP control port 5010) instead of the alphabetical default. Scripts can pin a specific camera without re-enumerating. Example: `BIAS_AVF_PREFER_UID=0x100000046d085c` pins the C922. |

To pass an env var into the `.app` bundle via `open`, use `--env`:

```sh
open -a build/test_gui.app --env BIAS_AVF_TRACE=1 --env BIAS_AVF_PREFER_UID=0x100000046d085c
```

## HTTP control server for scripted testing

Each camera window runs an HTTP control server on port
`5000 + 10*(camera_number + 1)` (so 5010 for cam 0, 5020 for cam 1, 5030
for cam 2). Useful endpoints:

```sh
curl "http://127.0.0.1:5010/?get-camera-guid"   # see what camera this port controls
curl "http://127.0.0.1:5010/?connect"           # open the AVCaptureSession (triggers TCC prompt on first run)
curl "http://127.0.0.1:5010/?start-capture"     # begin streaming
curl "http://127.0.0.1:5010/?get-status"        # frameCount, framesPerSec, capturing, connected
curl "http://127.0.0.1:5010/?stop-capture"
curl "http://127.0.0.1:5010/?disconnect"
```

Query-string style; `?` is required between the path and the command name.
