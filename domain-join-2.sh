#!/bin/bash
set -euo pipefail

INSTALLER_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/domain-join-candidate.sh"
TMP="$(mktemp /tmp/dr-domain-join.XXXXXX.sh)"

cleanup() {
    rm -f "$TMP"
}
trap cleanup EXIT

echo "Downloading DR Domain Join installer..."
wget -qO "$TMP" "$INSTALLER_URL"

echo "Starting DR Domain Join installer..."

if [ -r /dev/tty ]; then
    exec bash "$TMP" "$@" < /dev/tty
else
    exec bash "$TMP" "$@"
fi
