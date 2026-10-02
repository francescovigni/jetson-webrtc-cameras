#!/bin/sh
# camera-label: USB — C250 (with mic)
# camera-audio: yes
#
# Builds and runs the FFmpeg capture pipeline that publishes the C250 into
# MediaMTX. Invoked by MediaMTX via runOnDemand (and re-invoked on restart),
# so devices are re-detected on every (re)start — robust to USB re-plug.
set -u

VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
VIDEO_SIZE="${VIDEO_SIZE:-640x480}"
FRAMERATE="${FRAMERATE:-30}"
VBITRATE="${VBITRATE:-1M}"
ABITRATE="${ABITRATE:-64k}"
AUDIO_RATE="${AUDIO_RATE:-16000}"     # C250 mic supports 16000-48000 mono
# Pixel format from the camera. Empty = let v4l2 negotiate the native format.
# The C250 supports "mjpeg" at 640x480 (set via compose).
INPUT_FORMAT="${INPUT_FORMAT:-}"
RTSP_URL="rtsp://127.0.0.1:8554/${MTX_PATH:-usb}"

# --- choose the audio capture card -----------------------------------------
# Pick the USB audio card by NAME. We deliberately do NOT probe it in
# isolation: combo webcams like the C250 only stream audio while their VIDEO
# interface is active, so an isolated capture returns "Input/output error"
# even though the mic works fine in the real (A/V) pipeline. Matching "usb"
# also skips the Jetson's dummy onboard card (tegra ADMAIF), which never
# delivers samples.
if [ -n "${AUDIO_CARD:-}" ]; then
    CARD="${AUDIO_CARD}"
else
    CARD="$(arecord -l 2>/dev/null | grep -i 'usb' | sed -n 's/^card \([0-9][0-9]*\):.*/\1/p' | head -n1)"
fi

# --- shared video args ------------------------------------------------------
if [ -n "${INPUT_FORMAT}" ]; then
    VFMT="-input_format ${INPUT_FORMAT}"
else
    VFMT=""
fi

# -use_wallclock_as_timestamps 1: the C250 emits duplicate MJPEG timestamps;
#   stamping with the wall clock gives the muxer monotonic PTS/DTS.
# -tune zerolatency + ultrafast: low-latency software H264 on the Nano.
# baseline/yuv420p: maximum browser WebRTC compatibility.
# thread_queue_size: absorbs USB jitter so capture never blocks the encoder.
VIDEO_IN="-use_wallclock_as_timestamps 1 -thread_queue_size 1024 -f v4l2 ${VFMT} -video_size ${VIDEO_SIZE} -framerate ${FRAMERATE} -i ${VIDEO_DEV}"
VIDEO_OUT="-c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -pix_fmt yuv420p -g ${FRAMERATE} -b:v ${VBITRATE} -maxrate ${VBITRATE} -bufsize 2M"

run_video_only() {
    echo "[start-ffmpeg] streaming VIDEO ONLY -> ${RTSP_URL}"
    # shellcheck disable=SC2086
    exec ffmpeg -hide_banner -loglevel warning \
        ${VIDEO_IN} -map 0:v:0 ${VIDEO_OUT} \
        -f rtsp -rtsp_transport tcp "${RTSP_URL}"
}

if [ -z "${CARD}" ]; then
    echo "[start-ffmpeg] no USB audio card found"
    run_video_only
fi

# --- try A/V together (the mode in which the C250 mic actually streams) -----
ADEV="plughw:${CARD},0"
echo "[start-ffmpeg] A/V: video ${VIDEO_DEV} ${VIDEO_SIZE}@${FRAMERATE} + audio ${ADEV} @ ${AUDIO_RATE}Hz -> ${RTSP_URL}"
AUDIO_IN="-thread_queue_size 1024 -f alsa -ar ${AUDIO_RATE} -i ${ADEV}"
AUDIO_OUT="-c:a libopus -b:a ${ABITRATE} -ar 48000 -ac 1"

START="$(date +%s)"
# shellcheck disable=SC2086
ffmpeg -hide_banner -loglevel warning \
    ${VIDEO_IN} ${AUDIO_IN} \
    -map 0:v:0 -map 1:a:0 \
    ${VIDEO_OUT} ${AUDIO_OUT} \
    -f rtsp -rtsp_transport tcp "${RTSP_URL}"
RC=$?
ELAPSED=$(( $(date +%s) - START ))

# If the A/V pipeline died almost immediately the mic is unusable on this boot
# (e.g. genuinely dead, or a different USB mic that errors) — fall back to
# video-only so the stream still works and we don't restart-loop. If it ran a
# while then exited, it was a transient crash: just exit and let MediaMTX
# restart us, retrying WITH audio.
if [ "${ELAPSED}" -lt 8 ]; then
    echo "[start-ffmpeg] A/V pipeline failed after ${ELAPSED}s (rc=${RC}) -> video-only fallback"
    run_video_only
fi
echo "[start-ffmpeg] A/V pipeline exited after ${ELAPSED}s (rc=${RC}); MediaMTX will restart and retry with audio"
exit "${RC}"
