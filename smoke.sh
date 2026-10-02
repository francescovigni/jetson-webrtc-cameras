#!/bin/sh
# Smoke check: every MediaMTX path named on the command line must publish a
# video stream. Defaults to both cameras.
#
#   docker exec webcam_home sh /smoke.sh          # usb and csi
#   docker exec webcam_home sh /smoke.sh usb      # just the USB camera
#
# Because the paths are runOnDemand, connecting IS the test: it forces
# MediaMTX to spawn the capture pipeline. Exits non-zero on the first path
# that does not come up.
set -u

PATHS="${*:-usb csi}"
RTSP_BASE="rtsp://127.0.0.1:8554"
# Generous: argus init plus the first keyframe is slower than FFmpeg's start.
TIMEOUT="${SMOKE_TIMEOUT:-30}"
# Paths that must publish video and NOTHING else. The CSI camera has no mic,
# and it must never open the C250's — doing so would hold the USB device open
# from the CSI pipeline and defeat the on-demand isolation. Settable so this
# rule is testable against a path that does carry audio.
VIDEO_ONLY="${SMOKE_VIDEO_ONLY:-csi}"

rc=0
for p in ${PATHS}; do
    printf '%-4s ' "${p}"
    out="$(timeout "${TIMEOUT}" ffprobe -v error -rtsp_transport tcp \
             -show_entries stream=codec_type \
             -of default=nw=1:nk=1 \
             "${RTSP_BASE}/${p}" 2>&1)"
    if echo "${out}" | grep -qx 'video'; then
        if echo " ${VIDEO_ONLY} " | grep -q " ${p} " && echo "${out}" | grep -qx 'audio'; then
            echo "FAIL  [$(echo "${out}" | tr '\n' ' ')] — audio on a video-only path"
            rc=1
            continue
        fi
        echo "OK  [$(echo "${out}" | tr '\n' ' ')]"
    else
        echo "FAIL"
        echo "${out}" | head -3 | sed 's/^/       /'
        rc=1
    fi
done

[ "${rc}" -eq 0 ] && echo "smoke: all paths OK"
exit "${rc}"
