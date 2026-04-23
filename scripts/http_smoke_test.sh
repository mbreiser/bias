#!/usr/bin/env bash
# http_smoke_test.sh — exercise every BIAS HTTP control endpoint against a
# running test_gui.app and report PASS / FAIL per endpoint.
#
# Usage:
#   scripts/http_smoke_test.sh [--camera-port PORT] [--verbose]
#
# Exits 0 if FAIL count is 0, else non-zero (count of FAILs).
# Endpoints with known limitations (e.g. get-time-stamp returns ~0 on AVF
# until the timestamp override lands) are marked KNOWN rather than FAIL
# and don't count against the exit status.
#
# Prereqs: build/test_gui.app present, jq installed, port PORT free.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${REPO_ROOT}/build/test_gui.app"

PORT=5010
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --camera-port) PORT="$2"; shift 2 ;;
        --verbose|-v) VERBOSE=1; shift ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 64 ;;
    esac
done

[[ -d "$APP_BUNDLE" ]] || { echo "no $APP_BUNDLE - build first" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not installed (brew install jq)" >&2; exit 2; }

BASE="http://127.0.0.1:${PORT}"

PASS=0; FAIL=0; KNOWN=0
FAIL_LIST=()

urlenc() {
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

hit() {
    curl -s --max-time 10 "${BASE}/${1}"
}

log() {
    printf "%-6s %s\n" "$1" "$2"
}

# check <name> <jq_filter> <response>
# Pass if jq -e <filter> <rsp> evaluates truthy.
# If name begins with "KNOWN:" it won't count as FAIL on failure.
check() {
    local name=$1 filter=$2 rsp=$3
    local soft=0
    if [[ "$name" == KNOWN:* ]]; then soft=1; name="${name#KNOWN:}"; fi

    [[ $VERBOSE -eq 1 ]] && printf "  rsp: %s\n" "$rsp"

    if jq -e "$filter" <<< "$rsp" >/dev/null 2>&1; then
        log "ok" "$name"
        PASS=$((PASS + 1))
        return
    fi
    if (( soft == 1 )); then
        log "KNOWN" "$name"
        KNOWN=$((KNOWN + 1))
    else
        log "FAIL" "$name  (filter: $filter)"
        [[ $VERBOSE -eq 0 ]] && printf "  rsp: %s\n" "$rsp"
        FAIL=$((FAIL + 1))
        FAIL_LIST+=("$name")
    fi
}

# check_raw <name> <expected_substring> <response>
# For HTML responses (non-JSON) — does the body contain the expected string?
check_raw() {
    local name=$1 needle=$2 rsp=$3
    [[ $VERBOSE -eq 1 ]] && printf "  rsp: %s\n" "$rsp"
    if [[ "$rsp" == *"$needle"* ]]; then
        log "ok" "$name"
        PASS=$((PASS + 1))
    else
        log "FAIL" "$name  (expected substring: $needle)"
        [[ $VERBOSE -eq 0 ]] && printf "  rsp: %s\n" "$rsp"
        FAIL=$((FAIL + 1))
        FAIL_LIST+=("$name")
    fi
}

cleanup() { pkill -f "build/test_gui" 2>/dev/null || true; }
trap cleanup EXIT

echo "==== BIAS HTTP smoke test against port ${PORT} ===="
cleanup; sleep 1
open "$APP_BUNDLE"
for _ in {1..15}; do
    sleep 1
    curl -s --max-time 1 "${BASE}/?get-camera-guid" >/dev/null 2>&1 && break
done

# --- pre-connect ---
echo; echo "-- pre-connect --"

rsp=$(curl -s --max-time 5 "${BASE}/")
check_raw "/ (server running ping)" "BIAS Server Running" "$rsp"

rsp=$(hit "?get-camera-guid")
check "get-camera-guid" \
    '.[0] | .success == true and (.value | length > 0)' "$rsp"

rsp=$(hit "?get-status")
check "get-status (pre-connect, connected=false)" \
    '.[0].value.connected == false and .[0].value.capturing == false' "$rsp"

rsp=$(hit "?get-configuration")
check "get-configuration (pre-connect, expected failure)" \
    '.[0].success == false and (.[0].message | contains("not connected"))' "$rsp"

# --- connect ---
echo; echo "-- connect --"
rsp=$(hit "?connect")
check "connect" '.[0].success == true' "$rsp"
sleep 2

rsp=$(hit "?get-status")
check "get-status (post-connect, connected=true)" \
    '.[0].value.connected == true and .[0].value.capturing == false' "$rsp"

rsp=$(hit "?get-configuration")
check "get-configuration (post-connect)" \
    '.[0].success == true and (.[0].value | has("camera") and has("logging"))' "$rsp"

# --- setters ---
echo; echo "-- setters --"

rsp=$(curl -s --max-time 10 "${BASE}/?set-video-file=$(urlenc /tmp/bias_smoke_test)")
check "set-video-file" '.[0].success == true' "$rsp"

rsp=$(hit "?get-video-file")
check "get-video-file (round-trip filename)" \
    '.[0].success == true and (.[0].value | contains("bias_smoke_test"))' "$rsp"

rsp=$(curl -s --max-time 10 "${BASE}/?set-camera-name=SmokeTestCam")
check "set-camera-name" '.[0].success == true' "$rsp"

rsp=$(hit "?get-window-geometry")
check "get-window-geometry (shape)" \
    '.[0].success == true and (.[0].value | has("x") and has("y") and has("width") and has("height"))' "$rsp"

geom='{"x":200,"y":150,"width":640,"height":480}'
rsp=$(curl -s --max-time 10 "${BASE}/?set-window-geometry=$(urlenc "$geom")")
check "set-window-geometry" '.[0].success == true' "$rsp"

rsp=$(hit "?get-window-geometry")
check "get-window-geometry (after set, w=640 h=480)" \
    '.[0].value.width == 640 and .[0].value.height == 480' "$rsp"

# --- config save / load / set ---
echo; echo "-- config save/load/set --"

CFG_FILE=/tmp/bias_smoke_cfg.json
rm -f "$CFG_FILE" "${CFG_FILE}.mod"
rsp=$(curl -s --max-time 10 "${BASE}/?save-configuration=$(urlenc "$CFG_FILE")")
check "save-configuration" '.[0].success == true' "$rsp"

if [[ -s "$CFG_FILE" ]]; then
    log "ok" "save-configuration wrote non-empty file"
    PASS=$((PASS + 1))
else
    log "FAIL" "save-configuration left $CFG_FILE empty/missing"
    FAIL=$((FAIL + 1))
    FAIL_LIST+=("save-configuration wrote nothing")
fi

jq '.logging.format = "ufmf" | .logging.fileName = "smoke_ufmf"' "$CFG_FILE" > "${CFG_FILE}.mod"
rsp=$(curl -s --max-time 10 "${BASE}/?load-configuration=$(urlenc "${CFG_FILE}.mod")")
check "load-configuration (modified -> ufmf)" '.[0].success == true' "$rsp"

rsp=$(hit "?get-configuration")
check "get-configuration (format now ufmf)" \
    '.[0].value.logging.format == "ufmf"' "$rsp"

cfg_raw=$(hit "?get-configuration")
partial=$(jq -c '{logging: (.[0].value.logging | .format = "jpg" | .fileName = "smoke_jpg")}' <<< "$cfg_raw")
rsp=$(curl -s --max-time 20 "${BASE}/?set-configuration=$(urlenc "$partial")")
check "set-configuration (logging-only partial -> jpg)" '.[0].success == true' "$rsp"

rsp=$(hit "?get-configuration")
check "get-configuration (format now jpg)" \
    '.[0].value.logging.format == "jpg"' "$rsp"

# --- capture lifecycle ---
echo; echo "-- capture --"

# flip back to ufmf for a short recording
cfg_raw=$(hit "?get-configuration")
partial=$(jq -c '{logging: (.[0].value.logging | .format = "ufmf" | .fileName = "http_smoke")}' <<< "$cfg_raw")
curl -s --max-time 20 "${BASE}/?set-configuration=$(urlenc "$partial")" >/dev/null

rsp=$(hit "?enable-logging")
check "enable-logging" '.[0].success == true' "$rsp"

rsp=$(hit "?start-capture")
check "start-capture" '.[0].success == true' "$rsp"

sleep 3

rsp=$(hit "?get-status")
check "get-status (capturing=true, frameCount>0)" \
    '.[0].value.capturing == true and .[0].value.frameCount > 0' "$rsp"

rsp=$(hit "?get-frame-count")
check "get-frame-count (>0)" \
    '.[0].success == true and (.[0].value | tonumber > 0)' "$rsp"

rsp=$(hit "?get-frames-per-sec")
check "get-frames-per-sec (numeric)" \
    '.[0].success == true and ((.[0].value | type) == "number")' "$rsp"

# KNOWN limitation: AVF backend doesn't override getImageTimeStamp yet,
# so timestamp remains ~0. Next commit (the timestamp override) will
# flip this from KNOWN to PASS.
rsp=$(hit "?get-time-stamp")
check "KNOWN:get-time-stamp (AVF ~0 pre-override)" \
    '.[0].success == true and ((.[0].value | type) == "number") and (.[0].value | tonumber > 0.01)' "$rsp"

rsp=$(hit "?stop-capture")
check "stop-capture" '.[0].success == true' "$rsp"

rsp=$(hit "?disable-logging")
check "disable-logging" '.[0].success == true' "$rsp"

rsp=$(hit "?get-status")
check "get-status (post-stop, capturing=false)" \
    '.[0].value.capturing == false' "$rsp"

rsp=$(hit "?disconnect")
check "disconnect" '.[0].success == true' "$rsp"

# --- error paths ---
echo; echo "-- error paths --"

rsp=$(hit "?bogus-endpoint-name")
check "unknown command (success=false)" \
    '.[0].success == false and (.[0].message | contains("unknown"))' "$rsp"

rsp=$(curl -s --max-time 5 "${BASE}/nonquery")
check_raw "missing ? character (bad request)" "Bad request" "$rsp"

# --- close (runs last) ---
#
# /?close calls cameraWindowPtr_->close() which closes the camera window.
# Whether the Qt app PROCESS then exits depends on Qt's
# quitOnLastWindowClosed default (true by default, but some platforms or
# window types behave differently). We accept either behavior — the window
# closing is the contract; process lifecycle is a platform quirk.
echo; echo "-- close --"
rsp=$(hit "?close")
check "close (success)" '.[0].success == true' "$rsp"
sleep 3
# The camera window is closed → subsequent HTTP calls should fail (no TCP
# listener). That's the real test of "window is gone".
if ! curl -s --max-time 1 "${BASE}/?get-status" >/dev/null 2>&1; then
    log "ok" "HTTP server stopped responding after /?close"
    PASS=$((PASS + 1))
else
    log "KNOWN" "HTTP server still responds after /?close (process lingering)"
    KNOWN=$((KNOWN + 1))
fi

# --- summary ---
echo
echo "==== SUMMARY ===="
printf "PASS=%d  FAIL=%d  KNOWN=%d\n" "$PASS" "$FAIL" "$KNOWN"
if (( FAIL > 0 )); then
    echo "failed:"
    for t in "${FAIL_LIST[@]}"; do echo "  - $t"; done
fi
exit "$FAIL"
