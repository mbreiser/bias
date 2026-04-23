# Phase 5 — FLIR / Spinnaker on macOS (handoff)

**Status at end of previous session:** Spinnaker SDK **4.3.0.189** downloaded
and installed on the Mac (Gatekeeper bypass required — the .pkg isn't
notarized). Install layout confirmed. No BIAS code has been touched for
this phase yet; branch head is `d01e3f0` (Phase 3 validation doc).

**Real goal driving Phase 5** (important — don't lose this): answer
whether a Mac can run the lab's FLIR-camera behavioral-video experiments
at production rates. Phase 5 is not polish; it's the feasibility test.

## Current state

- [`docs/macos-dev-setup.md`](macos-dev-setup.md) — macOS build prerequisites.
- [`docs/phase3-ufmf-validation.md`](phase3-ufmf-validation.md) — uFMF pipeline
  proven end-to-end against the MacBook AVF camera at 30 fps / 1920×1080.
- [`scripts/phase3_record.sh`](../scripts/phase3_record.sh),
  [`scripts/ufmf_read.py`](../scripts/ufmf_read.py),
  [`scripts/http_smoke_test.sh`](../scripts/http_smoke_test.sh) — all
  camera-backend-agnostic; will work unchanged once the Spinnaker backend
  compiles.

## Spinnaker 4.3 install layout on macOS (verified)

Teledyne installs into `/Applications/Spinnaker/`, NOT into
`/Library/Frameworks/`. The existing `cmake/Modules/FindSpinnaker.cmake`
in the tree is Linux/Windows-only — Phase 5's first code change is to
add an `APPLE` branch there.

```
/Applications/Spinnaker/
├── include/
│   ├── Spinnaker.h              (C++ API top-level)
│   ├── SpinnakerDefs.h
│   ├── SpinnakerPlatform.h
│   ├── SpinGenApi/SpinnakerGenApi.h
│   └── spinc/
│       ├── SpinnakerC.h         (C API — what BIAS's backend uses)
│       ├── SpinnakerDefsC.h
│       ├── SpinnakerGenApiC.h
│       ├── SpinnakerGenApiDefsC.h
│       └── SpinnakerPlatformC.h
├── lib/
│   ├── libSpinnaker.dylib            symlink → libSpinnaker.4.3.0.189.dylib
│   ├── libSpinnaker.4.dylib          symlink → libSpinnaker.4.3.0.189.dylib
│   ├── libSpinnaker_C.dylib          symlink → libSpinnaker_C.4.3.0.189.dylib
│   ├── libSpinnaker_C.4.dylib        symlink → libSpinnaker_C.4.3.0.189.dylib   (primary link target for BIAS)
│   ├── libSpinVideo*.dylib           (video writer)
│   ├── libSpinUpdate*.dylib          (firmware updater)
│   ├── libGenApi_clang140_v3_0.dylib (GenApi runtime — Spinnaker links these transitively)
│   ├── libGCBase_clang140_v3_0.dylib
│   ├── libNodeMapData_clang140_v3_0.dylib
│   └── spinnaker-gentl/Spinnaker_GenTL.cti   (GenTL producer; discoverable via GENICAM_GENTL64_PATH)
├── bin/                               60+ example binaries (Enumeration, Acquisition, etc.)
├── apps/
│   └── SpinView_QT.app                GUI enumeration/preview tool
└── Utilities/
    └── SystemCleanup.app
```

Key detail: BIAS's existing `src/backend/spin/` code uses `#include "SpinnakerC.h"`
(bare path), but the macOS install puts that header in a `spinc/` subdir
— so both `/Applications/Spinnaker/include` and `/Applications/Spinnaker/include/spinc`
need to be added to the target's include directories. The library to
link is `libSpinnaker_C.dylib`.

## Gatekeeper on the installer

Spinnaker's `.pkg` isn't notarized. On modern macOS (Tahoe 26+) the
double-click path is blocked with *"Apple could not verify … is free of
malware"*. Two ways through — pick one when fresh-installing on another
Mac or upgrading:

```sh
# A. GUI: System Settings → Privacy & Security → "Open Anyway"
# B. CLI:
xattr -d com.apple.quarantine ~/Downloads/Spinnaker-X.Y.Z.pkg
sudo installer -pkg ~/Downloads/Spinnaker-X.Y.Z.pkg -target /
```

## Exact next steps (in order)

### Step 5.0 — SDK-level smoke test (do before touching BIAS code)

Plug the FLIR camera in, then run:

```sh
DYLD_LIBRARY_PATH=/Applications/Spinnaker/lib \
    /Applications/Spinnaker/bin/Enumeration 2>&1 | head -50
```

If that prints the camera's vendor / model / serial — the SDK + USB3 +
camera stack is working and we can proceed. If it prints `SPINNAKER_ERR_*`
or zero cameras — fix that first (cable, TCC camera permission for the
binary, system extension approval) because BIAS sits on top of this and
won't magically succeed where the example fails.

Also worth confirming `/Applications/Spinnaker/apps/SpinView_QT.app`
shows a live preview — that's the "no BIAS involved" ground truth.

### Step 5.1 — CMake: teach `FindSpinnaker.cmake` about macOS

[`cmake/Modules/FindSpinnaker.cmake`](../cmake/Modules/FindSpinnaker.cmake)
currently has Windows + Linux branches. Add an `APPLE` branch that sets:

```cmake
set(Spinnaker_INCLUDE_DIRS
    "/Applications/Spinnaker/include"
    "/Applications/Spinnaker/include/spinc"
)
find_library(Spinnaker_LIBRARY_C NAMES Spinnaker_C
             PATHS /Applications/Spinnaker/lib NO_DEFAULT_PATH)
set(Spinnaker_LIBRARIES ${Spinnaker_LIBRARY_C})
```

(Match the existing module's variable-naming convention — check what
`src/backend/spin/CMakeLists.txt` uses before inventing new names.)

### Step 5.2 — Build `-Dwith_spin=ON`

```sh
cd build
cmake -G Ninja \
    -DCMAKE_PREFIX_PATH="$(brew --prefix qt@5);$(brew --prefix opencv)" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -Dwith_fc2=OFF -Dwith_spin=ON -Dwith_dc1394=OFF -Dwith_avf=ON \
    ..
cmake --build . 2>&1 | grep -E "error:" | head -30
```

**Expect API-drift errors.** The existing `src/backend/spin/` code was
written against Spinnaker ~2.x/3.x circa 2019. Between then and 4.3.0
we'll almost certainly hit:

- Renamed enum values (e.g. `SPINNAKER_*` → different spelling).
- Changed node-map traversal function names (e.g. `spinNodeMapGetNodeByIndex`
  signatures).
- Chunk-data retrieval (used for per-frame timestamps in
  [camera_device_spin.cpp:1117-1129](../src/backend/spin/camera_device_spin.cpp))
  may have moved under a new function name or changed argument order.
- Event notifications (`spinEventCallback*`) commonly renamed.

Strategy: fix compilation errors in-place (small per-error diffs, with
a comment `// Spinnaker 4.x: renamed from spinFooBar`), *not* in a shim
layer — shims hide the real changes. If any error is non-trivial
(fundamentally new API surface), stop and plan.

### Step 5.3 — Runtime: enumerate + connect + stream

Once compilation succeeds:

1. Verify `/?get-camera-guid` on port 5010 reports the FLIR's serial
   (Spinnaker guids are camera serial strings). If the MacBook AVF
   camera shows up first, use `BIAS_AVF_PREFER_UID=<nonexistent>` to
   bump it down, or disable AVF with `-Dwith_avf=OFF` for Phase 5 runs
   to eliminate cross-backend noise.
2. Run `scripts/http_smoke_test.sh --camera-port 5010`. Most of the 32
   checks should pass unchanged; any that fail tell us where Spinnaker's
   reporting diverges from AVF's (probably property enumeration returns
   real data now, where AVF just reported `supported=false`).
3. Run `scripts/phase3_record.sh --duration 30`. Same uFMF pipeline we
   already validated; now with real FLIR frames. Compare fps, frame
   count, compression ratio against the roadmap's exit tests 15–16
   (FLIR enumerated, Format7 ROI works, property round-trip, trigger
   modes, sustained 5 min at native rate).

### Step 5.4 — Performance harness (the actual feasibility test)

This is what the whole port is for. Write `scripts/phase5_perf.sh` that:

- Records N minutes at each (resolution, fps) pair on your FLIR's
  native-mode list. Start small: one 30 s run at whatever the camera's
  default format is.
- Samples `/?get-frames-per-sec` and `/?get-frame-count` every second
  during capture; logs to a CSV.
- Samples CPU / memory / thermal (`powermetrics -s thermal -i 1000
  -n $((DURATION))`).
- After each run, invokes `ufmf_read.py` to count delivered frames and
  compare to `duration × fps`. Any delta is a drop.
- Target acceptance: 0 dropped frames over ≥ 10 min at the camera's
  configured rate, with thermal state staying out of `Throttled`.

Report the results in `docs/phase5-performance.md` with a table of
(resolution, fps, duration, delivered / expected frames, compression
ratio, thermal peak). That's the document that answers the original
question: "can a Mac run these experiments?"

### Step 5.5 — Trigger modes (optional, if rig uses external trigger)

- `cameraPtr_->setTriggerExternal()` path exists in BIAS but no AVF
  implementation. On Spinnaker this maps to TriggerMode=On, TriggerSource=Line0.
- Confirm external-trigger-driven capture produces frames timestamped
  relative to the trigger (important for sync with stimulus hardware).
- Free-running is fine for the initial feasibility test; add triggered
  mode once free-running passes.

## Things I'd do differently next time

- **Don't round-trip the full config via `/?set-configuration`.** The
  AVF backend only fakes property reporting; Spinnaker will report real
  values so the round-trip might work — but the `{"logging": {...}}`
  partial pattern in `scripts/phase3_record.sh` is still the safer path.
- **Don't trust BIAS's "Unable to revert to previous configuration"
  error message alone.** It swallows the original failure. If something
  breaks, run test_gui with stdout visible and/or add `bias_avf_trace`-style
  diagnostics in the Spinnaker backend's setConfigurationFromMap path.
- **The HTTP URL-decoder case sensitivity** (`%7B` vs `%7b` — see
  [src/utility/basic_http_server.cpp:15-45](../src/utility/basic_http_server.cpp))
  still applies for Spinnaker. `scripts/phase3_record.sh`'s Python
  encoder handles it; any new scripts should copy that pattern.

## Deferred items (NOT needed for Phase 5)

- Phase 4 (dylib rewriting / `.dmg` distribution) — only matters for
  sharing the `.app` with colleagues.
- Phase 7 (plugin verification) — mostly rig-specific; decide per-plugin
  based on actual lab use.
- PR against `mbreiser/master` — branch lives at `origin/claude/review-fork-port-strategy-4iMKH`
  with 10 Phase-0-through-3 commits ready to merge when convenient.
