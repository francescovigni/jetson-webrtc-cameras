# jetson-webrtc-cameras

Low-latency WebRTC streaming from **multiple camera backends** on an NVIDIA
Jetson Nano, switchable from a dropdown in the browser. One Docker container:
MediaMTX + FFmpeg + GStreamer + a static page.

Adding a camera means dropping one script into `cameras.d/`. Nothing else is
edited — not the MediaMTX config, not the Dockerfile, not the player.

```
┌─ cameras.d/usb.sh   ── FFmpeg, v4l2 → x264 + Opus ──┐
│                                                     │
├─ cameras.d/csi.sh   ── GStreamer, Tegra ISP → NVENC ┤──► MediaMTX ──► WHEP ──► browser
│                                                     │                  (WebRTC)
└─ cameras.d/test.sh  ── FFmpeg, test pattern ────────┘
       │
       └─ entrypoint.sh reads this directory and generates both the MediaMTX
          `paths:` block and the cameras.json the player fetches.
```

## Why more than one backend

Not architecture for its own sake — the hardware forces it.

The USB webcam is ordinary: `v4l2` into software x264 is cheap enough at VGA.
The Jetson's **onboard CSI camera cannot be done that way at all.** On JetPack
4.x the IMX219 presents 10-bit Bayer (`RG10`) on `/dev/video0`, which FFmpeg
cannot debayer, and there is no ISP anywhere in the FFmpeg path. It has to go
through GStreamer's `nvarguscamerasrc`, which reaches the sensor via
`nvargus-daemon` and the Tegra ISP, and `nvv4l2h264enc`, which encodes in
hardware.

So the two cameras need two genuinely different capture stacks, and the useful
question becomes: what is the smallest contract both can satisfy? That contract
is this project.

Measured on a 4-core Nano, which is why it matters:

| | Load average | Encoder cost |
|---|---|---|
| Idle, nobody watching | 0.34 | — |
| USB camera (software x264) | — | 66.3% of a core |
| CSI camera (hardware NVENC) | — | 10.9% of a core |
| A viewer on each at once | 1.07 | both of the above |

Only the camera being watched encodes. That is what makes two cameras fit.

## Add a camera backend

A backend is any executable in `cameras.d/`. Its filename without `.sh` is the
MediaMTX path name, so `cameras.d/front-door.sh` is served at
`http://<host>:8889/front-door/whep` and appears in the dropdown.

Three rules:

1. **Publish H264 to `rtsp://127.0.0.1:8554/${MTX_PATH}`.** MediaMTX exports
   `MTX_PATH`, and it always equals your filename without `.sh`.
2. **Stay in the foreground while streaming.** MediaMTX starts you when a viewer
   attaches and signals your process group on teardown, so `exec` your pipeline
   rather than backgrounding it — otherwise something is left holding the device.
3. **Exit non-zero, with a message, if your configuration is unusable.**
   `runOnDemandRestart` turns a silent failure into a restart loop.

Two comment headers carry presentation:

```sh
#!/bin/sh
# camera-label: Front door (RTSP)
# camera-audio: no
set -u
exec ffmpeg -hide_banner -loglevel warning \
    -rtsp_transport tcp -i "rtsp://user:pass@192.168.1.42/stream1" \
    -c:v copy -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/${MTX_PATH}"
```

Drop that in `cameras.d/`, redeploy, done. `cameras.d/test.sh` is the reference
implementation — it generates a test pattern, so it also works as a plumbing
check on a box whose camera is unplugged or not there yet.

`camera-audio` is not cosmetic: `smoke.sh` enforces it. A backend declaring
`no` that publishes an audio track fails the check.

## Cameras in this deployment

| Camera | Backend | Endpoint | Audio |
|---|---|---|---|
| USB Logitech C250 (`046d:0804`) | `cameras.d/usb.sh` | `:8889/usb/whep` | yes, the C250 mic |
| Onboard CSI IMX219 | `cameras.d/csi.sh` | `:8889/csi/whep` | no |
| Test pattern, no hardware | `cameras.d/test.sh` | `:8889/test/whep` | no |

The CSI camera has no microphone, and the C250's cannot stand in for it: that
mic only delivers samples while the C250's own video interface is open, which it
is not while another camera is the one being watched.

## How it works

- **On-demand capture.** Each backend gets a MediaMTX path with `runOnDemand`,
  so a camera is opened only while someone is watching it. `runOnDemandCloseAfter`
  (10s) means a page reload, or switching away and straight back, reuses the live
  pipeline instead of re-opening the device — the flip side being that for those
  10s after a switch the previous camera is still up.
- **The player `DELETE`s its WHEP session** on switch and on page unload. Without
  that, MediaMTX waits out the ICE disconnected timeout (~6s) before dropping the
  reader, and only then does the 10s linger begin — so one viewer switching camera
  ran both encoders for 16s.
- **Self-healing player.** `web/index.html` reconnects if its WebRTC link drops,
  and switching cameras reuses that machinery: a generation counter invalidates
  in-flight callbacks, so a switch mid-negotiation is safe.
- **Tailscale-friendly.** One TCP port for signalling, one UDP port for media, no
  multicast. The page derives its WHEP URL from the host you browsed to, so the
  same page works over LAN IP or Tailscale name with no edits.

### Ports

| Port | Purpose |
|---|---|
| 8080/tcp | Player page |
| 8889/tcp | WebRTC signalling (WHEP) + media |
| 8189/udp | WebRTC ICE / media |

## Requirements

- Jetson Nano on **JetPack 4.x** (developed against L4T **R32.7.6**). The base
  image is `nvcr.io/nvidia/l4t-base:r32.7.1`; the tag must match your host's L4T
  series — check with `cat /etc/nv_tegra_release`.
- Docker with the **nvidia runtime**, which bind-mounts the Tegra userspace libs
  the CSI backend needs. On JetPack it is usually the default already.
- `nvargus-daemon` running on the host (default on JetPack) for the CSI camera.
  The USB and test backends do not need it.

## Deploy

Deployment is `scp` over SSH plus `docker compose` on the target — no registry,
no CI. The image is built on the Jetson.

```bash
# One time: install your SSH key on the Jetson.
./script.sh setup-key

# Every deploy after that.
JETSON_USER=nvidia JETSON_HOST=my-jetson ./script.sh
```

Then open **http://&lt;jetson&gt;:8080**. Click **Unmute** for audio — browsers block
autoplay with sound until a click.

Host and user default to the values at the top of `script.sh`; override via env
as above.

## Verify

One command, run on the target. It forces every backend to spawn its pipeline
and asserts what comes back:

```bash
docker exec webcam_home sh /smoke.sh          # every backend
docker exec webcam_home sh /smoke.sh usb csi  # named ones
```

```
usb    OK    [video audio ]
csi    OK    [video ]
test   OK    [video ]
smoke: all backends OK
```

It exits non-zero if a backend publishes no video, or publishes audio while
declaring `camera-audio: no`.

For the player, open the page and run its assertions in the browser console:

```js
fetch('/selftest.js').then(r => r.text()).then(eval)
```

That checks the dropdown against `cameras.json`, and that a stored camera
preference which is not a real camera falls back to the default instead of
stranding the player on a path that 404s forever — including `constructor` and
`toString`, which are truthy on any JavaScript object and would pass a naive
check.

## Configuration

All via `environment:` in `docker-compose.yml`.

### Container

| Var | Default | Notes |
|---|---|---|
| `DEFAULT_CAMERA` | (first alphabetically) | Which camera the player opens on. Must match a `cameras.d/` filename without `.sh`. |
| `START_TIMEOUT` | 15s | How long a cold pipeline gets to produce its first frame. |
| `CLOSE_AFTER` | 10s | How long a pipeline lingers after the last viewer leaves. |

### USB backend

| Var | Default | Notes |
|---|---|---|
| `VIDEO_DEV` | /dev/video1 | Camera node |
| `VIDEO_SIZE` | 640x480 | C250 max is VGA |
| `FRAMERATE` | 30 | Drop to 15 to lighten CPU |
| `INPUT_FORMAT` | mjpeg | Empty = let v4l2 negotiate |
| `VBITRATE` | 1M | Video bitrate |
| `AUDIO_RATE` | 16000 | Mic capture rate; resampled to 48k Opus |
| `ABITRATE` | 64k | Opus bitrate |
| `AUDIO_CARD` | (auto: USB) | Pin an ALSA card number |

### CSI backend

| Var | Default | Notes |
|---|---|---|
| `CSI_SENSOR_ID` | 0 | argus sensor index |
| `CSI_SIZE` | 1280x720 | Must be a real IMX219 mode: 3264x2464@21, 1920x1080@30, 1640x1232@30 (native 4:3), 1280x720@60 |
| `CSI_FRAMERATE` | 30 | Capped by the sensor mode |
| `CSI_BITRATE` | 4000000 | **Bits per second, integer.** `nvv4l2h264enc` rejects `4M`. |

Width and height are validated separately, so `1280x` and `x720` are rejected
rather than reaching GStreamer as `height=` and restart-looping.

## Device notes

`/dev/video0` is the CSI camera, `/dev/video1` the USB one. Only the USB node is
in `devices:` — **`/dev/video0` is deliberately not mapped in**, because
`nvargus-daemon` on the host owns the sensor and `nvarguscamerasrc` reaches it
through the bind-mounted `/tmp/argus_socket`.

USB node numbers can move across reboots. To pin one:

```bash
echo 'SUBSYSTEM=="video4linux", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="0804", SYMLINK+="c250"' \
  | sudo tee /etc/udev/rules.d/99-c250.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then set `VIDEO_DEV=/dev/c250` and map it in `devices:`. (A camera exposes
several nodes; add `ATTR{index}=="0"` if the symlink lands on a non-capture one.)

## Troubleshooting

Start with the smoke check — it tells you which backend to chase.

- **Logs:** `docker logs -f webcam_home`. The startup lines list every backend
  that was configured.
- **Inspect the generated config:** `docker exec webcam_home cat /etc/mediamtx.yml`
- **Black page, no video:** confirm the camera enumerated — `ls /dev/video*` and
  `arecord -l` on the host.
- **Permission denied on a device:** the host user needs the `video` and `audio`
  groups.
- **CSI fails while USB works** — three distinct causes:
  - `No such element "nvarguscamerasrc"` in the container: the nvidia runtime is
    not mounting the Tegra libs. Check `runtime: nvidia` and
    `docker info | grep -i runtime`.
  - A GStreamer caps error: `CSI_SIZE` is not a real sensor mode.
  - `/tmp/argus_socket` missing, or `nvargus-daemon` not active, on the **host**.
  - **You restarted `nvargus-daemon`.** That replaces the socket's inode, which a
    single-file bind mount cannot follow. Restart the container too.

  Split host from container by running the pipeline on the host directly:

  ```bash
  gst-launch-1.0 -e nvarguscamerasrc num-buffers=30 ! nvvidconv ! nvv4l2h264enc \
    ! h264parse ! matroskamux ! filesink location=/tmp/csi.mkv
  ```

- **Choppy video:** lower `FRAMERATE` or `VBITRATE`. The software x264 path is
  the expensive half.

## Known limitations

Stated plainly rather than left to be discovered:

- **Pinned to JetPack 4.x / L4T R32.7.** The CSI backend depends on
  `nvarguscamerasrc` and the argus socket, which is JetPack-specific. The USB and
  test backends are portable; the container is not.
- **The base image is Ubuntu bionic**, inherited from `l4t-base:r32.7.1`. Bionic's
  arm64 archive is still served, but that is a clock — this project already had to
  move off Debian bullseye when its package pool disappeared.
- **No authentication on the streams.** Anyone who can reach port 8889 can watch,
  and with on-demand capture can cause capture processes to start. Intended for a
  LAN or a Tailscale tailnet, not the open internet.
- **Audio is USB-only** here, for the hardware reason above.
- Fast camera switching is verified manually, not by an automated test.

## Design notes

`docs/` carries the design document and the implementation plan this was built
from, including the probe results that settled whether the single-container
approach was viable at all, and the measured numbers quoted above.

Worth a look if you want the reasoning rather than the result — including the
bug that made it necessary to read SDP: MediaMTX answers a video-only path with
an empty audio m-line carrying no `a=msid`, so `ontrack` fires a second time with
`e.streams` empty. The original handler assigned `e.streams[0]` unconditionally
and wrote `undefined` over the video stream it had just bound, giving a black
player that reported "Live".

## License

MIT — see [LICENSE](LICENSE).
