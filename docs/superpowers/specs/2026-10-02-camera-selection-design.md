# Browser-side camera selection: USB C250 ↔ onboard CSI IMX219

Date: 2026-10-02
Status: approved design, not yet implemented

## Intent

Today the container publishes exactly one stream (`cam`), fed by the USB
Logitech C250 on `/dev/video1`. The Jetson Nano also carries an onboard CSI
camera (IMX219 on `/dev/video0`) that is currently unused and not even mapped
into the container.

Goal: from the web page at `:8080`, pick which camera to watch and switch
between them without redeploying or editing config.

Success criteria:

- A control on the page switches between USB and CSI, both directions, without
  a page reload.
- The choice survives a reload.
- Only the camera being watched encodes, so the Nano is never running two
  encoders at once.
- The USB stream keeps its current behaviour, audio included.

Explicitly out of scope: audio on the CSI stream, dynamic device discovery,
more than these two fixed cameras, authentication on the stream.

## Decisions and why

### One container on an L4T base, not a sidecar

On JetPack 4.x the IMX219 presents 10-bit Bayer (`RG10`) on `/dev/video0`.
FFmpeg cannot debayer that — its v4l2 Bayer support is 8-bit only and there is
no ISP in the FFmpeg path. The supported route is GStreamer
`nvarguscamerasrc`, which reaches the sensor through nvargus-daemon and the
Tegra ISP. This is precisely the L4T/GStreamer stack the current Dockerfile
header says it avoided.

Three shapes were considered:

| Shape | Verdict |
|---|---|
| Single container on `nvcr.io/nvidia/l4t-base` | **Chosen.** |
| CSI as a separate L4T sidecar publishing into the same localhost RTSP | Rejected: MediaMTX `runOnDemand` can only spawn processes in its own container, so CSI would have to be always-on. |
| FFmpeg software debayer of `RG10`, no GStreamer | Rejected: format almost certainly unsupported, no ISP, and a 1080p software debayer is hopeless on a Nano. Retained only as a cheap probe check. |

On-demand encoding was the governing requirement, and one container is the
only shape where MediaMTX can start either pipeline itself.

Accepted cost: the base image changes from `arm64v8/debian:bullseye-slim` to
L4T (Ubuntu bionic), so the USB path moves from FFmpeg 4.3 to 3.4. Everything
that path uses — `v4l2` input, `libx264`, `libopus`, the rtsp muxer,
`-use_wallclock_as_timestamps` — exists in 3.4. The probe step confirms this
before the rewrite lands. The image also grows by roughly the size of
GStreamer.

### On-demand pipelines, replacing always-on

The current README calls always-on capture "the key to stability": clients
attaching and detaching never re-open the USB device. On-demand gives that up
deliberately, in exchange for never running two encoders on a Nano.

`runOnDemandCloseAfter: 10s` recovers most of what always-on protected — a page
reload, or a switch away and back, reuses the live pipeline instead of
re-opening the device. `runOnDemandStartTimeout: 15s` because argus
initialisation is slower than the 10s default.

### `rtspclientsink`, not `fdsink | ffmpeg`

A shell pipeline makes the shell the process MediaMTX signals on teardown, and
GStreamer or FFmpeg can be orphaned behind it. Publishing straight from
GStreamer keeps the pipeline a single process that dies cleanly.

### Two capture scripts, not one branching script

`start-ffmpeg.sh` stays byte-for-byte unchanged. Its `RTSP_URL` already reads
`${MTX_PATH:-cam}`, so renaming its MediaMTX path to `usb` needs no edit. CSI
logic lives in its own `start-csi.sh` rather than as a branch inside a script
that would then mix FFmpeg and GStreamer concerns.

### Breaking change

`/cam/whep` ceases to exist; the paths become `usb` and `csi`. No redirect
alias for `cam` — single-user deploy, the README is updated instead.

## Architecture

```
CSI IMX219 ──(host nvargus-daemon, /tmp/argus_socket)──► gst nvarguscamerasrc
                                                          │ nvv4l2h264enc (HW)
                                                          ▼
                                                     rtspclientsink
                                                          │
C250 ──/dev/video1──┐                                     │
                    ├─► FFmpeg (x264/Opus) ───────────────┼──► MediaMTX ──► WebRTC/WHEP ──► browser
C250 mic ─/dev/snd──┘                                                           │
                                                          busybox httpd ──► index.html (:8080)
```

Two MediaMTX paths, each with its own `runOnDemand` command. The browser
selects a camera purely by choosing which WHEP URL to POST to; there is no
control endpoint and no server-side state.

## Components

### `mediamtx.yml`

Replace the single `cam` path with:

```yaml
paths:
  usb:
    runOnDemand: sh /start-ffmpeg.sh
    runOnDemandRestart: yes
    runOnDemandStartTimeout: 15s
    runOnDemandCloseAfter: 10s
  csi:
    runOnDemand: sh /start-csi.sh
    runOnDemandRestart: yes
    runOnDemandStartTimeout: 15s
    runOnDemandCloseAfter: 10s
```

Everything else in the file is unchanged; the API stays disabled.

### `start-csi.sh` (new)

Single GStreamer process, no pipe:

```sh
gst-launch-1.0 -q \
  nvarguscamerasrc sensor-id="${CSI_SENSOR_ID}" ! \
  "video/x-raw(memory:NVMM),width=${W},height=${H},framerate=${CSI_FRAMERATE}/1,format=NV12" ! \
  nvv4l2h264enc insert-sps-pps=1 idrinterval="${CSI_FRAMERATE}" \
      bitrate="${CSI_BITRATE}" control-rate=1 profile=0 maxperf-enable=1 ! \
  h264parse ! \
  rtspclientsink location="rtsp://127.0.0.1:8554/${MTX_PATH:-csi}" protocols=tcp
```

`W`/`H` are split from `CSI_SIZE`. `insert-sps-pps=1` plus `idrinterval` so a
WebRTC client joining late receives parameter sets. `profile=0` is Baseline,
matching the USB path's browser-compatibility choice. Encoding is in hardware,
so the CSI path costs almost no CPU.

### `Dockerfile`

- Base becomes `nvcr.io/nvidia/l4t-base:r32.7.1`, kept as an `ARG` next to the
  existing `MEDIAMTX_VERSION` arg. `r32.7.1` is the JetPack 4.6.x tag; the
  probe step reads `/etc/nv_tegra_release` on the host and the arg is corrected
  to match before the first build.
- Add `gstreamer1.0-tools`, `gstreamer1.0-plugins-base`, `-good`, `-bad`, and
  `gstreamer1.0-rtsp`.
- Assert the publisher plugin exists at build time:
  `RUN gst-inspect-1.0 rtspclientsink >/dev/null` — a missing plugin fails the
  build rather than the stream. Drop the assert if the registry scan proves
  flaky without the nvidia runtime.
- `COPY start-csi.sh` and `smoke.sh`, `chmod +x` both.

### `docker-compose.yml`

- Add `runtime: nvidia` (the reason the file is pinned to schema 2.4 — v3
  dropped `runtime`).
- Bind mount `/tmp/argus_socket:/tmp/argus_socket`.
- Do **not** map `/dev/video0`: nvarguscamerasrc reaches the sensor through
  nvargus-daemon on the host, so that device node belongs to the daemon.
- `/dev/nvhost-*`, needed by the hardware encoder inside the container, should
  arrive via `runtime: nvidia`. Add explicit device maps only if the probe
  shows they do not.
- Add the four `CSI_*` environment variables below.

### `web/index.html`

The stream name becomes runtime state:

```js
const CAMS = { usb: "USB — C250", csi: "CSI — IMX219" };
const saved = localStorage.getItem("cam");
let cam = CAMS[saved] ? saved : "usb";
const whepUrl = () => `${location.protocol}//${location.hostname}:8889/${cam}/whep`;
```

A `<select>` joins the existing `.bar` alongside Unmute and Reconnect. Its
change handler stores the choice and calls `connect()`. The existing
`teardown()` and `generation` counter already make a mid-flight switch safe, so
no new reconnect logic is needed. `connect()` calls `whepUrl()` where it
previously read the `WHEP_URL` const.

On `loadedmetadata`, set the `.stage` element's `aspectRatio` from
`video.videoWidth / video.videoHeight`, so a 16:9 CSI frame is not letterboxed
inside a hardcoded 4:3 box.

Camera options are hardcoded: two physically fixed cameras, no discovery
endpoint. A camera that fails to start shows the page's existing
"Stream offline — retrying…" state; there is no separate availability probe.

### `script.sh`

Add `start-csi.sh` and `smoke.sh` to the `FILES` array. Without this the
deploy copies a tree whose MediaMTX config references a script that is not
there.

### `README.md`

Update the diagram, the paths (`cam` → `usb`/`csi`), the tuning table, and the
always-on claim, which on-demand makes false.

## Configuration

| Var | Default | Notes |
|---|---|---|
| `CSI_SENSOR_ID` | `0` | argus sensor index |
| `CSI_SIZE` | `1280x720` | must be a real IMX219 mode: 3264x2464@21, 1920x1080@30, 1640x1232@30 (native 4:3), 1280x720@60 |
| `CSI_FRAMERATE` | `30` | |
| `CSI_BITRATE` | `4000000` | bits per second; `nvv4l2h264enc` does not accept `4M` |

These stay knobs rather than constants on purpose: sensor modes, lens and ISP
exposure differ per board.

Existing `VIDEO_DEV`, `VIDEO_SIZE`, `FRAMERATE`, `INPUT_FORMAT`, `VBITRATE`,
`AUDIO_*` keep their current meaning and continue to apply to the USB path
only.

## Error handling

- A camera that will not start leaves its MediaMTX path empty; the WHEP POST
  fails and the page falls into its existing retry loop. The other camera is
  unaffected, because the paths are independent.
- `runOnDemandRestart: yes` restarts a pipeline that dies while someone is
  watching.
- The USB path keeps its A/V-then-video-only fallback in `start-ffmpeg.sh`
  unchanged, including the 8-second heuristic for a dead mic.
- Switching cameras tears the peer connection down through the existing
  `teardown()`; the `generation` counter discards in-flight callbacks from the
  previous camera.

## Verification

1. **Host probe, throwaway, before any repo change.** Over ssh:
   `cat /etc/nv_tegra_release` to fix the L4T tag, then
   `gst-launch-1.0 -e nvarguscamerasrc num-buffers=30 ! nvvidconv ! nvv4l2h264enc ! h264parse ! matroskamux ! filesink location=/tmp/csi.mkv`.
   A non-empty, playable file proves sensor, ISP and hardware encoder before
   anything is committed. Also confirm FFmpeg 3.4 on the L4T base still drives
   the USB pipeline.
2. **`smoke.sh`, the one kept check.** Runs in-container, `ffprobe`s
   `rtsp://127.0.0.1:8554/usb` and `rtsp://127.0.0.1:8554/csi`, and asserts a
   video stream on each. It fails if a path name, a capture pipeline, or
   on-demand startup breaks. No test framework.
3. **Browser.** Load `:8080`, switch both directions, confirm a reload
   remembers the choice and that audio still works on the USB camera.

## Risks

- The L4T base tag must match the host L4T release; a mismatch breaks the
  nvidia runtime's library mounts.
- FFmpeg 3.4 on bionic drives the USB path. Expected fine, confirmed by probe.
- Argus socket permissions may need more than `group_add: video`.
- On-demand replaces an always-on design the README credits for stability.
  `runOnDemandCloseAfter` is the mitigation; if device re-open turns out to be
  flaky in practice, the fallback is always-on for USB and on-demand for CSI
  only.

## Unrelated finding

`.env` in the project root contains a live Tailscale auth key in cleartext.
Rotate it if that file has ever left this machine. Separately, `script.sh`
claims it copies `.env` to the Jetson, but `FILES` does not include it.
