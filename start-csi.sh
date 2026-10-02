#!/bin/sh
# Publishes the Jetson's onboard CSI camera (IMX219) into MediaMTX. Invoked by
# MediaMTX via runOnDemand, so the sensor is opened only while someone is
# watching and re-detected on every restart.
#
# Deliberately NOT FFmpeg: on JetPack 4.x the IMX219 presents 10-bit Bayer
# (RG10) on /dev/video0, which FFmpeg cannot debayer and for which there is no
# ISP in the FFmpeg path. nvarguscamerasrc runs it through the Tegra ISP via
# nvargus-daemon, and nvv4l2h264enc encodes in hardware — so unlike the USB
# path, this one costs almost no CPU.
#
# Video only. The C250's mic is not usable here: it only delivers samples while
# its own video interface is open, and on-demand means the USB path is idle
# whenever this one is live.
set -u

CSI_SENSOR_ID="${CSI_SENSOR_ID:-0}"
CSI_SIZE="${CSI_SIZE:-1280x720}"
CSI_FRAMERATE="${CSI_FRAMERATE:-30}"
# Bits per second as an integer. nvv4l2h264enc rejects "4M".
CSI_BITRATE="${CSI_BITRATE:-4000000}"
RTSP_URL="rtsp://127.0.0.1:8554/${MTX_PATH:-csi}"

# Validate before handing anything to gst-launch: a malformed size otherwise
# surfaces as an opaque caps-negotiation failure, and runOnDemandRestart turns
# that into a silent restart loop.
W="${CSI_SIZE%x*}"
H="${CSI_SIZE#*x}"
case "${CSI_SIZE}" in
    *x*) ;;
    *)  echo "[start-csi] CSI_SIZE='${CSI_SIZE}' is not WIDTHxHEIGHT"; exit 2 ;;
esac
case "${W}${H}" in
    ''|*[!0-9]*) echo "[start-csi] CSI_SIZE='${CSI_SIZE}' has non-numeric dimensions"; exit 2 ;;
esac
case "${CSI_FRAMERATE}" in
    ''|*[!0-9]*) echo "[start-csi] CSI_FRAMERATE='${CSI_FRAMERATE}' is not an integer"; exit 2 ;;
esac
case "${CSI_BITRATE}" in
    ''|*[!0-9]*) echo "[start-csi] CSI_BITRATE='${CSI_BITRATE}' must be bits/s as an integer, not e.g. 4M"; exit 2 ;;
esac

echo "[start-csi] CSI sensor ${CSI_SENSOR_ID}: ${W}x${H}@${CSI_FRAMERATE}, hw-h264 ${CSI_BITRATE}bps -> ${RTSP_URL}"
echo "[start-csi] note: CSI_SIZE must be a real IMX219 mode (3264x2464@21, 1920x1080@30, 1640x1232@30, 1280x720@60)"

# insert-sps-pps=1 and idrinterval: a WebRTC viewer joining mid-stream needs
#   parameter sets and a keyframe, not just inter frames.
# profile=0 is Baseline, matching the USB path's browser-compatibility choice.
# One exec'd process, no shell pipeline: MediaMTX signals this PID on teardown,
#   and nothing is orphaned still holding the sensor.
exec gst-launch-1.0 -q \
    nvarguscamerasrc sensor-id="${CSI_SENSOR_ID}" ! \
    "video/x-raw(memory:NVMM),width=${W},height=${H},framerate=${CSI_FRAMERATE}/1,format=NV12" ! \
    nvv4l2h264enc insert-sps-pps=1 idrinterval="${CSI_FRAMERATE}" \
        bitrate="${CSI_BITRATE}" control-rate=1 profile=0 maxperf-enable=1 ! \
    h264parse ! \
    rtspclientsink location="${RTSP_URL}" protocols=tcp
