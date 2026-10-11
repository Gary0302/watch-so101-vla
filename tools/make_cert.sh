#!/usr/bin/env bash
# Self-signed TLS cert for the gateway + the SHA-256 pin to paste into the iPhone app.
#   tools/make_cert.sh ~/gary/certs 169.233.72.12
set -euo pipefail
DIR=${1:?usage: make_cert.sh DIR IP}
IP=${2:?usage: make_cert.sh DIR IP}
mkdir -p "$DIR"; umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=so101-agent" \
  -addext "subjectAltName=IP:$IP" -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
echo "pin (SHA-256):"
openssl x509 -in "$DIR/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
