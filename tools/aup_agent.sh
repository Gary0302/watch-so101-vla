#!/usr/bin/env bash
# Run the Local Robot Agent (WSS gateway + real SO-101) on aup inside docker, in the foreground.
#
# Same rules as aup_probe.sh: touches only ~/gary and the named serial port, checks on the
# HOST that nothing else holds it, never stops/kills anything. Ctrl-C stops our container;
# the arm keeps holding (disconnect(disable_torque=False)).
#
# One-time, in ~/gary on aup:
#   cp ~/.cache/huggingface/lerobot/calibration/robots/so_follower/<id>.json ~/gary/so101_calibration.json  # so101_follower/ on older lerobot
#   cp watch-so101-vla/robot/config/so101.example.toml ~/gary/so101.toml   # then edit with measured values
#   watch-so101-vla/tools/make_cert.sh ~/gary/certs 169.233.72.12          # prints the pin for the iPhone app
#   (umask 077; head -c 24 /dev/urandom | base64 > ~/gary/so101_token)
#
#   tools/aup_agent.sh /dev/ttyACM0
set -euo pipefail

PORT_DEV=${1:?usage: aup_agent.sh /dev/ttyACMx}
LISTEN=${SO101_LISTEN_PORT:-8765}
GARY="$HOME/gary"
REPO_IN_CONTAINER=/work/watch-so101-vla
IMAGE=ghcr.io/amdresearch/auplc-physim:latest
STAMP=$(date +%Y%m%d_%H%M%S)

for f in so101.toml so101_calibration.json so101_token certs/cert.pem certs/key.pem; do
  [ -e "$GARY/$f" ] || { echo "missing ~/gary/$f (see header)" >&2; exit 2; }
done
[ -e "$PORT_DEV" ] || { echo "no such device: $PORT_DEV" >&2; exit 2; }
if holders=$(lsof -t "$PORT_DEV" 2>/dev/null) && [ -n "$holders" ]; then
  echo "REFUSING: $PORT_DEV is in use by:" >&2
  ps -o pid,user,etime,cmd -p $(echo $holders | tr ' ' ',') >&2 || true
  exit 3
fi

setup='
VENV=/work/venvs/agent
if [ ! -x $VENV/bin/python ]; then
  python -m venv --system-site-packages $VENV
  $VENV/bin/pip install -q --no-deps lerobot==0.6.1 feetech-servo-sdk pyserial deepdiff tqdm \
    huggingface_hub draccus mergedeep typing_inspect mypy_extensions typing_extensions \
    orderly_set cachebox
  $VENV/bin/pip install -q "websockets>=17.2"
fi
'

# Inside the container lsof cannot see host processes, so tell the in-process guard which
# device was already checked here; robot.port in so101.toml must be that same path.
docker run --rm --init \
  --name "gary-agent-$STAMP" \
  --device="$PORT_DEV" --group-add dialout \
  -p "$LISTEN:$LISTEN" \
  -v "$GARY:/work" -w "$REPO_IN_CONTAINER/robot" \
  -e PYTHONPATH="$REPO_IN_CONTAINER/robot/src" \
  -e SO101_PORT_CHECKED_ON_HOST="$PORT_DEV" \
  "$IMAGE" \
  bash -c "$setup; exec /work/venvs/agent/bin/python -m so101_watch.gateway \
    --config /work/so101.toml --token-file /work/so101_token \
    --cert /work/certs/cert.pem --key /work/certs/key.pem --port $LISTEN"
