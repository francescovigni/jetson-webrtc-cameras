#!/bin/sh
# camera-label: Test pattern (no hardware)
# camera-audio: no
#
# The reference backend, and the smallest possible one. It needs no camera, so
# it is also how you check the plumbing on a box whose hardware is unplugged,
# misconfigured, or not there yet.
#
# A backend is ANY executable in /cameras.d/ that satisfies three rules:
#
#   1. Publish H264 to rtsp://127.0.0.1:8554/${MTX_PATH}. MediaMTX exports
#      MTX_PATH, and it always equals this file's name without .sh.
#   2. Stay in the foreground for as long as it is streaming. MediaMTX starts
#      you when a viewer attaches and signals your process group on teardown,
#      so `exec` your pipeline rather than backgrounding it — otherwise
#      something is left holding the device.
#   3. Exit non-zero, with a message, if your configuration is unusable.
#      runOnDemandRestart turns a silent failure into a restart loop.
#
# Audio is optional. Declare it in the `camera-audio:` header above so the
# player labels it correctly and smoke.sh knows whether audio is allowed.
set -u

TEST_SIZE="${TEST_SIZE:-640x480}"
TEST_FRAMERATE="${TEST_FRAMERATE:-15}"
RTSP_URL="rtsp://127.0.0.1:8554/${MTX_PATH:-test}"

echo "[test] generated ${TEST_SIZE}@${TEST_FRAMERATE} -> ${RTSP_URL}"

exec ffmpeg -hide_banner -loglevel warning \
    -f lavfi -i "testsrc=size=${TEST_SIZE}:rate=${TEST_FRAMERATE}" \
    -c:v libx264 -preset ultrafast -tune zerolatency \
    -profile:v baseline -pix_fmt yuv420p -g "${TEST_FRAMERATE}" \
    -f rtsp -rtsp_transport tcp "${RTSP_URL}"
