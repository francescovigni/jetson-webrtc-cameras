#!/bin/sh
# Smoke check: every camera backend must publish a video stream, and a backend
# that declares no audio must not publish one.
#
#   docker exec webcam_home sh /smoke.sh          # every backend in /cameras.d
#   docker exec webcam_home sh /smoke.sh usb      # just one
#
# Both the list of cameras and the audio expectation come from /cameras.d, so
# adding a backend extends this check automatically — nothing here to edit.
#
# Because the paths are runOnDemand, connecting IS the test: it forces MediaMTX
# to spawn the capture pipeline.
set -u

CAMERA_DIR="${CAMERA_DIR:-/cameras.d}"
RTSP_BASE="${RTSP_BASE:-rtsp://127.0.0.1:8554}"
# Generous: argus init plus the first keyframe is slower than FFmpeg's start.
TIMEOUT="${SMOKE_TIMEOUT:-30}"

# Default to every backend present, in the same order MediaMTX configured them.
if [ "$#" -gt 0 ]; then
    PATHS="$*"
else
    PATHS=""
    for s in "${CAMERA_DIR}"/*.sh; do
        [ -f "${s}" ] && PATHS="${PATHS} $(basename "${s}" .sh)"
    done
fi
[ -n "${PATHS# }" ] || { echo "smoke: no camera backends found in ${CAMERA_DIR}" >&2; exit 2; }

# Does this backend declare audio? Unknown backends are not constrained.
declares_audio() {
    f="${CAMERA_DIR}/$1.sh"
    [ -f "${f}" ] || return 0
    case "$(sed -n 's/^# *camera-audio: *//p' "${f}" | head -n1)" in
        yes|true|1) return 0 ;;
        *)          return 1 ;;
    esac
}

rc=0
for p in ${PATHS}; do
    printf '%-6s ' "${p}"
    out="$(timeout "${TIMEOUT}" ffprobe -v error -rtsp_transport tcp \
             -show_entries stream=codec_type \
             -of default=nw=1:nk=1 \
             "${RTSP_BASE}/${p}" 2>&1)"
    tracks="$(echo "${out}" | tr '\n' ' ')"

    if ! echo "${out}" | grep -qx 'video'; then
        echo "FAIL  no video"
        echo "${out}" | head -3 | sed 's/^/         /'
        rc=1
        continue
    fi
    # A video-only backend must never open an audio device. On this hardware
    # that would also mean holding the USB camera open from another pipeline.
    if ! declares_audio "${p}" && echo "${out}" | grep -qx 'audio'; then
        echo "FAIL  [${tracks}] — audio on a backend that declares camera-audio: no"
        rc=1
        continue
    fi
    echo "OK    [${tracks}]"
done

[ "${rc}" -eq 0 ] && echo "smoke: all backends OK"
exit "${rc}"
