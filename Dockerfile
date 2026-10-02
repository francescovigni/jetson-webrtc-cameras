# Jetson Nano is arm64. We use a plain Debian arm64 base and do CPU-based
# H264 encoding (the C250 is only VGA/MJPEG, so software x264 is plenty and
# avoids dragging the L4T/GStreamer HW-encode stack onto JetPack 4.x).
# bookworm, not bullseye: Debian 11 LTS ended 2026-08-31 and its .deb pool is
# gone from both deb.debian.org and archive.debian.org, so bullseye no longer
# builds at all. bookworm ships ffmpeg 5.1 — same features this pipeline uses.
FROM arm64v8/debian:bookworm-slim

# Pin MediaMTX so builds are reproducible. arm64v8 asset.
ARG MEDIAMTX_VERSION=v1.9.3

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        alsa-utils \
        busybox \
        ca-certificates \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Fetch the single static MediaMTX binary (Go, no deps).
RUN wget -qO /tmp/mediamtx.tgz \
        "https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_linux_arm64v8.tar.gz" \
    && tar -xzf /tmp/mediamtx.tgz -C /usr/local/bin mediamtx \
    && rm /tmp/mediamtx.tgz \
    && chmod +x /usr/local/bin/mediamtx

COPY mediamtx.yml    /etc/mediamtx.yml
COPY start-ffmpeg.sh /start-ffmpeg.sh
COPY entrypoint.sh   /entrypoint.sh
COPY web/            /web/

RUN chmod +x /start-ffmpeg.sh /entrypoint.sh

# 8080 = frontend page, 8889 = WebRTC/WHEP signalling+media (TCP),
# 8189/udp = WebRTC ICE/media.
EXPOSE 8080 8889 8189/udp

ENTRYPOINT ["/entrypoint.sh"]
