#!/usr/bin/env bash
# phase3_record.sh — record a uFMF + AVI pair from BIAS on macOS and run
# the Python reader over the .ufmf output, as the Phase 3 validation
# harness. See docs/phase3-ufmf-validation.md for what the output means.
#
# Usage:
#   scripts/phase3_record.sh [--duration SECS] [--camera-port PORT]
#                            [--out-base NAME]
#
# Defaults:
#   duration    = 10 (seconds)
#   camera-port = 5010 (cam 0, typically the C922 if plugged in)
#   out-base    = phase3
#
# Exits 0 on full success, non-zero on any recording or validation error.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${REPO_ROOT}/build/test_gui.app"
READER="${REPO_ROOT}/scripts/ufmf_read.py"

DURATION=10
PORT=5010
OUT_BASE=phase3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration) DURATION="$2"; shift 2 ;;
        --camera-port) PORT="$2"; shift 2 ;;
        --out-base) OUT_BASE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: $APP_BUNDLE not found — build first" >&2
    exit 2
fi
if [[ ! -f "$READER" ]]; then
    echo "error: $READER not found" >&2
    exit 2
fi
if ! command -v jq >/dev/null; then
    echo "error: jq not installed (brew install jq)" >&2
    exit 2
fi

MOVIES="$HOME/Movies"
CFG_RAW=$(mktemp -t bias_cfg_raw.XXXX.json)
CFG_PATCHED=$(mktemp -t bias_cfg_patched.XXXX.json)
trap 'rm -f "$CFG_RAW" "$CFG_PATCHED"' EXIT

launch_app() {
    pkill -f "build/test_gui" 2>/dev/null || true
    sleep 1
    open "$APP_BUNDLE"
    # Wait for the HTTP server on the target port to come up
    local t=0
    while (( t < 15 )); do
        if curl -s --max-time 1 "http://127.0.0.1:${PORT}/?get-camera-guid" \
               | grep -q '"success" : true' 2>/dev/null; then
            return 0
        fi
        sleep 1; t=$((t + 1))
    done
    echo "error: test_gui didn't come up on port $PORT within 15s" >&2
    return 3
}

stop_app() {
    pkill -f "build/test_gui" 2>/dev/null || true
}

# Build a minimal logging-only config JSON (avoids round-tripping the full
# camera block, which would require setCameraFromMap to re-apply device
# settings that the AVF backend can't currently reapply cleanly).
# Output to stdout: one-line compact JSON of the form {"logging": {...}}.
build_logging_cfg() {
    local format=$1
    local filename=$2
    local raw_cfg=$3
    jq -c --arg fmt "$format" --arg name "$filename" \
       '{logging: (.[0].value.logging | .format = $fmt | .fileName = $name
                                      | .enabled = false)}' \
       <<< "$raw_cfg"
}

# POST a JSON payload as /?set-configuration=<URL-encoded>. BIAS's
# replaceEscapeChars table uses UPPERCASE hex (%2F, %7B, ...), and
# `curl --data-urlencode` produces lowercase hex, which BIAS silently
# fails to decode. So we encode with Python (uppercase) and pass as a
# literal URL.
post_set_configuration() {
    local port=$1
    local json=$2
    local url
    url=$(python3 - "$port" "$json" <<'PY'
import sys, urllib.parse
port, val = sys.argv[1], sys.argv[2]
print(f"http://127.0.0.1:{port}/?set-configuration={urllib.parse.quote(val, safe='')}")
PY
)
    curl -s --max-time 30 "$url"
}

record_format() {
    local format=$1
    local filename=$2

    echo ">> recording format=$format as $filename (${DURATION}s on port $PORT)"

    # 1. Launch + connect
    launch_app
    local guid
    guid=$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/?get-camera-guid" \
           | jq -r '.[0].value')
    echo "   camera guid=$guid"
    curl -s --max-time 10 "http://127.0.0.1:${PORT}/?connect" >/dev/null
    sleep 3

    # 2. Get + build logging-only config
    local cfg_raw
    cfg_raw=$(curl -s --max-time 5 "http://127.0.0.1:${PORT}/?get-configuration")
    if ! jq -e '.[0].success' <<< "$cfg_raw" >/dev/null; then
        echo "error: get-configuration failed after connect" >&2
        echo "$cfg_raw" >&2
        stop_app; return 4
    fi
    local cfg_patched
    cfg_patched=$(build_logging_cfg "$format" "$filename" "$cfg_raw")

    # 3. set-configuration
    local rsp
    rsp=$(post_set_configuration "$PORT" "$cfg_patched")
    if ! jq -e '.[0].success' <<< "$rsp" >/dev/null; then
        echo "error: set-configuration failed" >&2
        echo "$rsp" >&2
        stop_app; return 5
    fi

    # 4. enable-logging + start-capture
    curl -s --max-time 10 "http://127.0.0.1:${PORT}/?enable-logging" \
        | jq -r '.[0] | "enable-logging success=\(.success) msg=\(.message)"'
    curl -s --max-time 10 "http://127.0.0.1:${PORT}/?start-capture" \
        | jq -r '.[0] | "start-capture success=\(.success) msg=\(.message)"'

    # 5. Capture
    sleep "$DURATION"

    # 6. Read final status before stopping (for frame-count parity check)
    local status
    status=$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/?get-status")
    echo "$status" | jq -r '.[0].value | "bias stats: frameCount=\(.frameCount) framesPerSec=\(.framesPerSec) capturing=\(.capturing)"'
    local bias_frames
    bias_frames=$(jq -r '.[0].value.frameCount' <<< "$status")

    # 7. stop-capture + disable-logging
    curl -s --max-time 10 "http://127.0.0.1:${PORT}/?stop-capture" >/dev/null
    curl -s --max-time 10 "http://127.0.0.1:${PORT}/?disable-logging" >/dev/null
    sleep 2  # let writer flush

    stop_app

    # 8. Locate output file
    local out
    out=$(ls -t "$MOVIES"/*"$filename"*.${format} 2>/dev/null | head -1 || true)
    if [[ -z "$out" ]]; then
        echo "error: no output file matching $filename in $MOVIES" >&2
        return 6
    fi
    local bytes
    bytes=$(stat -f%z "$out")
    echo "   output: $out ($bytes bytes)"

    # 9. Format-specific validation
    if [[ "$format" == "ufmf" ]]; then
        local reader_out
        reader_out=$(python3 "$READER" "$out" 2>&1) || {
            echo "error: ufmf_read.py failed on $out" >&2
            echo "$reader_out" >&2
            return 7
        }
        echo "   reader: $reader_out"
        local file_frames
        file_frames=$(grep -oE 'frames=[0-9]+' <<< "$reader_out" | head -1 | cut -d= -f2)
        echo "   parity: bias=$bias_frames file=$file_frames delta=$((bias_frames - file_frames))"
    elif [[ "$format" == "avi" ]]; then
        if command -v ffprobe >/dev/null; then
            local probe
            probe=$(ffprobe -v error -select_streams v:0 \
                    -show_entries stream=width,height,nb_frames,codec_name \
                    -of csv=s=,:p=0 "$out" 2>&1 || true)
            echo "   ffprobe: $probe"
        else
            echo "   ffprobe not installed; skipping AVI inspection"
        fi
    fi

    # Export for summary
    LAST_OUT="$out"
    LAST_BYTES="$bytes"
    LAST_BIAS_FRAMES="$bias_frames"
    LAST_FILE_FRAMES="${file_frames:-}"
    return 0
}

echo "=== Phase 3 validation run ==="
echo "  repo         : $REPO_ROOT"
echo "  app bundle   : $APP_BUNDLE"
echo "  duration     : ${DURATION}s"
echo "  camera port  : $PORT"
echo "  output dir   : $MOVIES"
echo

record_format "ufmf" "${OUT_BASE}_ufmf"
UFMF_OUT="$LAST_OUT"; UFMF_BYTES="$LAST_BYTES"
UFMF_BIAS="$LAST_BIAS_FRAMES"; UFMF_FILE="$LAST_FILE_FRAMES"

echo
record_format "avi" "${OUT_BASE}_avi"
AVI_OUT="$LAST_OUT"; AVI_BYTES="$LAST_BYTES"; AVI_BIAS="$LAST_BIAS_FRAMES"

echo
echo "=== summary ==="
echo "  uFMF : $UFMF_OUT  (${UFMF_BYTES} bytes, bias=${UFMF_BIAS} file=${UFMF_FILE})"
echo "  AVI  : $AVI_OUT  (${AVI_BYTES} bytes, bias=${AVI_BIAS})"
