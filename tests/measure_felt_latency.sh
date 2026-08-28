#!/bin/bash
#
# What a viewer experiences, plus what it costs the server.
#
# Server CPU is not what a person sees. This reports the distribution of gaps
# between COMPLETED framebuffer updates - min, mean, percentiles and max, where
# the max is the stall you actually notice - alongside the server's CPU-seconds
# over the same window.
#
# Reference points measured on this machine (two displays, 5552x2715):
#
#   capture 12 FPS, defer 84 ms (before this work)
#       fps  8.1   mean 125 ms   p90 155 ms   max  174 ms   CPU 3.37 s / 15 s
#   capture 30 FPS, defer 10 ms, quality 5 (after)
#       fps 33.4   mean  30 ms   p90  40 ms   max  128 ms   CPU 5.55 s / 15 s
#
# The client runs on the SAME Mac as the server, so its decode competes for CPU
# and the network path is not real. Valid for comparing builds measured the same
# way; NOT valid as "what the iPad sees".
#
# usage: tests/measure_felt_latency.sh [seconds] [host] [port] [quality] [jpeg]
set -uo pipefail

SECONDS_TO_RUN=${1:-20}
HOST=${2:-127.0.0.1}
PORT=${3:-5900}
QUALITY=${4:-7}
JPEG=${5:-1}

BUILD_DIR=${BUILD_DIR:-build-release-arm64}
PROBE="$BUILD_DIR/vnc_probe"

if [ ! -x "$PROBE" ]; then
    echo "build the probe first: cmake --build $BUILD_DIR --target vnc_probe"
    exit 1
fi

PID=$(pgrep -x macVNC | head -1)
if [ -z "$PID" ]; then
    echo "macVNC is not running"
    exit 1
fi

cpu_seconds() {
    ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ' | awk -F: '
        NF==2 { printf "%.2f", $1*60 + $2 }
        NF==3 { printf "%.2f", $1*3600 + $2*60 + $3 }'
}

export DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH:-/opt/homebrew/opt/libvncserver/lib}

# libvncclient narrates the handshake on stderr; keep it for a failure, out of
# the way otherwise, so the output of this script is one comparable line.
CHATTER=$(mktemp)
before=$(cpu_seconds "$PID")
if ! result=$("$PROBE" "$HOST" "$PORT" stream "$SECONDS_TO_RUN" "$QUALITY" 6 "$JPEG" \
              2>"$CHATTER"); then
    echo "probe failed:"
    tail -5 "$CHATTER"
    rm -f "$CHATTER"
    exit 1
fi
after=$(cpu_seconds "$PID")
rm -f "$CHATTER"

printf '%s cpu_seconds=%s\n' "$result" \
    "$(echo "$after $before" | awk '{printf "%.2f", $1-$2}')"
