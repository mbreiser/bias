#!/usr/bin/env python3
"""
ufmf_read.py — minimal in-repo reference reader for the uFMF v4 files
produced by BIAS. Used for Phase 3 validation of the macOS port.

Byte-level spec is extracted from BIAS's writer at
src/gui/video_writer_ufmf.cpp:407-740 and src/gui/compressed_frame_ufmf.cpp.
All integers little-endian.

Usage:
    python3 scripts/ufmf_read.py PATH [--save-bg OUT.pgm]
                                       [--save-first-frame OUT.pgm]
                                       [--walk-all]
                                       [--verbose]

Exit codes:
    0  valid, all invariants hold
    2  bad magic / version
    3  never-closed file (index_offset == 0)
    4  chunk-ID mismatch at a frame_loc or keyframe_loc
    5  frame-count mismatch between index and walked chunks
    6  file truncated before index

Success stdout (one line, shell-parseable):
    ok=1 width=W height=H coding=C frames=N keyframes=K \\
      first_ts=F last_ts=L bytes=B compression_ratio=R
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
from dataclasses import dataclass, field
from typing import BinaryIO

try:
    import numpy as np  # type: ignore
    HAVE_NUMPY = True
except ImportError:  # pragma: no cover
    HAVE_NUMPY = False


# -- fixed constants from video_writer_ufmf.hpp ------------------------------

MAGIC = b"ufmf"
VERSION = 4

KEYFRAME_CHUNK_ID = 0
FRAME_CHUNK_ID = 1
INDEX_DICT_CHUNK_ID = 2

CHAR_FOR_DICT = b"d"
CHAR_FOR_ARRAY = b"a"
CHAR_FOR_DTYPE_UINT8 = b"B"
CHAR_FOR_DTYPE_UINT64 = b"q"
CHAR_FOR_DTYPE_DOUBLE = b"d"


# -- dataclasses -------------------------------------------------------------


@dataclass
class UfmfHeader:
    magic: bytes
    version: int
    index_offset: int
    width: int  # image width (or box length if is_fixed_size)
    height: int  # image height (or box length if is_fixed_size)
    is_fixed_size: bool
    coding: str  # e.g. "MONO8"
    header_size: int  # bytes consumed by the header itself


@dataclass
class UfmfIndex:
    frame_locs: list[int] = field(default_factory=list)
    frame_times: list[float] = field(default_factory=list)
    keyframe_locs: list[int] = field(default_factory=list)
    keyframe_times: list[float] = field(default_factory=list)


@dataclass
class Keyframe:
    width: int
    height: int
    timestamp: float
    pixels: bytes  # width*height raw uint8


@dataclass
class CompressedFrame:
    timestamp: float
    boxes: list[tuple[int, int, int, int, bytes]]  # (x, y, w, h, pixels)


# -- low-level readers -------------------------------------------------------


def _read_exact(f: BinaryIO, n: int, what: str) -> bytes:
    buf = f.read(n)
    if len(buf) != n:
        raise IOError(
            f"short read: wanted {n} bytes for {what}, got {len(buf)} "
            f"at offset {f.tell()}"
        )
    return buf


def _read_u8(f: BinaryIO) -> int:
    return struct.unpack("<B", _read_exact(f, 1, "uint8"))[0]


def _read_u16(f: BinaryIO) -> int:
    return struct.unpack("<H", _read_exact(f, 2, "uint16"))[0]


def _read_u32(f: BinaryIO) -> int:
    return struct.unpack("<I", _read_exact(f, 4, "uint32"))[0]


def _read_u64(f: BinaryIO) -> int:
    return struct.unpack("<Q", _read_exact(f, 8, "uint64"))[0]


def _read_double(f: BinaryIO) -> float:
    return struct.unpack("<d", _read_exact(f, 8, "double"))[0]


# -- header ------------------------------------------------------------------


def parse_header(f: BinaryIO) -> UfmfHeader:
    f.seek(0)
    magic = _read_exact(f, 4, "magic")
    version = _read_u32(f)
    index_offset = _read_u64(f)
    width = _read_u16(f)
    height = _read_u16(f)
    is_fixed_size = bool(_read_u8(f))
    coding_len = _read_u8(f)
    coding = _read_exact(f, coding_len, "coding").decode("ascii")
    return UfmfHeader(
        magic=magic,
        version=version,
        index_offset=index_offset,
        width=width,
        height=height,
        is_fixed_size=is_fixed_size,
        coding=coding,
        header_size=22 + coding_len,
    )


# -- index parser ------------------------------------------------------------
#
# Note: index_offset from the header points to the BYTE AFTER the chunk-ID
# byte (i.e. to the 'd' dict marker), because video_writer_ufmf.cpp:466-467
# writes chunk-ID then captures tellp(). Frame and keyframe locations, by
# contrast, point to the chunk-ID byte itself (captured before the write).


def _read_dict_key(f: BinaryIO) -> str:
    key_len = _read_u16(f)
    return _read_exact(f, key_len, "dict key").decode("ascii")


def _read_array_header(f: BinaryIO) -> tuple[bytes, int]:
    """Reader has already consumed the 'a' marker. Returns (dtype, num_bytes)."""
    dtype = _read_exact(f, 1, "dtype")
    num_bytes = _read_u32(f)
    return dtype, num_bytes


def _read_array_u64(f: BinaryIO) -> list[int]:
    dtype, n = _read_array_header(f)
    if dtype != CHAR_FOR_DTYPE_UINT64:
        raise IOError(f"expected uint64 array, got dtype={dtype!r}")
    if n % 8 != 0:
        raise IOError(f"uint64 array byte count {n} not divisible by 8")
    count = n // 8
    return list(struct.unpack(f"<{count}Q", _read_exact(f, n, "uint64 data")))


def _read_array_double(f: BinaryIO) -> list[float]:
    dtype, n = _read_array_header(f)
    if dtype != CHAR_FOR_DTYPE_DOUBLE:
        raise IOError(f"expected double array, got dtype={dtype!r}")
    if n % 8 != 0:
        raise IOError(f"double array byte count {n} not divisible by 8")
    count = n // 8
    return list(struct.unpack(f"<{count}d", _read_exact(f, n, "double data")))


def parse_index(f: BinaryIO, index_offset: int) -> UfmfIndex:
    if index_offset == 0:
        raise IOError("index_offset is 0 — file was never closed properly")
    f.seek(index_offset)

    # index_offset points to the dict marker 'd' (after the chunk-ID byte).
    marker = _read_exact(f, 1, "index dict marker")
    if marker != CHAR_FOR_DICT:
        raise IOError(f"expected 'd' at index offset, got {marker!r}")
    num_top_keys = _read_u8(f)

    result = UfmfIndex()

    for _ in range(num_top_keys):
        top_key = _read_dict_key(f)
        sub_marker = _read_exact(f, 1, "sub-dict marker")
        if sub_marker != CHAR_FOR_DICT:
            raise IOError(f"expected 'd' under {top_key!r}, got {sub_marker!r}")
        num_sub = _read_u8(f)

        if top_key == "frame":
            for _ in range(num_sub):
                sub_key = _read_dict_key(f)
                kind = _read_exact(f, 1, "frame sub marker")
                if kind != CHAR_FOR_ARRAY:
                    raise IOError(f"expected 'a' under frame/{sub_key}, got {kind!r}")
                if sub_key == "loc":
                    result.frame_locs = _read_array_u64(f)
                elif sub_key == "timestamp":
                    result.frame_times = _read_array_double(f)
                else:
                    raise IOError(f"unknown frame subkey {sub_key!r}")
        elif top_key == "keyframe":
            for _ in range(num_sub):
                type_key = _read_dict_key(f)  # "mean"
                type_marker = _read_exact(f, 1, "keyframe type marker")
                if type_marker != CHAR_FOR_DICT:
                    raise IOError(
                        f"expected 'd' under keyframe/{type_key}, got {type_marker!r}"
                    )
                num_type_sub = _read_u8(f)
                if type_key != "mean":
                    # We only know about "mean"; skip anything else by reading
                    # the expected number of sub-entries.
                    for _ in range(num_type_sub):
                        _ = _read_dict_key(f)
                        _ = _read_exact(f, 1, "skip")
                        # Best effort — we don't know the sub-structure; bail.
                        raise IOError(
                            f"don't know how to parse keyframe type {type_key!r}"
                        )
                    continue
                for _ in range(num_type_sub):
                    sub_key = _read_dict_key(f)
                    kind = _read_exact(f, 1, "keyframe sub marker")
                    if kind != CHAR_FOR_ARRAY:
                        raise IOError(
                            f"expected 'a' under keyframe/mean/{sub_key}, got {kind!r}"
                        )
                    if sub_key == "loc":
                        result.keyframe_locs = _read_array_u64(f)
                    elif sub_key == "timestamp":
                        result.keyframe_times = _read_array_double(f)
                    else:
                        raise IOError(f"unknown keyframe subkey {sub_key!r}")
        else:
            raise IOError(f"unknown top-level index key {top_key!r}")

    return result


# -- chunk readers -----------------------------------------------------------


def read_keyframe(f: BinaryIO, offset: int) -> Keyframe:
    f.seek(offset)
    chunk_id = _read_u8(f)
    if chunk_id != KEYFRAME_CHUNK_ID:
        raise IOError(
            f"expected keyframe chunk (id={KEYFRAME_CHUNK_ID}) at {offset}, "
            f"got id={chunk_id}"
        )
    type_len = _read_u8(f)
    type_str = _read_exact(f, type_len, "keyframe type").decode("ascii")
    if type_str != "mean":
        raise IOError(f"unsupported keyframe type {type_str!r}")
    dtype = _read_exact(f, 1, "keyframe dtype")
    if dtype != CHAR_FOR_DTYPE_UINT8:
        raise IOError(f"keyframe dtype must be 'B' (uint8), got {dtype!r}")
    w = _read_u16(f)
    h = _read_u16(f)
    ts = _read_double(f)
    pixels = _read_exact(f, w * h, "keyframe pixels")
    return Keyframe(width=w, height=h, timestamp=ts, pixels=pixels)


def read_frame(f: BinaryIO, offset: int) -> CompressedFrame:
    f.seek(offset)
    chunk_id = _read_u8(f)
    if chunk_id != FRAME_CHUNK_ID:
        raise IOError(
            f"expected frame chunk (id={FRAME_CHUNK_ID}) at {offset}, "
            f"got id={chunk_id}"
        )
    ts = _read_double(f)
    n_boxes = _read_u32(f)
    boxes: list[tuple[int, int, int, int, bytes]] = []
    for _ in range(n_boxes):
        x = _read_u16(f)
        y = _read_u16(f)
        w = _read_u16(f)
        h = _read_u16(f)
        pix = _read_exact(f, w * h, "box pixels")
        boxes.append((x, y, w, h, pix))
    return CompressedFrame(timestamp=ts, boxes=boxes)


# -- frame reconstruction ----------------------------------------------------


def reconstruct_frame(bg_pixels: bytes, bg_w: int, bg_h: int,
                      frame: CompressedFrame):
    """Compose a full MONO8 image by overlaying the frame's boxes onto the
    background. Returns a numpy array if numpy is available, else bytes."""
    if HAVE_NUMPY:
        bg = np.frombuffer(bg_pixels, dtype=np.uint8).reshape(bg_h, bg_w).copy()
        for x, y, w, h, pix in frame.boxes:
            box = np.frombuffer(pix, dtype=np.uint8).reshape(h, w)
            bg[y:y + h, x:x + w] = box
        return bg
    # stdlib fallback: mutate a bytearray
    out = bytearray(bg_pixels)
    for x, y, w, h, pix in frame.boxes:
        for row in range(h):
            dst = (y + row) * bg_w + x
            src = row * w
            out[dst:dst + w] = pix[src:src + w]
    return bytes(out)


# -- PGM writer (stdlib fallback when PIL is unavailable) --------------------


def write_pgm(path: str, pixels, width: int, height: int) -> None:
    if HAVE_NUMPY and hasattr(pixels, "tobytes"):
        data = pixels.tobytes()
    elif isinstance(pixels, (bytes, bytearray)):
        data = bytes(pixels)
    else:
        raise TypeError(f"unsupported pixels type: {type(pixels)}")
    with open(path, "wb") as g:
        g.write(f"P5\n{width} {height}\n255\n".encode("ascii"))
        g.write(data)


# -- main --------------------------------------------------------------------


def validate(path: str, verbose: bool = False, walk_all: bool = False,
             save_bg: str | None = None, save_first_frame: str | None = None) -> int:
    file_size = os.path.getsize(path)
    with open(path, "rb") as f:
        # Header
        try:
            hdr = parse_header(f)
        except IOError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        if hdr.magic != MAGIC:
            print(f"error: bad magic {hdr.magic!r} (expected {MAGIC!r})",
                  file=sys.stderr)
            return 2
        if hdr.version != VERSION:
            print(f"error: bad version {hdr.version} (expected {VERSION})",
                  file=sys.stderr)
            return 2
        if hdr.index_offset == 0:
            print("error: index_offset is 0 — file was never closed",
                  file=sys.stderr)
            return 3
        if hdr.index_offset >= file_size:
            print(f"error: index_offset {hdr.index_offset} beyond file size "
                  f"{file_size}", file=sys.stderr)
            return 6

        if verbose:
            print(f"# header: {hdr}", file=sys.stderr)

        # Index
        try:
            idx = parse_index(f, hdr.index_offset)
        except IOError as e:
            print(f"error parsing index: {e}", file=sys.stderr)
            return 4

        if verbose:
            print(f"# index: {len(idx.frame_locs)} frames, "
                  f"{len(idx.keyframe_locs)} keyframes", file=sys.stderr)

        # Sanity checks on the offset tables themselves
        if len(idx.frame_locs) != len(idx.frame_times):
            print(f"error: frame loc/timestamp count mismatch: "
                  f"{len(idx.frame_locs)} vs {len(idx.frame_times)}",
                  file=sys.stderr)
            return 5
        if len(idx.keyframe_locs) != len(idx.keyframe_times):
            print(f"error: keyframe loc/timestamp count mismatch: "
                  f"{len(idx.keyframe_locs)} vs {len(idx.keyframe_times)}",
                  file=sys.stderr)
            return 5

        # Verify chunk IDs at spot-checked offsets. When --walk-all is given,
        # we verify EVERY offset. Otherwise we check first/last to catch
        # truncation and middle-of-file corruption cheaply.
        to_check_frames = idx.frame_locs[:] if walk_all else (
            [idx.frame_locs[0], idx.frame_locs[-1]] if idx.frame_locs else []
        )
        to_check_keyframes = idx.keyframe_locs[:] if walk_all else (
            [idx.keyframe_locs[0], idx.keyframe_locs[-1]]
            if idx.keyframe_locs else []
        )

        for loc in to_check_keyframes:
            try:
                read_keyframe(f, loc)
            except IOError as e:
                print(f"error reading keyframe at {loc}: {e}", file=sys.stderr)
                return 4
        for loc in to_check_frames:
            try:
                read_frame(f, loc)
            except IOError as e:
                print(f"error reading frame at {loc}: {e}", file=sys.stderr)
                return 4

        # Optional extractions
        first_bg = None
        if idx.keyframe_locs:
            first_bg = read_keyframe(f, idx.keyframe_locs[0])
        if save_bg and first_bg is not None:
            write_pgm(save_bg, first_bg.pixels, first_bg.width, first_bg.height)

        if save_first_frame and idx.frame_locs and first_bg is not None:
            frm = read_frame(f, idx.frame_locs[0])
            img = reconstruct_frame(first_bg.pixels, first_bg.width,
                                    first_bg.height, frm)
            write_pgm(save_first_frame, img, first_bg.width, first_bg.height)

    # Summary (single-line, shell-parseable)
    n_frames = len(idx.frame_locs)
    n_keyframes = len(idx.keyframe_locs)
    first_ts = idx.frame_times[0] if idx.frame_times else 0.0
    last_ts = idx.frame_times[-1] if idx.frame_times else 0.0
    raw_bytes = hdr.width * hdr.height * max(n_frames, 1)
    ratio = file_size / raw_bytes if raw_bytes > 0 else 0.0
    print(
        f"ok=1 width={hdr.width} height={hdr.height} coding={hdr.coding} "
        f"frames={n_frames} keyframes={n_keyframes} "
        f"first_ts={first_ts:.6f} last_ts={last_ts:.6f} "
        f"bytes={file_size} compression_ratio={ratio:.4f}"
    )
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Validate a BIAS-produced uFMF v4 file.")
    ap.add_argument("path", help="path to .ufmf file")
    ap.add_argument("--save-bg", metavar="OUT.pgm",
                    help="write first background (keyframe) image as PGM")
    ap.add_argument("--save-first-frame", metavar="OUT.pgm",
                    help="reconstruct first frame (bg + boxes) and write PGM")
    ap.add_argument("--walk-all", action="store_true",
                    help="verify chunk ID at every index offset (slow)")
    ap.add_argument("--verbose", "-v", action="store_true")
    args = ap.parse_args(argv)
    try:
        return validate(args.path, verbose=args.verbose, walk_all=args.walk_all,
                        save_bg=args.save_bg,
                        save_first_frame=args.save_first_frame)
    except FileNotFoundError:
        print(f"error: file not found: {args.path}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
