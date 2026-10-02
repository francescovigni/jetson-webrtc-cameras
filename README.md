# Webcam Home — Jetson Nano WebRTC streamer

Streams either of the Jetson Nano's two cameras over **WebRTC** to a simple web
page, switchable from a dropdown in the browser:

- the USB Logitech C250 (`046d:0804`) — **video + audio**
- the onboard CSI IMX219 — **video only**

One Docker container: MediaMTX + FFmpeg + GStreamer + a static frontend.

## How it works

```
C250 ──────/dev/video1─┐
                       ├─► FFmpeg (x264 + Opus) ──┐
C250 mic ──/dev/snd────┘                          │
                                                  ├─► MediaMTX ─► WebRTC (WHEP) ─► browser
IMX219 ─(host nvargus-daemon, /tmp/argus_socket)─┐ │                   │
        └─► gst nvarguscamerasrc ! nvv4l2h264enc ! rtspclientsink      │
            (Tegra ISP + hardware H264)                               │
                                        busybox httpd ──► index.html (:8080)
```

- **On-demand capture:** each camera has its own MediaMTX path with
  `runOnDemand`, so a camera is opened only while someone is watching it and
  **only one encoder runs** in the normal case. `runOnDemandCloseAfter: 10s`
  means a page reload, or switching away and straight back, reuses the live
  pipeline instead of re-opening the device. If a pipeline dies, MediaMTX
  restarts it (`runOnDemandRestart`).
- **Two capture backends, on purpose:** the C250 is plain v4l2 into software
  x264 — cheap enough at VGA. The IMX219 cannot be: on JetPack 4.x it delivers
  10-bit Bayer (`RG10`) that FFmpeg cannot debayer and for which FFmpeg has no
  ISP, so it goes through GStreamer's `nvarguscamerasrc` (Tegra ISP) and
  `nvv4l2h264enc` (hardware H264) instead.
- **Self-healing player:** `index.html` auto-reconnects if its WebRTC link
  drops, so you can close the tab and reopen freely.
- **Tailscale-friendly:** one TCP web port (8889) + one UDP port (8189), no
  multicast. The page derives the WHEP URL from the host you browsed to, so the
  same page works over LAN IP *or* Tailscale name with no edits.

## Ports

| Port       | Purpose                          |
|------------|----------------------------------|
| 8080/tcp   | Frontend page                    |
| 8889/tcp   | WebRTC signalling (WHEP) + media |
| 8189/udp   | WebRTC ICE / media               |

## Cameras

| Camera | MediaMTX path | WHEP endpoint | Audio |
|---|---|---|---|
| USB Logitech C250 | `usb` | `http://<host>:8889/usb/whep` | yes, the C250 mic |
| Onboard CSI IMX219 | `csi` | `http://<host>:8889/csi/whep` | no |

Switch with the dropdown on the player page; the choice is remembered per
browser. The stage follows each camera's aspect ratio (the C250 is 4:3, the
IMX219 at the default mode is 16:9).

**Breaking change:** `/cam/whep` no longer exists. It became `/usb/whep` when
the second camera was added.

The CSI camera has no microphone, and the C250's mic cannot fill in: it only
delivers samples while the C250's own video interface is open, which it is not
while the CSI camera is the one being watched.

## Deploy

1. Edit the config block at the top of `script.sh` (or pass via env):

   ```bash
   JETSON_USER=jetson JETSON_HOST=192.168.1.50 ./script.sh
   ```

   Use `USE_SUDO=sudo ./script.sh` if Docker on the Jetson needs root.

2. Open **http://<jetson-ip>:8080** (or `http://<tailscale-name>:8080`).
   Click **Unmute** for audio (browsers block autoplay-with-sound until a click).

## Access over Tailscale

Tailscale runs on the **Jetson host**, and the `webcam` service uses host
networking — so the stream is already bound to the `tailscale0` interface and
MediaMTX gathers the `100.x` IP as a WebRTC ICE candidate automatically. Nothing
to configure in the container.

From any device on your tailnet:

```bash
tailscale ip -4         # on the Jetson: get its 100.x.y.z address
```

Then open **http://<100.x.y.z>:8080** (or **http://<magicdns-name>:8080**). The
frontend derives its WHEP URL from the host you browsed to, so signalling (8889)
and media (8189/udp) both flow over the tunnel. LAN access via the local IP keeps
working unchanged.

**If video stays stuck on "Connecting…" over Tailscale** (ICE didn't pick the
`100.x` candidate), ask for the `webrtcAdditionalHosts` auto-advertise tweak —
the entrypoint can detect the `tailscale0` IP and hand it to MediaMTX
explicitly.

## Finding the correct ALSA capture device

Audio is **auto-detected by name**: the container picks the **USB** audio card
(the C250 mic) from `arecord -l`, which skips the Jetson's dummy onboard card
(`tegra-snd-t210ref`, 10x ADMAIF) that never delivers samples.

> **C250 quirk:** this camera only streams audio while its **video** interface
> is active — capturing the mic *on its own* returns `Input/output error`.
> That's why the pipeline captures **video + audio together** and does **not**
> probe the mic in isolation (an isolated probe would wrongly reject a working
> mic). If the A/V pipeline fails within 8s (genuinely dead mic), it
> automatically falls back to **video-only** instead of restart-looping.

To inspect the cards yourself, list them inside the container:

```bash
docker run --rm --device /dev/snd --entrypoint arecord webcam_home:latest -l
```

Example on this Jetson:

```
card 1: tegrasndt210ref [...], device 0: ADMAIF1 ...   <- onboard dummy (no input)
   ... (ADMAIF1..10) ...
card 2: U0x46d0x804 [USB Device 0x46d:0x804], device 0: USB Audio  <- the C250 mic
```

Here the C250 is **card 2** → `plughw:2,0`, and auto-detect picks it because it
matches `USB` *and* passes the capture probe.

To pin a card explicitly (e.g. multiple USB mics), set it in
`docker-compose.yml` and redeploy:

```yaml
    environment:
      - AUDIO_CARD=2      # the "card N" number of your mic from `arecord -l`
```

## Finding the correct video device

```bash
v4l2-ctl --list-devices        # if v4l-utils installed
ls -l /dev/video*
```

On this Jetson, **`/dev/video0` is the onboard CSI camera (IMX219 Bayer)** and
the **USB C250 is `/dev/video1`**. Only the C250 is set via `VIDEO_DEV` and
mapped in `devices:`.

**`/dev/video0` is deliberately *not* mapped into the container.** The CSI
sensor is owned by `nvargus-daemon` on the host, and `nvarguscamerasrc` talks to
that daemon over `/tmp/argus_socket` — which *is* bind-mounted. Mapping the
device node as well would do nothing. This also means the CSI path depends on
two host-side things: `nvargus-daemon` running, and `runtime: nvidia` so the
Tegra userspace libs (`libargus`, `nvv4l2`) are mounted into the container.

### Stable device naming (if the C250 moves to a different node)

USB `/dev/video*` numbers can change across reboots/re-plugs. If the C250 stops
being `/dev/video1`, either update `VIDEO_DEV` + the `devices:` mapping, or
create a persistent symlink on the host via udev:

```bash
# Match the C250 by its USB IDs and pin a stable name.
echo 'SUBSYSTEM=="video4linux", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="0804", SYMLINK+="c250"' \
  | sudo tee /etc/udev/rules.d/99-c250.rules
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then set `VIDEO_DEV=/dev/c250` and map `"/dev/c250:/dev/c250"` in
`docker-compose.yml`. (A camera exposes several video nodes; if `/dev/c250`
points at a non-capture node, add `ATTR{index}=="0"` to the rule.)

## Troubleshooting

**Start here.** The smoke check forces each path to spawn its pipeline and
asserts a video stream comes back:

```bash
docker exec webcam_home sh /smoke.sh usb csi
```

Healthy output is `usb  OK  [video audio ]` and `csi  OK  [video ]`. A path that
reports `FAIL` tells you which camera to chase.

- **Logs:** `docker logs -f webcam_home`
- **Black page / no video:** confirm the C250 enumerated —
  `ls /dev/video*` and `arecord -l` on the host.
- **Permission denied on device:** ensure the host user is in the `video` and
  `audio` groups, or as a last resort add `privileged: true` to the service in
  `docker-compose.yml`.
- **No audio:** check `arecord -l` shows the C250 as a capture card; verify the
  log line `[start-ffmpeg] audio capture device: plughw:X,0`.
- **Choppy video:** lower the load via `VIDEO_SIZE=640x480` / `FRAMERATE=15` or
  reduce `VBITRATE` in `docker-compose.yml`.
- **CSI path fails, USB fine —** three distinct causes, in order of likelihood:
  - `No such element or plugin "nvarguscamerasrc"` inside the container: the
    nvidia runtime is not mounting the Tegra libs. Check `runtime: nvidia` is in
    `docker-compose.yml` and that `docker info | grep -i runtime` lists it.
  - A GStreamer caps-negotiation error: `CSI_SIZE` is not a real IMX219 sensor
    mode. Use one from the table below.
  - `/tmp/argus_socket` missing, or `systemctl is-active nvargus-daemon` not
    `active`, on the **host**. The USB camera is unaffected by either.

  Verify the whole chain on the host, outside Docker, to split host from
  container:

  ```bash
  gst-launch-1.0 -e nvarguscamerasrc num-buffers=30 ! nvvidconv ! nvv4l2h264enc \
    ! h264parse ! matroskamux ! filesink location=/tmp/csi.mkv
  ```

## Tuning

All via `environment:` in `docker-compose.yml`.

### USB camera (C250)

| Var            | Default     | Notes                                          |
|----------------|-------------|------------------------------------------------|
| `VIDEO_DEV`    | /dev/video1 | Camera node                                    |
| `VIDEO_SIZE`   | 640x480     | C250 max is VGA                                |
| `FRAMERATE`    | 30          | Drop to 15 to lighten CPU                      |
| `INPUT_FORMAT` | mjpeg       | Empty = let v4l2 negotiate                     |
| `VBITRATE`     | 1M          | Video bitrate                                  |
| `AUDIO_RATE`   | 16000       | Mic capture rate (C250 supports 16000-48000). Resampled to 48k Opus. |
| `ABITRATE`     | 64k         | Opus bitrate                                   |
| `AUDIO_CARD`   | (auto: USB) | Pin a specific ALSA card number                |

### CSI camera (onboard IMX219)

| Var             | Default   | Notes                                                        |
|-----------------|-----------|--------------------------------------------------------------|
| `CSI_SENSOR_ID` | 0         | argus sensor index                                           |
| `CSI_SIZE`      | 1280x720  | Must be a real IMX219 mode: 3264x2464@21, 1920x1080@30, 1640x1232@30 (native 4:3), 1280x720@60 |
| `CSI_FRAMERATE` | 30        | Capped by the sensor mode above                              |
| `CSI_BITRATE`   | 4000000   | **Bits per second as an integer.** `nvv4l2h264enc` rejects `4M`. |

All four are validated at startup: a malformed value exits with a readable
message instead of a GStreamer caps error on a restart loop.

### CPU cost

Only the camera being watched encodes, so normally one encoder runs. The
exception is two viewers on *different* cameras at once, when the software x264
encoder and the hardware CSI encoder run together. Measured on this 4-core Nano:

| State | Load average | USB x264 | CSI hw encode |
|---|---|---|---|
| Idle, no viewers | 0.34 | — | — |
| A viewer on each camera | 1.07 | 66.3% of a core | 10.9% of a core |

Comfortable, because the CSI path encodes in hardware. If it ever isn't, drop
`FRAMERATE` for the USB path — that's the expensive half.

### Check what the camera actually supports

If video fails to start, list the formats/resolutions/framerates the USB camera
really reports:

```bash
docker exec webcam_home ffmpeg -hide_banner -f v4l2 -list_formats all -i /dev/video1
```

Then set `VIDEO_SIZE` / `FRAMERATE` / `INPUT_FORMAT` to a combination it reports,
and redeploy. For the CSI camera the equivalent is the sensor-mode list in the
table above — `nvarguscamerasrc` also prints the modes it supports when it
starts, visible in `docker logs webcam_home`.
