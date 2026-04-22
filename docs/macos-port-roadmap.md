# BIAS macOS Port — Roadmap & Test Plan

Status: proposed, not yet started. Target branch: `claude/review-fork-port-strategy-4iMKH`.

## Context

This tree is the **BIASJAABA** fork of `iorodeo/bias` (Branson lab, Janelia).
BIAS is a Qt5/C++ multi-camera acquisition app. Two driving goals for the
macOS port:

1. **Primary feature:** preserve uFMF recording end-to-end.
2. **Camera support on mac, in priority order:**
   - any mac-native camera source (FaceTime cam, iPhone Continuity Camera,
     generic USB webcams) for demos and CI.
   - **FLIR / Spinnaker** (we already own these cameras; Spinnaker 4.1+ has
     official Apple Silicon support).
   - **Basler / pylon** as a hedge and second industrial backend.

Non-goals: Windows-only plugins (stampede rig control), the dead `fc2` /
`dc1394` backends, Qt6 migration, JAABA integration itself.

## Architectural observations that drive the plan

- BIAS already has a clean **camera facade** (`src/facade/camera.{hpp,cpp}`,
  `src/backend/base/camera_device.hpp`). Adding a backend is a localized
  change: one `CameraDevice` subclass + one guid class + register in
  `Camera::Camera(Guid)` at `src/facade/camera.cpp:27` and in `CameraFinder`.
  **We never need to touch the GUI or the uFMF writer to add a camera.**
- uFMF pipeline (`src/gui/video_writer_ufmf.*`, `compressor_ufmf.*`,
  `background_*_ufmf.*`) is Qt5 + OpenCV + STL with no OS-specific code.
  Expected to "just work" on macOS once the tree compiles.
- Platform-specific code surface is tiny: thread affinity (Windows API),
  one `QueryPerformanceCounter` block in the dc1394 backend (which we
  aren't compiling on mac), Windows-registry-based default save directory,
  and `-std=gnu++0x` in `CMakeLists.txt`.

## Phased roadmap

Each phase has a clear deliverable. Phases are mostly sequential; explicit
parallelism noted where it exists.

### Phase 0 — Dev environment (0.5 day)

- Install toolchain on the MacBook: Xcode Command Line Tools, Homebrew,
  `brew install cmake qt@5 opencv pkg-config ninja`.
- Record versions in `docs/macos-dev-setup.md` for reproducibility.
- Confirm the `claude/review-fork-port-strategy-4iMKH` branch is checked
  out and clean.

**Deliverable:** brew-installed toolchain + a dev-setup note.

**Exit test:** `cmake --version`, `qmake -v`, `pkg-config --modversion opencv4`
all succeed.

### Phase 1 — Minimal compile and launch on macOS (1 day)

Smallest patch that gets `test_gui` launching on a Mac with all three
existing backends disabled.

Files to change:
- `CMakeLists.txt`: bump `cmake_minimum_required` to 3.16; replace
  `-std=gnu++0x` with `-std=c++14`; add an `if(APPLE)` branch noting which
  backends are skipped; allow build if only mac-native backend is on.
- `src/gui/affinity.cpp:5-103`: wrap the Windows block in
  `#ifdef Q_OS_WIN`; provide no-op implementations of
  `ThreadAffinityService::assignThreadAffinity()` etc. on other platforms.
- `src/gui/camera_window.cpp:2971-2985`: add a `#elif defined(Q_OS_MAC)`
  branch using `QStandardPaths::writableLocation(QStandardPaths::MoviesLocation)`
  and `QStandardPaths::DocumentsLocation`.
- Configure with
  `cmake -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5);$(brew --prefix opencv)"
         -Dwith_fc2=OFF -Dwith_spin=OFF -Dwith_dc1394=OFF ..`.

**Deliverable:** `test_gui` binary links and launches, showing an empty
camera list and a functional menu bar. Quit cleanly.

**Exit tests:**
1. `cmake --build build -j` completes with zero errors.
2. `./test_gui` opens, the camera enumeration dialog shows "no cameras".
3. Main window menus open (File, Camera, Logging, Timer, Plugins).
4. App quits without crash (check `Console.app` for no uncaught signals).

### Phase 2 — Mac-native camera backend for demos (3–5 days)

Give BIAS a camera on macOS without needing Spinnaker. This is the
"demo before the FLIR arrives" path.

**Two sub-options, pick one or do both:**

**2a. AVFoundation backend** (`src/backend/avf/`) — *recommended first*.
- Covers the built-in FaceTime camera, any AVF-visible USB webcam, and
  **iPhone Continuity Camera** (macOS 13+). Great demo story.
- Pure Apple framework — no new third-party dependency.
- Small Obj-C++ file set: `camera_device_avf.{hpp,mm}`,
  `guid_device_avf.{hpp,mm}`, `utils_avf.{hpp,mm}`.
- Map BIAS `PropertyType` enum (`src/facade/basic_types.hpp:217`) onto
  `AVCaptureDevice` KVC properties (exposure, focus, white balance).
- Map pixel formats to BIAS: MONO8 (from `kCVPixelFormatType_OneComponent8`),
  RGB8, 422YUV8.
- Link flags: `-framework AVFoundation -framework CoreMedia
  -framework CoreVideo -framework Foundation`.

**2b. libuvc backend** (`src/backend/uvc/`) — *optional fallback*.
- `brew install libuvc`. Works with generic UVC cameras not exposed via AVF.
- More mechanical but also more generic code than AVF.
- Skip this if 2a covers the demo cameras you actually plug in.

Both follow the existing backend pattern — `Camera::Camera(Guid)` at
`src/facade/camera.cpp:27` gets a new `case CAMERA_LIB_AVF:` (and/or
`CAMERA_LIB_UVC:`). Add to `CameraLib` enum in `basic_types.hpp`.

**Deliverable:** live preview of a FaceTime/iPhone/webcam frame in BIAS's
camera window.

**Exit tests:**
1. `CameraFinder` lists at least one device.
2. Connect → preview displays frames at steady fps.
3. Property dialog shows at least exposure, gain, white balance with
   working sliders.
4. Disconnect → reconnect cycle works without crash or leak.
5. App grants camera access via the standard macOS TCC prompt (requires
   `NSCameraUsageDescription` in `Info.plist`, see Phase 4).

### Phase 3 — uFMF end-to-end verification (1–2 days, overlaps with Phase 2)

The whole reason we're doing this.

- Record a 60-second clip to `.ufmf` from the Phase 2 backend.
- Verify bytes: confirm header `"ufmf"`, version `4` (see
  `src/gui/video_writer_ufmf.cpp:46`), chunk IDs `0/1/2` for
  keyframe/frame/index.
- Read the file back with an independent tool to confirm correctness.
  Options: Python reader from the JAABA ecosystem, or
  [`motmot.ufmf`](https://github.com/motmot/ufmf). Pick one and document
  which.
- Measure: compression ratio, sustained fps, dropped frame count,
  background-model update latency.
- Sanity-check by logging the same stream to `.avi` and `.fmf` in parallel
  runs.

**Deliverable:** a recorded `.ufmf` file that a known-good reader opens
and decodes.

**Exit tests:**
1. Record 60 s at the camera's native fps → `.ufmf` file exists, non-zero.
2. External reader decodes all frames without error.
3. Frame count in file == frames logged by BIAS (no silent drops).
4. Mean image from decoded uFMF matches a concurrently captured AVI
   within a small pixel tolerance.
5. Record the same duration to `.avi`, `.fmf`, `.bmp`-sequence. All work
   (VideoWriter_avi wraps OpenCV, which is present on mac).

### Phase 4 — Distributable .app bundle (1–2 days)

Make it runnable on a second Mac that has no dev tooling.

- CMake: set `MACOSX_BUNDLE` on `test_gui` target; set
  `CMAKE_OSX_DEPLOYMENT_TARGET="13.0"` (Ventura) as a reasonable floor.
- Start Apple Silicon only (`CMAKE_OSX_ARCHITECTURES=arm64`); expand to
  universal (`arm64;x86_64`) only if an Intel mac is in scope.
- Post-build step: run `macdeployqt test_gui.app` to embed Qt frameworks.
- Add a `fixup_bundle` CMake step (or `dylibbundler`) for OpenCV and any
  other non-Qt dylibs, rewriting install names to `@rpath`.
- Write `Info.plist` keys:
  - `NSCameraUsageDescription` (required for AVFoundation)
  - `CFBundleIdentifier`, `CFBundleVersion`, `CFBundleShortVersionString`
- Sign ad-hoc (`codesign --deep --force -s - test_gui.app`) for local use.
- Produce a `.dmg` via `hdiutil create` or `create-dmg`.

**Deliverable:** a `.dmg` that, when dragged to `/Applications` on a
second mac, runs BIAS and records a `.ufmf`.

**Exit tests:**
1. Copy `.app` bundle to a Mac without Homebrew; launch.
2. Camera-access prompt appears; granting it enables preview.
3. Record a `.ufmf` clip on that machine.
4. `otool -L test_gui.app/Contents/MacOS/test_gui` shows only system
   frameworks and `@rpath/`-prefixed libs (no `/usr/local/` or
   `/opt/homebrew/` absolute paths).

### Phase 5 — Spinnaker backend on macOS (2–3 days, when FLIR camera available)

With the app already standing up and recording uFMF, integrating the
real industrial camera is focused work.

- Install Spinnaker 4.1+ for Apple Silicon from Teledyne.
- `cmake/Modules/FindSpinnaker.cmake`: add an `elseif(APPLE)` branch
  pointing at `/Library/Frameworks/Spinnaker.framework` or the installer's
  `/usr/local/lib` location (check the `.pkg` layout; Spinnaker installs
  to `/Applications/Spinnaker` + `/usr/local` historically).
- Build `src/backend/spin/` and address any API drift between the
  Spinnaker version BIASJAABA was written against (≈2.x–3.x) and 4.1.
  Likely touch points: node map traversal, event notifications,
  enum-name changes. Audit via `spinc` header diffs.
- If drift is non-trivial, introduce a thin shim header rather than
  branching the whole backend.

**Deliverable:** BIAS enumerating and streaming from a real FLIR USB3 or
GigE camera on a Mac, recording uFMF.

**Exit tests:**
1. FLIR camera appears in `CameraFinder` list.
2. Format7 ROI selection works.
3. Property pages (brightness, shutter, gain, frame rate) round-trip
   values to the device.
4. Internal and external trigger modes both take effect.
5. Sustained uFMF recording for 5 minutes at the camera's native rate
   without drops.

### Phase 6 — Basler/pylon backend (3–5 days, future, optional)

- `brew install --cask` or run Basler's `.pkg` for pylon 8.1+.
- New backend `src/backend/pylon/` mirroring `src/backend/spin/` layout.
- GenICam model is nearly identical between Spinnaker and pylon —
  expect ~70% of the mapping logic to be near-translation.

**Deliverable:** second industrial backend, selectable alongside
Spinnaker at build time with `-Dwith_pylon=ON`.

**Exit tests:** same matrix as Phase 5, against a Basler ace/dart/boost
camera.

### Phase 7 — Plugins (stretch)

Inventory of the three BIASJAABA plugins and their mac story:
- `signal_slot_demo` — pure Qt. Should compile and run on mac
  immediately. Valuable as a two-camera sync demo once two cameras are
  available.
- `grab_detector` — Qt + `Qt5SerialPort` + QCustomPlot + DIO firmware.
  SerialPort works on mac (`/dev/tty.usbmodem*`); firmware is external,
  not our problem. Build should work.
- `stampede` — Qt + `Qt5SerialPort`. Specific to a Janelia rig. Likely
  not useful to us directly; compile only if enabled.

Defer until Phase 5 is green; these are not load-bearing for the uFMF
objective.

## Testing plan summary

A single table to check against in a month.

| # | Test | Phase | Pass criterion |
|---|------|-------|----------------|
| 1 | `cmake` configures on macOS | 1 | 0 errors |
| 2 | `test_gui` builds | 1 | 0 errors, 0 warnings (or documented) |
| 3 | `test_gui` launches with empty camera list | 1 | window appears, quits cleanly |
| 4 | AVF camera enumerated | 2 | at least 1 device listed |
| 5 | AVF live preview steady | 2 | ≥ native fps, no visible hitches for 60 s |
| 6 | Property dialog reads/writes | 2 | exposure + gain + WB round-trip |
| 7 | Record `.ufmf` 60 s | 3 | file exists, non-zero, valid header |
| 8 | External reader decodes `.ufmf` | 3 | all frames decoded, no errors |
| 9 | Frame-count parity ufmf vs log | 3 | delta == 0 |
| 10 | `.avi` + `.fmf` + `.bmp` also work | 3 | files produced, playable |
| 11 | HTTP control `/start` / `/stop` | 3 | `curl` to `ExtCtlHttpServer` port drives record |
| 12 | JSON config save/load round-trip | 3 | loaded config matches saved config byte-for-byte |
| 13 | `.app` bundle runs on second Mac | 4 | record a `.ufmf` without dev tools installed |
| 14 | `otool -L` clean | 4 | no absolute Homebrew paths in final binary |
| 15 | FLIR enumerated & streaming | 5 | preview + 5-min uFMF recording |
| 16 | FLIR trigger modes | 5 | internal + external trigger work |
| 17 | Two-camera `signal_slot_demo` | 7 | (when 2 cameras available) both cams sync by frame count |
| 18 | Basler enumerated & streaming | 6 | same as test 15 against Basler |

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Spinnaker 4.x C API drift from code | Medium | Medium | Audit headers early in Phase 5; keep changes in a shim file |
| Qt5 EOL pressure | Low now, rising | Medium | Pin to Qt 5.15 LTS on mac; revisit Qt6 as separate project |
| AVFoundation property model mismatch with BIAS `Property` struct | Medium | Low | Some properties will be `supported=false`; that's fine |
| Apple Silicon vs Intel split | Low | Low | Start arm64-only; universal build is mechanical to add |
| macdeployqt + OpenCV dylib rewriting fiddly | Medium | Low | Well-trodden path; use `fixup_bundle` / `dylibbundler` |
| `NSCameraUsageDescription` missing → silent TCC denial | High if forgotten | High for UX | Build into Phase 4 from the start; test on a fresh user account |
| Apple notarization required for distribution to other users | Low (dev use) | Medium | Ad-hoc sign for internal use; notarize only if distributing broadly |

## Single-shot vs multi-agent — my recommendation

Short answer: **mostly single-shot, with one narrow place to parallelize.**

Reasoning:
- Phases are naturally sequential. Phase 1 gates Phase 2 (can't write a
  backend if the tree doesn't compile). Phase 2 gates Phase 3 (need a
  camera to record uFMF). Phase 3 gates Phase 4 (no point packaging an
  unverified build). Phase 5 needs hardware we don't have yet.
- Each phase is small enough (0.5–5 days) that a single agent or a
  single human keeps the context coherent. The costs of multi-agenting
  (merge conflicts, duplicated context, divergent style) outweigh the
  wall-clock savings at this scale.
- The one place parallelism genuinely helps: **Phase 2a (AVFoundation) +
  Phase 2b (libuvc) can be written concurrently** by two agents once the
  facade-extension pattern is locked in during Phase 1, because they
  touch disjoint `src/backend/{avf,uvc}/` subtrees. This saves maybe a
  day.
- A better decomposition than parallel agents is **one PR per phase**.
  That's four to six reviewable diffs, each small enough to reason about,
  with a clear rollback point if something breaks. It gives us a testing
  checkpoint at every step rather than a single 2-week PR that's hard to
  review or revert.

**Concrete proposal:**
- Phase 1: single agent, one PR.
- Phase 2: optionally parallel agents for 2a/2b, one PR each.
- Phase 3: single PR (mostly validation scripts + any bugfixes that
  shake out).
- Phase 4: single PR.
- Phase 5 / 6: single PRs when cameras arrive.

At any point, a human (you) is the integrator, not another agent. Agents
write, humans decide what lands.

## Open questions to resolve before starting

1. Is this primarily an **Apple Silicon** effort, or do we need Intel
   mac support too? (Affects Phase 4 decisions.)
2. Minimum macOS version floor? (Proposal: Ventura 13.0 — gives us
   iPhone Continuity Camera.)
3. Distribution model: internal-only (ad-hoc signing fine) or broader
   (notarization + Developer ID required)?
4. Do we want to keep the `fc2` / `dc1394` backends in the tree for
   Windows/Linux builds, or strip them? (Proposal: keep, gated behind
   their existing CMake flags — they don't affect the mac build.)
5. Which uFMF reader becomes the "reference decoder" for validation in
   Phase 3?

## Local development handoff

This roadmap was drafted in a cloud session against a clone of the repo.
Every phase from 1 onward requires a real Mac to test, so all further
work should happen in a local session on the MacBook.

Resync the local checkout before starting:

```sh
# in your local clone of the fork
git fetch origin
git checkout claude/review-fork-port-strategy-4iMKH
git pull --ff-only origin claude/review-fork-port-strategy-4iMKH
```

Then start a fresh Claude Code session from that directory and point it
at this roadmap:

```sh
cd /path/to/bias
claude
# inside the session:
# > Read docs/macos-port-roadmap.md and start Phase 1.
```

## Change log

- *Initial draft*: proposed roadmap, pending approval.
