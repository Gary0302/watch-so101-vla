#!/usr/bin/env bash
# Run a READ-ONLY probe on aup inside docker.
#
# Touches only ~/gary and the devices named on the command line. Checks on the HOST
# that no other process holds those devices first (a container cannot see host
# processes), and refuses if any do. Never stops, kills or moves anything.
#
#   tools/aup_probe.sh telemetry /dev/ttyACM0
#   tools/aup_probe.sh camera /dev/video0 /dev/video2
set -euo pipefail

WHAT=${1:?usage: aup_probe.sh telemetry|camera DEVICE...}
shift
[ $# -ge 1 ] || { echo "name at least one device" >&2; exit 2; }

GARY="$HOME/gary"
REPO_IN_CONTAINER=/work/watch-so101-vla
IMAGE=ghcr.io/amdresearch/auplc-physim:latest
STAMP=$(date +%Y%m%d_%H%M%S)

dev_args=()
for d in "$@"; do
  [ -e "$d" ] || { echo "no such device: $d" >&2; exit 2; }
  if holders=$(lsof -t "$d" 2>/dev/null) && [ -n "$holders" ]; then
    echo "REFUSING: $d is in use by:" >&2
    ps -o pid,user,etime,cmd -p $(echo $holders | tr ' ' ',') >&2 || true
    exit 3
  fi
  dev_args+=(--device="$d")
done

case "$WHAT" in
  telemetry) cmd="python tools/feetech_telemetry_probe.py --port $1 --out runs/telemetry_$STAMP.csv" ;;
  camera)    cmd="python tools/camera_probe.py --devices $* --out runs/cameras_$STAMP" ;;
  *) echo "unknown probe: $WHAT" >&2; exit 2 ;;
esac

# Minimal deps for lerobot.motors only. --no-deps keeps pip from replacing the image's ROCm torch.
setup='
VENV=/work/venvs/probe
if [ ! -x $VENV/bin/python ]; then
  python -m venv --system-site-packages $VENV
  $VENV/bin/pip install -q --no-deps lerobot==0.6.1 feetech-servo-sdk pyserial deepdiff tqdm \
    huggingface_hub draccus mergedeep typing_inspect mypy_extensions typing_extensions \
    orderly_set cachebox
fi
'

docker run --rm \
  --name "gary-probe-$WHAT-$STAMP" \
  "${dev_args[@]}" \
  --group-add dialout --group-add video \
  -v "$GARY:/work" -w "$REPO_IN_CONTAINER" \
  "$IMAGE" \
  bash -c "$setup; /work/venvs/probe/bin/$cmd"
