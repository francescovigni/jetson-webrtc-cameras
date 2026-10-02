# Webcam Home — Jetson Nano WebRTC streamer

Captures **video + audio** from a Logitech C250 (USB `046d:0804`) on a Jetson
Nano and streams it over **WebRTC** to a simple web page. One Docker container:
MediaMTX + FFmpeg + a static frontend.

## How it works

```
C250 ──/dev/video0─┐
                   ├─► FFmpeg ─(H264/Opus over RTSP, localhost)─► MediaMTX ─► WebRTC (WHEP) ─► browser
C250 mic ─/dev/snd─┘                                                                │
                                                            busybox httpd ──► index.html (:8080)
```

- **Always-on capture:** FFmpeg is started once by MediaMTX (`runOnInit`) and
  runs continuously. Clients connecting/disconnecting **never** restart the
  pipeline or re-open the USB device — that's the key to stability. If FFmpeg
  ever dies, MediaMTX restarts it (`runOnInitRestart`).
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
the **USB C250 is `/dev/video1`**. That's already set in `docker-compose.yml`
(`VIDEO_DEV=/dev/video1` + the matching `devices:` mapping).

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

## Tuning

All via `environment:` in `docker-compose.yml`:

| Var          | Default     | Notes                              |
|--------------|-------------|------------------------------------|
| `VIDEO_DEV`    | /dev/video0 | Camera node                                    |
| `VIDEO_SIZE`   | 640x480     | C250 max is VGA                                |
| `FRAMERATE`    | 30          | Drop to 15 to lighten CPU                      |
| `INPUT_FORMAT` | mjpeg       | C250 supports `mjpeg` at 640x480. Empty = let v4l2 negotiate. |
| `AUDIO_RATE`   | 16000       | Mic capture rate (C250 supports 16000-48000). Resampled to 48k Opus. |
| `AUDIO_CARD`   | (auto: USB) | Pin a specific ALSA card number                |

### Check what the camera actually supports

The C250 has **no MJPEG mode** — it only outputs raw YUYV. If video fails to
start, list the real supported formats/resolutions/framerates:

```bash
docker exec webcam_home ffmpeg -hide_banner -f v4l2 -list_formats all -i /dev/video0
```

Then set `VIDEO_SIZE` / `FRAMERATE` in `docker-compose.yml` to a combination it
reports, and redeploy.
| `VBITRATE`   | 1M          | Video bitrate                      |
| `AUDIO_CARD` | (auto)      | Pin ALSA card number               |
