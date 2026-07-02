#!/bin/bash
set -euo pipefail

INSTALLER_URL="http://ontrack.link/releases/domain-join-latest.sh"
TMP="$(mktemp /tmp/dr-domain-join.XXXXXX.sh)"

cleanup() {
    rm -f "$TMP"
}
trap cleanup EXIT

echo "Downloading DR Domain Join installer..."
wget -qO "$TMP" "$INSTALLER_URL"

echo "Starting DR Domain Join installer..."
exec bash "$TMP" "$@"
