#!/bin/sh
set -e

# Serve the single-page frontend on :8080 (busybox httpd daemonizes).
echo "[entrypoint] serving frontend on :8080"
busybox httpd -p 0.0.0.0:8080 -h /web

# Hand off to MediaMTX (foreground). It will start the capture pipeline
# via runOnInit and serve WebRTC on :8889.
echo "[entrypoint] starting mediamtx"
exec /usr/local/bin/mediamtx /etc/mediamtx.yml
