#!/bin/sh
set -e

# Every executable in /cameras.d/ is a camera backend. Its filename without
# .sh is the MediaMTX path name, hence also the WHEP URL and the value the
# player stores. Two headers inside each script carry its presentation:
#
#   # camera-label: <what the dropdown shows>
#   # camera-audio: yes|no
#
# Adding a camera means dropping one script in here. Nothing else is edited:
# this loop writes both the MediaMTX `paths:` block and the cameras.json the
# player reads.
CAMERA_DIR="${CAMERA_DIR:-/cameras.d}"
MTX_BASE="${MTX_BASE:-/etc/mediamtx.base.yml}"
MTX_CONF="${MTX_CONF:-/etc/mediamtx.yml}"
WEB_ROOT="${WEB_ROOT:-/web}"

# How long a cold pipeline gets to produce its first frame, and how long it
# lingers after the last viewer leaves. The linger is why a page reload or a
# switch away and straight back reuses the pipeline instead of re-opening the
# device.
START_TIMEOUT="${START_TIMEOUT:-15s}"
CLOSE_AFTER="${CLOSE_AFTER:-10s}"

# Which camera the player opens on when a browser has no stored preference.
# Listed first in cameras.json. Unset, or naming a backend that is not present,
# falls back to whichever sorts first — so set it rather than relying on that.
DEFAULT_CAMERA="${DEFAULT_CAMERA:-}"

header() {
    # header <file> <name> <default> — reads a "# <name>: value" comment.
    v=$(sed -n "s/^# *$2: *//p" "$1" | head -n1)
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$3"
}

cp "${MTX_BASE}" "${MTX_CONF}"
printf 'paths:\n' >> "${MTX_CONF}"

# Build the backend list, with DEFAULT_CAMERA first if it exists.
names=""
for script in "${CAMERA_DIR}"/*.sh; do
    [ -f "${script}" ] || continue
    n=$(basename "${script}" .sh)
    [ "${n}" = "${DEFAULT_CAMERA}" ] || names="${names} ${n}"
done
if [ -n "${DEFAULT_CAMERA}" ] && [ -f "${CAMERA_DIR}/${DEFAULT_CAMERA}.sh" ]; then
    names="${DEFAULT_CAMERA}${names}"
elif [ -n "${DEFAULT_CAMERA}" ]; then
    echo "[entrypoint] WARNING: DEFAULT_CAMERA='${DEFAULT_CAMERA}' has no ${CAMERA_DIR}/${DEFAULT_CAMERA}.sh" >&2
fi

json="${WEB_ROOT}/cameras.json"
printf '[' > "${json}"
first=1
found=0

for name in ${names}; do
    script="${CAMERA_DIR}/${name}.sh"
    label=$(header "${script}" camera-label "${name}")
    audio=$(header "${script}" camera-audio no)
    found=$((found + 1))

    echo "[entrypoint] camera '${name}': ${label} (audio: ${audio})"

    cat >> "${MTX_CONF}" <<EOF
  ${name}:
    runOnDemand: sh ${script}
    runOnDemandRestart: yes
    runOnDemandStartTimeout: ${START_TIMEOUT}
    runOnDemandCloseAfter: ${CLOSE_AFTER}
EOF

    [ "${first}" -eq 1 ] || printf ',' >> "${json}"
    first=0
    # The label is operator-authored, but it reaches the browser as data, so
    # escape the two characters that could break out of a JSON string.
    esc=$(printf '%s' "${label}" | sed 's/\\/\\\\/g; s/"/\\"/g')
    case "${audio}" in
        yes|true|1) has_audio=true ;;
        *)          has_audio=false ;;
    esac
    printf '{"path":"%s","label":"%s","audio":%s}' "${name}" "${esc}" "${has_audio}" >> "${json}"
done
printf ']' >> "${json}"

if [ "${found}" -eq 0 ]; then
    echo "[entrypoint] FATAL: no camera backends found in ${CAMERA_DIR}" >&2
    exit 1
fi
echo "[entrypoint] ${found} camera backend(s) configured"

# Serve the single-page frontend on :8080 (busybox httpd daemonizes).
echo "[entrypoint] serving frontend on :8080"
busybox httpd -p 0.0.0.0:8080 -h "${WEB_ROOT}"

# Hand off to MediaMTX (foreground). It starts each capture pipeline on demand
# and serves WebRTC on :8889.
echo "[entrypoint] starting mediamtx"
exec /usr/local/bin/mediamtx "${MTX_CONF}"
