#!/usr/bin/env bash
# Deploy webcam_home to the Jetson Nano: copy files, then build & start.
# Run from your DEV machine:  ./script.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG — edit these (or override via env, e.g. JETSON_HOST=100.x.y.z ./script.sh)
# ---------------------------------------------------------------------------
JETSON_USER="${JETSON_USER:-nvidia}"            # SSH user on the Nano
JETSON_HOST="${JETSON_HOST:-bart}"              # hostname, LAN IP, or Tailscale name
SSH_PORT="${SSH_PORT:-22}"
REMOTE_DIR="${REMOTE_DIR:-/home/${JETSON_USER}/webcam_home}"
USE_SUDO="${USE_SUDO:-}"                         # set to "sudo" if docker needs root
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SSH=(ssh -p "$SSH_PORT" "${JETSON_USER}@${JETSON_HOST}")
SCP=(scp -P "$SSH_PORT" -r)

# One-time key bootstrap: `./script.sh setup-key` prompts for the Jetson
# password once and installs your public key, so no deploy ever needs a
# password and none is stored in this repo.
if [ "${1:-}" = "setup-key" ]; then
  [ -f "${HOME}/.ssh/id_ed25519.pub" ] || ssh-keygen -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519"
  ssh-copy-id -p "$SSH_PORT" "${JETSON_USER}@${JETSON_HOST}"
  echo ">> Key installed. Now run: ./script.sh"
  exit 0
fi

# Fail early with a useful message instead of hanging on a password prompt.
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$SSH_PORT" \
      "${JETSON_USER}@${JETSON_HOST}" true 2>/dev/null; then
  echo "!! Cannot log in to ${JETSON_USER}@${JETSON_HOST} without a password." >&2
  echo "   Run once:  ./script.sh setup-key" >&2
  exit 1
fi

FILES=(Dockerfile docker-compose.yml mediamtx.yml entrypoint.sh start-ffmpeg.sh start-csi.sh smoke.sh web README.md)

echo ">> [1/3] Ensuring remote dir: ${REMOTE_DIR}"
"${SSH[@]}" "mkdir -p '${REMOTE_DIR}'"

echo ">> [2/3] Copying project files to ${JETSON_USER}@${JETSON_HOST}:${REMOTE_DIR}"
"${SCP[@]}" "${FILES[@]}" "${JETSON_USER}@${JETSON_HOST}:${REMOTE_DIR}/"

echo ">> [3/3] Building & starting container on the Jetson"
"${SSH[@]}" "USE_SUDO='${USE_SUDO}' REMOTE_DIR='${REMOTE_DIR}' bash -s" <<'REMOTE'
set -e
cd "$REMOTE_DIR"
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi
echo "   using: ${USE_SUDO} ${DC}"
${USE_SUDO} ${DC} up --build -d
${USE_SUDO} ${DC} ps
REMOTE

echo
echo ">> Done. Open the player at:"
echo "     http://${JETSON_HOST}:8080"
echo
echo "   Logs:    ${SSH[*]} '${USE_SUDO} docker logs -f webcam_home'"
echo "   Stop:    ${SSH[*]} 'cd ${REMOTE_DIR} && ${USE_SUDO} docker-compose down'"
