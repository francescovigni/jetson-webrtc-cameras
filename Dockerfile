# Jetson Nano is arm64. The USB C250 is encoded in software (VGA/MJPEG in,
# x264 out) — cheap enough on the Nano. The onboard CSI camera cannot be:
# on JetPack 4.x the IMX219 delivers 10-bit Bayer (RG10) that FFmpeg cannot
# debayer and for which there is no ISP in the FFmpeg path. That needs
# GStreamer's nvarguscamerasrc (Tegra ISP, via nvargus-daemon) and
# nvv4l2h264enc (hardware H264), which only exist on an L4T base — hence this
# is no longer plain Debian.
#
# The tag must match the host's L4T series. This host is R32.7.6, so r32.7.x.
# Check with: cat /etc/nv_tegra_release
ARG L4T_VERSION=r32.7.1
FROM nvcr.io/nvidia/l4t-base:${L4T_VERSION}

# Pin MediaMTX so builds are reproducible. arm64v8 asset.
ARG MEDIAMTX_VERSION=v1.9.3

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        alsa-utils \
        busybox \
        ca-certificates \
        wget \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-rtsp \
    && rm -rf /var/lib/apt/lists/*

# Fail the build, not the stream, if the CSI publisher element is missing.
# gstreamer1.0-rtsp is what provides it; verified on this base.
RUN gst-inspect-1.0 rtspclientsink > /dev/null

# Fetch the single static MediaMTX binary (Go, no deps).
RUN wget -qO /tmp/mediamtx.tgz \
        "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64v8.tar.gz" \
    && tar -xzf /tmp/mediamtx.tgz -C /usr/local/bin mediamtx \
    && rm /tmp/mediamtx.tgz \
    && chmod +x /usr/local/bin/mediamtx

# The base config carries everything but `paths:`; entrypoint.sh generates that
# from /cameras.d/ at startup, so adding a camera touches neither this file nor
# mediamtx.yml.
COPY mediamtx.yml    /etc/mediamtx.base.yml
COPY cameras.d/      /cameras.d/
COPY smoke.sh        /smoke.sh
COPY entrypoint.sh   /entrypoint.sh
COPY web/            /web/

RUN chmod +x /cameras.d/*.sh /smoke.sh /entrypoint.sh

# 8080 = frontend page, 8889 = WebRTC/WHEP signalling+media (TCP),
# 8189/udp = WebRTC ICE/media.
EXPOSE 8080 8889 8189/udp

ENTRYPOINT ["/entrypoint.sh"]
