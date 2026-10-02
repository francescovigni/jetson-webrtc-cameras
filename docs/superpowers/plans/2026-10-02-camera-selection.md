# Camera Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the browser choose between the USB Logitech C250 and the Jetson's onboard CSI IMX219, switching live without a reload or a redeploy.

**Architecture:** MediaMTX gains a second path. `usb` keeps the existing FFmpeg capture; `csi` runs a GStreamer pipeline through the Tegra ISP with hardware H264. Both are `runOnDemand`, so only the camera being watched encodes. The browser switches by choosing which WHEP URL to POST to — there is no control endpoint and no server-side state.

**Tech Stack:** MediaMTX 1.9.3, FFmpeg (v4l2 + libx264 + libopus), GStreamer 1.14 with `nvarguscamerasrc`/`nvv4l2h264enc`/`rtspclientsink`, busybox httpd, Docker Compose schema 2.4, plain ES2017 in a single static HTML file.

**Spec:** [docs/superpowers/specs/2026-10-02-camera-selection-design.md](../specs/2026-10-02-camera-selection-design.md)

## Global Constraints

- Base image: `nvcr.io/nvidia/l4t-base:r32.7.1`, pinned as a Dockerfile `ARG`. Host is L4T **R32.7.6**; the tag must stay in the R32.7 series.
- `docker-compose.yml` stays on schema **version "2.4"**. Compose v3 dropped `runtime:`, which this design needs.
- H264 **Baseline profile, yuv420p** on both paths. `nvv4l2h264enc profile=0`, `libx264 -profile:v baseline`.
- `CSI_BITRATE` is **bits per second** as an integer. `nvv4l2h264enc` rejects `4M`.
- `CSI_SIZE` must be a real IMX219 sensor mode: `3264x2464@21`, `1920x1080@30`, `1640x1232@30`, `1280x720@60`.
- No new ports. 8080/tcp, 8889/tcp, 8189/udp only.
- The CSI path is **video only**. It must never open the C250 or an ALSA device.
- Exactly two cameras, hardcoded. No discovery endpoint, no MediaMTX API — `api: no` stays.
- `/dev/video0` is **not** mapped into the container. nvarguscamerasrc reaches the sensor through nvargus-daemon via `/tmp/argus_socket`.
- `.env` is never committed. It is in `.gitignore` and holds a live Tailscale key.
- Deploy is `./script.sh` to `nvidia@bart` over SSH keys. Every file the container needs must be in that script's `FILES` array.

## Review Focus

Failure modes the spec implies but does not assign tests to. Each line's test is added to the task that owns the code.

1. A `localStorage` camera value that is not a real camera — left by an older build, hand-edited, or a JS builtin name like `constructor` — must fall back to USB rather than strand the player on a path that 404s forever. (Task 5)
2. Two viewers picking different cameras at the same time run both encoders, which is the exact thing on-demand was chosen to prevent. The spec never says what happens. (Task 4)
3. `CSI_SIZE` set to a value that is not a sensor mode, or not `WIDTHxHEIGHT` at all, must fail with a readable message instead of a GStreamer caps-negotiation wall or a silent restart loop. (Task 4)
4. Switching away and back inside the `runOnDemandCloseAfter` window must reuse the live pipeline, not race a closing one and kill the stream. (Task 3)
5. Switching cameras repeatedly and fast must not leave a stale `ontrack` callback binding the video element to the previous camera's stream. (Task 5)

---

## File Structure

| File | Responsibility |
|---|---|
| `Dockerfile` | L4T base, FFmpeg + GStreamer + MediaMTX install, copies the three scripts |
| `docker-compose.yml` | Device and socket passthrough, `runtime: nvidia`, all tuning env vars |
| `mediamtx.yml` | The two on-demand paths and nothing else |
| `start-ffmpeg.sh` | USB C250 capture, video + audio. **Unchanged by this plan.** |
| `start-csi.sh` | **New.** CSI IMX219 capture, video only, hardware encode |
| `smoke.sh` | **New.** The one automated check: every named path publishes video |
| `web/index.html` | Player plus the camera selector |
| `web/selftest.js` | **New.** Console assertions for the selector logic; ships under `web/`, which `script.sh` already copies |
| `script.sh` | Deploy. Its `FILES` array must list the new scripts |
| `README.md` | Documents paths, on-demand behaviour, CSI tuning |

---

### Task 1: Confirm the L4T base can actually do this

A gate, not a feature. It commits no product code. If it fails, stop and revisit the spec — the single-container shape is what makes on-demand possible, and losing it changes the design.

**Files:**
- Create: nothing. This runs throwaway commands on the Jetson.
- Modify: `docs/superpowers/specs/2026-10-02-camera-selection-design.md` (record the result)

**Interfaces:**
- Consumes: nothing.
- Produces: a confirmed answer to two questions every later task assumes — does `nvarguscamerasrc` work from inside `l4t-base:r32.7.1`, and does bionic's FFmpeg still drive the USB pipeline.

- [ ] **Step 1: Confirm bionic's apt archive is still alive for arm64**

The whole base-image choice rests on this. Debian 11 already died under this project once.

```bash
curl -sS -o /dev/null -w 'ports bionic: %{http_code}\n' \
  http://ports.ubuntu.com/ubuntu-ports/dists/bionic/InRelease
```

Expected: `ports bionic: 200`. Anything else and this task fails — report it and stop.

- [ ] **Step 2: Pull the base image on the Jetson**

```bash
ssh nvidia@bart 'docker pull nvcr.io/nvidia/l4t-base:r32.7.1'
```

Expected: pull completes. It is a large image on a slow disk; allow several minutes.

- [ ] **Step 3: Prove nvargus and GStreamer work from inside that image**

This is the decisive check. `--runtime nvidia` is already the Jetson's default runtime, but pass it explicitly so the test does not depend on daemon config.

```bash
ssh nvidia@bart 'docker run --rm --runtime nvidia \
  -v /tmp/argus_socket:/tmp/argus_socket \
  nvcr.io/nvidia/l4t-base:r32.7.1 bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
      gstreamer1.0-tools gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-rtsp
    gst-inspect-1.0 nvarguscamerasrc >/dev/null && echo PLUGIN_nvargus_OK
    gst-inspect-1.0 nvv4l2h264enc  >/dev/null && echo PLUGIN_nvenc_OK
    gst-inspect-1.0 rtspclientsink >/dev/null && echo PLUGIN_rtspsink_OK
    gst-launch-1.0 -e nvarguscamerasrc num-buffers=30 sensor-id=0 ! \
      \"video/x-raw(memory:NVMM),width=1280,height=720,framerate=30/1,format=NV12\" ! \
      nvv4l2h264enc insert-sps-pps=1 bitrate=4000000 profile=0 ! \
      h264parse ! matroskamux ! filesink location=/tmp/t.mkv
    test -s /tmp/t.mkv && echo CAPTURE_OK
  "'
```

Expected, all four: `PLUGIN_nvargus_OK`, `PLUGIN_nvenc_OK`, `PLUGIN_rtspsink_OK`, `CAPTURE_OK`.

If `rtspclientsink` is the only miss, the package name differs on this base — try `gstreamer1.0-rtsp` first, then `libgstrtspserver-1.0-0`, and record which worked. If `nvarguscamerasrc` is missing, the nvidia runtime is not mounting `/usr/lib/aarch64-linux-gnu/tegra`; report and stop.

- [ ] **Step 4: Prove bionic's FFmpeg still drives the USB camera**

The USB path is currently working software. Do not migrate the base until this passes.

```bash
ssh nvidia@bart 'docker run --rm --runtime nvidia \
  --device /dev/video1 --group-add video \
  nvcr.io/nvidia/l4t-base:r32.7.1 bash -c "
    set -e
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ffmpeg
    ffmpeg -version | head -1
    ffmpeg -hide_banner -loglevel error \
      -f v4l2 -input_format mjpeg -video_size 640x480 -framerate 30 \
      -i /dev/video1 -frames:v 30 \
      -c:v libx264 -preset ultrafast -profile:v baseline -pix_fmt yuv420p \
      -f mp4 -y /tmp/t.mp4
    test -s /tmp/t.mp4 && echo USB_ENCODE_OK
    ffmpeg -hide_banner -loglevel error -muxers 2>/dev/null | grep -q rtsp \
      && echo RTSP_MUXER_OK
    ffmpeg -hide_banner -loglevel error -encoders 2>/dev/null | grep -q libopus \
      && echo LIBOPUS_OK
  "'
```

Expected: an FFmpeg 3.4.x version line, then `USB_ENCODE_OK`, `RTSP_MUXER_OK`, `LIBOPUS_OK`.

If `libopus` is absent, the USB path loses audio on this base. Stop and report — that is a spec-level regression, not something to work around silently.

- [ ] **Step 5: Record the result in the spec and commit**

Append the outcome to the spec's Verification section, replacing the "Still open" paragraph with what was actually observed, including the FFmpeg version string.

```bash
git add docs/superpowers/specs/2026-10-02-camera-selection-design.md
git commit -m "docs: confirm l4t-base r32.7.1 runs nvargus and the USB pipeline

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Migrate the container to the L4T base, USB path untouched

One variable at a time. The path is still called `cam` and still `runOnInit` after this task. If the stream breaks here, the base image is the only suspect.

**Files:**
- Modify: `Dockerfile:1-8` (base image and build args), `Dockerfile:9-16` (packages)
- Modify: `docker-compose.yml` (add `runtime: nvidia`, the argus socket mount)

**Interfaces:**
- Consumes: the package names Task 1 confirmed.
- Produces: an image where both FFmpeg and GStreamer are available. Later tasks assume `gst-launch-1.0` and `rtspclientsink` exist at runtime.

- [ ] **Step 1: Capture the current working state as the thing not to break**

```bash
ssh nvidia@bart 'docker exec webcam_home ffprobe -v error -rtsp_transport tcp \
  -show_entries stream=codec_name,codec_type,width,height \
  -of default=nw=1 rtsp://127.0.0.1:8554/cam'
```

Expected now, and expected again at the end of this task:

```
codec_name=h264
codec_type=video
width=640
height=480
codec_name=opus
codec_type=audio
```

- [ ] **Step 2: Swap the base image and add GStreamer**

In `Dockerfile`, replace the `FROM` line and the package list. Keep the `MEDIAMTX_VERSION` arg and everything below the install untouched.

```dockerfile
# Jetson Nano is arm64. The onboard CSI camera (IMX219) delivers 10-bit Bayer
# that FFmpeg cannot debayer, so the CSI path needs GStreamer's
# nvarguscamerasrc (Tegra ISP) and nvv4l2h264enc (hardware H264). That is only
# available on an L4T base, which is why this is no longer plain Debian.
#
# The tag must match the host's L4T series: host is R32.7.6, so r32.7.x.
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
RUN gst-inspect-1.0 rtspclientsink > /dev/null
```

If Task 1 found a different package provides `rtspclientsink`, use that name here instead.

- [ ] **Step 3: Give the container the argus socket and the nvidia runtime**

In `docker-compose.yml`, inside the `webcam` service. Docker's default runtime on this host is already `nvidia`, but state it so the file does not depend on daemon config.

```yaml
    # Required for the CSI path: the nvidia runtime bind-mounts the Tegra
    # userspace libs (libargus, nvv4l2) that nvarguscamerasrc and
    # nvv4l2h264enc load. Compose schema 2.4 is kept because v3 dropped this.
    runtime: nvidia

    volumes:
      # nvargus-daemon runs on the HOST and owns /dev/video0. The CSI camera is
      # reached through this socket, which is why /dev/video0 is deliberately
      # not mapped in below.
      - "/tmp/argus_socket:/tmp/argus_socket"
```

- [ ] **Step 4: Deploy and verify the USB stream is byte-for-byte as capable as before**

```bash
./script.sh
```

Then repeat Step 1's probe. Expected: the same six lines, h264 640x480 plus opus. Audio present is the part most likely to regress on an older FFmpeg — if `codec_name=opus` is missing, stop.

- [ ] **Step 5: Confirm GStreamer is present at runtime**

```bash
ssh nvidia@bart 'docker exec webcam_home gst-inspect-1.0 nvarguscamerasrc | head -3
ssh nvidia@bart docker exec webcam_home gst-inspect-1.0 rtspclientsink | head -3'
```

Expected: plugin details for both, no "No such element or plugin".

- [ ] **Step 6: Commit**

```bash
git add Dockerfile docker-compose.yml
git commit -m "feat: move container to L4T base for CSI camera support

The IMX219 delivers 10-bit Bayer that FFmpeg cannot debayer, so the CSI
path needs nvarguscamerasrc and nvv4l2h264enc. Those only exist on an L4T
base with the nvidia runtime mounting the Tegra userspace libs.

USB path behaviour is unchanged and verified: h264 640x480 + opus.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Rename the path to `usb`, make it on-demand, add the smoke check

**Files:**
- Create: `smoke.sh`
- Modify: `mediamtx.yml:31-39` (the `paths:` block)
- Modify: `Dockerfile` (copy and chmod `smoke.sh`)
- Modify: `script.sh` (`FILES` array)

**Interfaces:**
- Consumes: the L4T image from Task 2.
- Produces: `/smoke.sh` in the container, taking MediaMTX path names as arguments and defaulting to `usb csi`. Exit 0 only if every named path publishes a video stream. Task 4 reuses it unchanged.

- [ ] **Step 1: Write the failing check**

Create `smoke.sh` in the project root. `timeout` wraps `ffprobe` rather than using FFmpeg's own `-timeout`, whose units differ between protocols and versions.

```sh
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

rc=0
for p in ${PATHS}; do
    printf '%-4s ' "${p}"
    out="$(timeout "${TIMEOUT}" ffprobe -v error -rtsp_transport tcp \
             -show_entries stream=codec_type \
             -of default=nw=1:nk=1 \
             "${RTSP_BASE}/${p}" 2>&1)"
    if echo "${out}" | grep -qx 'video'; then
        echo "OK  [$(echo "${out}" | tr '\n' ' ')]"
    else
        echo "FAIL"
        echo "${out}" | head -3 | sed 's/^/       /'
        rc=1
    fi
done

[ "${rc}" -eq 0 ] && echo "smoke: all paths OK"
exit "${rc}"
```

- [ ] **Step 2: Run it and watch it fail**

```bash
scp smoke.sh nvidia@bart:/tmp/smoke.sh
ssh nvidia@bart 'docker cp /tmp/smoke.sh webcam_home:/smoke.sh && \
  docker exec webcam_home sh /smoke.sh usb'
```

Expected: FAIL. The path is still called `cam`, so `usb` does not exist and ffprobe reports a 404-equivalent RTSP error. This is the point — the check can tell the difference.

- [ ] **Step 3: Rename the path and switch it to on-demand**

Replace the whole `paths:` block in `mediamtx.yml`:

```yaml
paths:
  # The USB Logitech C250: video + audio. Reachable at
  # http://<host>:8889/usb/whep
  usb:
    # On-demand, not runOnInit: with two cameras, always-on would mean two
    # encoders on a Nano. The pipeline starts when a viewer attaches and
    # lingers for runOnDemandCloseAfter, so a page reload or a switch away
    # and straight back reuses it instead of re-opening the USB device.
    runOnDemand: sh /start-ffmpeg.sh
    runOnDemandRestart: yes
    # Longer than the 10s default: v4l2 open plus the first keyframe.
    runOnDemandStartTimeout: 15s
    runOnDemandCloseAfter: 10s
```

- [ ] **Step 4: Ship the check with the image and the deploy**

In `Dockerfile`, extend the existing COPY and chmod lines:

```dockerfile
COPY mediamtx.yml    /etc/mediamtx.yml
COPY start-ffmpeg.sh /start-ffmpeg.sh
COPY smoke.sh        /smoke.sh
COPY entrypoint.sh   /entrypoint.sh
COPY web/            /web/

RUN chmod +x /start-ffmpeg.sh /smoke.sh /entrypoint.sh
```

In `script.sh`, add `smoke.sh` to `FILES`. Miss this and the deploy copies a tree whose Dockerfile references a file that is not there:

```bash
FILES=(Dockerfile docker-compose.yml mediamtx.yml entrypoint.sh start-ffmpeg.sh smoke.sh web README.md)
```

- [ ] **Step 5: Deploy and run the check**

```bash
./script.sh
ssh nvidia@bart 'docker exec webcam_home sh /smoke.sh usb'
```

Expected: `usb  OK  [video audio]` then `smoke: all paths OK`.

- [ ] **Step 6: Test the close-after window (Review Focus 4)**

Switching away and back must reuse the lingering pipeline, not race a closing one.

```bash
ssh nvidia@bart 'docker exec webcam_home sh /smoke.sh usb && \
  sleep 3 && docker exec webcam_home sh /smoke.sh usb && \
  echo REUSE_OK'
```

Expected: both runs OK, then `REUSE_OK`. In `docker logs webcam_home` the second run must **not** show a second `[start-ffmpeg]` banner — the pipeline was still alive inside the 10s window. Then confirm it does close:

```bash
ssh nvidia@bart 'sleep 15; docker logs --tail 5 webcam_home'
```

Expected: a log line showing the on-demand command was stopped after the last reader left.

- [ ] **Step 7: Commit**

```bash
git add smoke.sh mediamtx.yml Dockerfile script.sh
git commit -m "feat: rename the USB path to usb and make it on-demand

Adds smoke.sh, which forces each named MediaMTX path to spawn its
pipeline and asserts a video stream comes back.

On-demand replaces always-on because a second camera is coming and two
software encoders will not fit on a Nano. runOnDemandCloseAfter=10s keeps
a reload or a quick switch-back from re-opening the device.

BREAKING: /cam/whep is now /usb/whep.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: The CSI path

**Files:**
- Create: `start-csi.sh`
- Modify: `mediamtx.yml` (add the `csi` path)
- Modify: `Dockerfile` (copy and chmod `start-csi.sh`)
- Modify: `docker-compose.yml` (the four `CSI_*` env vars)
- Modify: `script.sh` (`FILES` array)

**Interfaces:**
- Consumes: `smoke.sh` from Task 3, unchanged. `MTX_PATH`, which MediaMTX exports to its `runOnDemand` command.
- Produces: MediaMTX path `csi`, video-only H264 Baseline. `web/index.html` in Task 5 hardcodes this exact path name.

- [ ] **Step 1: Write the failing check**

No new test file — Task 3's check already covers this, which is why it takes path names.

```bash
ssh nvidia@bart 'docker exec webcam_home sh /smoke.sh usb csi'
```

Expected: `usb  OK`, then `csi  FAIL`. The `csi` path does not exist yet.

- [ ] **Step 2: Write the CSI capture script**

Create `start-csi.sh`:

```sh
#!/bin/sh
# Publishes the Jetson's onboard CSI camera (IMX219) into MediaMTX. Invoked by
# MediaMTX via runOnDemand, so the sensor is opened only while someone is
# watching and re-detected on every restart.
#
# Deliberately NOT FFmpeg: on JetPack 4.x the IMX219 presents 10-bit Bayer
# (RG10) on /dev/video0, which FFmpeg cannot debayer and which has no ISP in
# the FFmpeg path. nvarguscamerasrc runs it through the Tegra ISP via
# nvargus-daemon, and nvv4l2h264enc encodes in hardware — so unlike the USB
# path, this one costs almost no CPU.
#
# Video only. The C250's mic is not usable here: it only delivers samples
# while its own video interface is open, and on-demand means the USB path is
# idle whenever this one is live.
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
# One exec'd process, no shell pipeline: MediaMTX signals this PID on
#   teardown, and nothing is orphaned still holding the sensor.
exec gst-launch-1.0 -q \
    nvarguscamerasrc sensor-id="${CSI_SENSOR_ID}" ! \
    "video/x-raw(memory:NVMM),width=${W},height=${H},framerate=${CSI_FRAMERATE}/1,format=NV12" ! \
    nvv4l2h264enc insert-sps-pps=1 idrinterval="${CSI_FRAMERATE}" \
        bitrate="${CSI_BITRATE}" control-rate=1 profile=0 maxperf-enable=1 ! \
    h264parse ! \
    rtspclientsink location="${RTSP_URL}" protocols=tcp
```

- [ ] **Step 3: Add the path, ship the script, wire the env vars**

Append to `paths:` in `mediamtx.yml`:

```yaml
  # The onboard CSI camera (IMX219), video only. Reachable at
  # http://<host>:8889/csi/whep
  csi:
    runOnDemand: sh /start-csi.sh
    runOnDemandRestart: yes
    # argus init is slower than v4l2 open.
    runOnDemandStartTimeout: 15s
    runOnDemandCloseAfter: 10s
```

In `Dockerfile`, beside the other scripts:

```dockerfile
COPY start-csi.sh    /start-csi.sh
```

and add `/start-csi.sh` to the existing `chmod +x` line.

In `script.sh`, add it to `FILES`:

```bash
FILES=(Dockerfile docker-compose.yml mediamtx.yml entrypoint.sh start-ffmpeg.sh start-csi.sh smoke.sh web README.md)
```

In `docker-compose.yml`, under `environment:`:

```yaml
      # --- CSI camera (onboard IMX219), video only ---
      # CSI_SIZE must be a real sensor mode: 3264x2464@21, 1920x1080@30,
      # 1640x1232@30 (native 4:3), 1280x720@60.
      - CSI_SENSOR_ID=0
      - CSI_SIZE=1280x720
      - CSI_FRAMERATE=30
      - CSI_BITRATE=4000000     # bits/s — nvv4l2h264enc rejects "4M"
```

- [ ] **Step 4: Deploy and run the check**

```bash
./script.sh
ssh nvidia@bart 'docker exec webcam_home sh /smoke.sh usb csi'
```

Expected:

```
usb  OK  [video audio]
csi  OK  [video]
smoke: all paths OK
```

`csi` showing `[video audio]` is a bug — the CSI path must never open an audio device.

- [ ] **Step 5: Test invalid configuration (Review Focus 3)**

A bad `CSI_SIZE` must say so, not loop.

```bash
ssh nvidia@bart 'docker exec -e CSI_SIZE=720p webcam_home sh /start-csi.sh; echo "rc=$?"'
```

Expected: `[start-csi] CSI_SIZE='720p' is not WIDTHxHEIGHT` and `rc=2`.

```bash
ssh nvidia@bart 'docker exec -e CSI_BITRATE=4M webcam_home sh /start-csi.sh; echo "rc=$?"'
```

Expected: the bits-per-second message and `rc=2`.

- [ ] **Step 6: Measure both cameras at once (Review Focus 2)**

Two viewers on different cameras defeats the point of on-demand. Find out what it actually costs before calling the design done.

```bash
ssh nvidia@bart 'docker exec -d webcam_home sh -c "ffprobe -v quiet -rtsp_transport tcp -i rtsp://127.0.0.1:8554/usb -t 30 2>/dev/null"
docker exec -d webcam_home sh -c "ffprobe -v quiet -rtsp_transport tcp -i rtsp://127.0.0.1:8554/csi -t 30 2>/dev/null"
sleep 10; top -bn1 | head -15; docker exec webcam_home sh /smoke.sh usb csi'
```

Record the load. Both paths must still report OK. The CSI encoder is hardware, so the only software encoder is the USB one and this should be survivable — but record the real number, and note it in the README's tuning section as the known ceiling. If both streams degrade, add a `ponytail:` comment on the `csi` path in `mediamtx.yml` naming the ceiling and the upgrade path (drop `FRAMERATE` for the USB path, or serve one camera at a time).

- [ ] **Step 7: Commit**

```bash
git add start-csi.sh mediamtx.yml Dockerfile docker-compose.yml script.sh
git commit -m "feat: publish the onboard CSI camera as a second path

nvarguscamerasrc through the Tegra ISP, nvv4l2h264enc in hardware,
published straight to MediaMTX by rtspclientsink — one process, so
teardown leaves nothing holding the sensor.

Video only: the C250 mic only streams while its own video interface is
open, and on-demand means the USB path is idle while this one is live.

CSI_SIZE/FRAMERATE/BITRATE are validated up front, because
runOnDemandRestart would otherwise turn a typo into a silent restart loop.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: The browser selector

**Files:**
- Modify: `web/index.html` — the `.bar` markup, the `<style>` block, and the script's stream constants and `connect()`

**Interfaces:**
- Consumes: MediaMTX paths `usb` and `csi` from Tasks 3 and 4.
- Produces: nothing other tasks depend on.

- [ ] **Step 1: Write the failing checks as a browser console script**

There is no JS test runner in this project and adding one for three branches is not worth it. These assertions run in the browser console on the deployed page, and each fails loudly if the selector logic breaks.

Save as `web/selftest.js` so it ships with the page and can be pasted or imported:

```js
// Selector self-check. Paste into the browser console on the player page.
// Reloads are required between cases because the camera is resolved once at
// load, so run each case, reload, and read the result.
(function () {
  const results = [];
  const check = (name, got, want) => {
    results.push(`${got === want ? "PASS" : "FAIL"}  ${name}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  };

  // 1. The selector exists and offers exactly the two cameras.
  const sel = document.getElementById("cam");
  check("selector present", !!sel, true);
  check("option count", sel ? sel.options.length : 0, 2);
  check("option values", sel ? [...sel.options].map(o => o.value).join(",") : "", "usb,csi");

  // 2. The selector reflects the camera actually being played.
  check("selector matches active path", sel ? sel.value : "",
        document.querySelector("video") ? window.__activeCam : "");

  // 3. Review Focus 1: a stored value that is not a camera must not be used.
  //    "constructor" is the nasty one — it is truthy on every object, so a
  //    plain `CAMS[stored]` test would wrongly accept it.
  for (const bad of ["cam", "", "constructor", "toString", "__proto__", "USB"]) {
    localStorage.setItem("cam", bad);
    const stored = localStorage.getItem("cam");
    const resolved = Object.prototype.hasOwnProperty.call(window.__CAMS, stored)
      ? stored : "usb";
    check(`rejects stored ${JSON.stringify(bad)}`, resolved, "usb");
  }
  localStorage.setItem("cam", window.__activeCam);

  console.log(results.join("\n"));
  return results.every(r => r.startsWith("PASS")) ? "ALL PASS" : "FAILURES ABOVE";
})();
```

- [ ] **Step 2: Run it and watch it fail**

Open `http://bart:8080`, paste the script into the console.

Expected: `FAIL  selector present: got false, want true`, and failures on the option checks. There is no `<select>` yet and no `window.__CAMS`.

- [ ] **Step 3: Add the selector markup and matching style**

In `web/index.html`, replace the `.bar` div:

```html
  <div class="bar">
    <span id="dot" class="dot"></span>
    <span id="status" class="status">Connecting…</span>
    <select id="cam" aria-label="Camera"></select>
    <button id="unmute">🔊 Unmute</button>
    <button id="reconnect" class="secondary">↻ Reconnect</button>
  </div>
```

In the `<style>` block, after the `button.secondary` rule, so the select does not look foreign next to the buttons:

```css
    select {
      background: #2a2d36; color: #e7e9ee; border: 0; border-radius: 8px;
      padding: .5rem .6rem; font-size: .9rem; cursor: pointer;
    }
```

- [ ] **Step 4: Make the stream name runtime state**

Replace these two lines:

```js
    const STREAM   = "cam";
    const WHEP_URL = `${location.protocol}//${location.hostname}:8889/${STREAM}/whep`;
```

with:

```js
    // Two physically fixed cameras on this Jetson, so they are hardcoded —
    // no discovery endpoint, and MediaMTX's API stays disabled.
    const CAMS = { usb: "USB — C250 (with mic)", csi: "CSI — IMX219 (video only)" };
    const DEFAULT_CAM = "usb";

    // hasOwnProperty, not `CAMS[stored]`: a stored value of "constructor" or
    // "toString" is truthy on any object and would strand the player on a
    // path that 404s forever. localStorage can also throw outright in a
    // private window, so every access is guarded.
    let stored = null;
    try { stored = localStorage.getItem("cam"); } catch (_) {}
    let cam = Object.prototype.hasOwnProperty.call(CAMS, stored) ? stored : DEFAULT_CAM;

    // Derived per connect(), not once: the camera changes at runtime. Host is
    // still taken from the page URL, so LAN and Tailscale both keep working.
    const whepUrl = () => `${location.protocol}//${location.hostname}:8889/${cam}/whep`;

    // Exposed only for web/selftest.js.
    window.__CAMS = CAMS;
```

- [ ] **Step 5: Point `connect()` at the current camera**

In `connect()`, the fetch currently reads `WHEP_URL`. Change it:

```js
        const res = await fetch(whepUrl(), {
```

And at the top of `connect()`, after `const myGen = ++generation;`, record what is playing so the self-check and the UI agree:

```js
      window.__activeCam = cam;
```

- [ ] **Step 6: Populate the dropdown and handle changes**

Add just above the existing `unmuteBtn` listener:

```js
    const camSel = document.getElementById("cam");
    for (const [value, label] of Object.entries(CAMS)) {
      camSel.add(new Option(label, value, false, value === cam));
    }

    camSel.addEventListener("change", () => {
      cam = camSel.value;
      try { localStorage.setItem("cam", cam); } catch (_) {}
      // connect() calls teardown() first, which bumps `generation` so any
      // in-flight callback from the previous camera becomes a no-op. That is
      // what makes fast repeated switching safe.
      connect();
    });

    // The two cameras have different aspect ratios; let the stage follow the
    // frame instead of letterboxing inside a hardcoded 4/3 box.
    video.addEventListener("loadedmetadata", () => {
      if (video.videoWidth && video.videoHeight) {
        document.querySelector(".stage").style.aspectRatio =
          `${video.videoWidth} / ${video.videoHeight}`;
      }
    });
```

- [ ] **Step 7: Deploy and run the checks**

```bash
./script.sh
```

Open `http://bart:8080`, paste `web/selftest.js` into the console.

Expected: `ALL PASS`, with the six "rejects stored" cases among them — that is Review Focus 1 covered.

- [ ] **Step 8: Test fast repeated switching (Review Focus 5)**

A stale `ontrack` must never bind the video element to the previous camera.

In the console:

```js
(async () => {
  const sel = document.getElementById("cam");
  for (let i = 0; i < 6; i++) {
    sel.value = i % 2 ? "csi" : "usb";
    sel.dispatchEvent(new Event("change"));
    await new Promise(r => setTimeout(r, 400));   // switch mid-negotiation
  }
  await new Promise(r => setTimeout(r, 6000));
  console.log("selected:", sel.value, "active:", window.__activeCam,
              "status:", document.getElementById("status").textContent,
              "tracks:", document.querySelector("video").srcObject?.getTracks().length);
})();
```

Expected: `selected` and `active` are the same camera, status reaches `Live`, and the picture matches the selected camera. A `csi` selection showing an audio track means a stale stream from the USB camera is still bound.

- [ ] **Step 9: Verify persistence and the aspect ratio by eye**

Select CSI, reload the page. Expected: it comes back on CSI, and the stage is 16:9 rather than a letterboxed 4:3. Switch to USB. Expected: the stage returns to 4:3 and Unmute produces sound.

- [ ] **Step 10: Commit**

```bash
git add web/index.html web/selftest.js
git commit -m "feat: let the browser pick the camera

A select in the player switches between the usb and csi WHEP paths and
remembers the choice. The existing teardown()/generation machinery
already makes a mid-negotiation switch safe, so no new reconnect logic.

A stored camera is validated with hasOwnProperty, not truthiness:
'constructor' and 'toString' are truthy on any object and would strand
the player on a path that 404s forever.

The stage now takes its aspect ratio from the frame, since the two
cameras are 4:3 and 16:9.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Documentation

The README currently describes a single always-on camera on a Debian base. Every one of those statements is now false.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the measured figures from Task 4 Step 6.
- Produces: nothing.

- [ ] **Step 1: Update the architecture diagram and the always-on claim**

Replace the diagram and the "Always-on capture" bullet. The replacement must state that capture is on-demand, that `runOnDemandCloseAfter` makes a reload or quick switch-back reuse the pipeline, and that only the camera being watched encodes.

```
C250 ──/dev/video1─┐
                   ├─► FFmpeg (x264/Opus) ──┐
C250 mic ─/dev/snd─┘                        │
                                            ├─► MediaMTX ─► WebRTC (WHEP) ─► browser
IMX219 ─(nvargus-daemon, /tmp/argus_socket)─┤                     │
        └─► gst nvarguscamerasrc ! nvv4l2h264enc ! rtspclientsink  │
                                                 busybox httpd ──► index.html (:8080)
```

- [ ] **Step 2: Document the two paths and the breaking change**

Add this section after the Ports table:

```markdown
## Cameras

| Camera | MediaMTX path | WHEP endpoint | Audio |
|---|---|---|---|
| USB Logitech C250 | `usb` | `http://<host>:8889/usb/whep` | yes, the C250 mic |
| Onboard CSI IMX219 | `csi` | `http://<host>:8889/csi/whep` | no |

Switch with the dropdown on the player page; the choice is remembered per
browser. Only the camera being watched encodes — capture starts when a viewer
attaches and stops ~10s after the last one leaves.

**Breaking change:** `/cam/whep` no longer exists. It was replaced by
`/usb/whep` when the second camera was added.

The CSI camera has no microphone, and the C250's mic cannot fill in: it only
delivers samples while the C250's own video interface is open, which it is not
while the CSI camera is the one being watched.
```

- [ ] **Step 3: Rewrite the video-device section**

The current text says `/dev/video0` is the unused onboard camera. Now it is the CSI camera, reached through nvargus-daemon rather than mapped into the container. Document that `/dev/video0` is deliberately absent from `devices:` and why, and keep the existing udev advice for the USB camera moving node numbers.

- [ ] **Step 4: Extend the tuning table and record the measured ceiling**

Add these rows to the existing Tuning table, and label the existing rows as USB-only:

```markdown
| Var             | Default   | Notes                                                        |
|-----------------|-----------|--------------------------------------------------------------|
| `CSI_SENSOR_ID` | 0         | argus sensor index                                           |
| `CSI_SIZE`      | 1280x720  | Must be a real IMX219 mode: 3264x2464@21, 1920x1080@30, 1640x1232@30 (native 4:3), 1280x720@60 |
| `CSI_FRAMERATE` | 30        | Capped by the sensor mode above                              |
| `CSI_BITRATE`   | 4000000   | **Bits per second as an integer.** `nvv4l2h264enc` rejects `4M`. |
```

Then add this note below the table, substituting the load figure measured in
Task 4 Step 6:

```markdown
Only the camera being watched encodes, so normally one encoder runs. The
exception is two viewers on *different* cameras at once: then the USB software
x264 encoder and the CSI hardware encoder run together. Measured load in that
case: <figure from Task 4 Step 6>. If that is too high, drop `FRAMERATE` for
the USB path.
```

- [ ] **Step 5: Add CSI troubleshooting**

Three failures worth naming: `nvarguscamerasrc` missing inside the container means the nvidia runtime is not mounting the Tegra libs; a caps-negotiation error means `CSI_SIZE` is not a real sensor mode; and `/tmp/argus_socket` absent or `nvargus-daemon` inactive on the host breaks the CSI path while leaving USB fine. Include the smoke check as the first diagnostic:

```bash
docker exec webcam_home sh /smoke.sh usb csi
```

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: document both camera paths and on-demand capture

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```
