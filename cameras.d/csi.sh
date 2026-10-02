#!/bin/sh
# camera-label: CSI — IMX219 (video only)
# camera-audio: no
#
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
# nvarguscamerasrc reaches the sensor through nvargus-daemon over this socket,
# which is bind-mounted from the host. Overridable only so the check below is
# testable.
ARGUS_SOCKET="${ARGUS_SOCKET:-/tmp/argus_socket}"
RTSP_URL="rtsp://127.0.0.1:8554/${MTX_PATH:-csi}"

# Validate before handing anything to gst-launch: a malformed value otherwise
# surfaces as an opaque caps-negotiation failure, and runOnDemandRestart turns
# that into a silent restart loop.
die() { echo "[start-csi] $1"; exit 2; }

# A plain integer, at least 1. Used for every numeric knob below.
positive_int() {
    case "$2" in
        ''|*[!0-9]*) die "$1='$2' is not a non-negative integer" ;;
    esac
    [ "$2" -ge "$3" ] || die "$1='$2' must be >= $3"
}

case "${CSI_SIZE}" in
    *x*) ;;
    *)   die "CSI_SIZE='${CSI_SIZE}' is not WIDTHxHEIGHT" ;;
esac
# Width and height are checked SEPARATELY. Checking them concatenated hides an
# empty half: "1280x" and "x720" are both numeric once joined, and both reach
# gst-launch as width=1280,height= — the caps error plus restart loop this
# block exists to prevent.
W="${CSI_SIZE%x*}"
H="${CSI_SIZE#*x}"
positive_int "CSI_SIZE width"  "${W}" 1
positive_int "CSI_SIZE height" "${H}" 1
positive_int "CSI_FRAMERATE"   "${CSI_FRAMERATE}" 1
positive_int "CSI_SENSOR_ID"   "${CSI_SENSOR_ID}" 0
case "${CSI_BITRATE}" in
    ''|*[!0-9]*) die "CSI_BITRATE='${CSI_BITRATE}' must be bits/s as an integer, not e.g. 4M" ;;
esac
positive_int "CSI_BITRATE" "${CSI_BITRATE}" 1

# Without the socket there is no ISP and no sensor. Say so plainly: the usual
# causes are a missing bind mount, or nvargus-daemon not running on the host.
# Note that a daemon RESTART on the host replaces this socket's inode, which a
# single-file bind mount cannot follow — the container must be restarted too.
[ -S "${ARGUS_SOCKET}" ] || die "no argus socket at ${ARGUS_SOCKET} — is nvargus-daemon running on the HOST, and is the socket bind-mounted? A host daemon restart also requires restarting this container."

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
