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
`CMakeLists.txt` — they default OFF on `APPLE`).

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

## Notes on deployment target and architecture

The CMake config sets, on `APPLE`:

- `CMAKE_OSX_DEPLOYMENT_TARGET = 15.0` (Sequoia floor)
- `CMAKE_OSX_ARCHITECTURES = arm64`

Both are overridable from the command line if you need a different target
(e.g. for universal builds later).
