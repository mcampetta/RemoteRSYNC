#!/bin/bash

# Ontrack Tar Transfer Utility - V1.105
# Description: Transfers files over SSH using GNU tar and pv, with exclusions and diagnostics.
# Author: Ontrack Engineering

START_TIME=$SECONDS

echo -e "\n🛰  Ontrack Tar Transfer Utility - V1.105"
echo "========================================="
echo "📁 Efficiently transfer files over SSH with built-in exclusions, progress, and error logging."
echo ""

USER="$1"
IP_ADDRESS="$2"
SOURCE_PATH="$3"
REMOTE_PATH="$4"

[ -z "$USER" ] && read -rp "Enter remote username: " USER
[ -z "$IP_ADDRESS" ] && read -rp "Enter remote IP address: " IP_ADDRESS
[ -z "$SOURCE_PATH" ] && read -rp "Enter local source path: " SOURCE_PATH
[ -z "$REMOTE_PATH" ] && read -rp "Enter remote destination path: " REMOTE_PATH

SOURCE_PATH="${SOURCE_PATH%/}"

echo -e "\n🔍 Detecting machine architecture..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_x86_64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_x86_64"
    echo "Detected Intel architecture."
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_arm64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_arm64"
    echo "Detected Apple Silicon architecture."
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

TMP_DIR=$(mktemp -d)
GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
LOG_FILE="$TMP_DIR/skipped_files.log"

echo -e "\n⬇️  Downloading GNU tar and pv binaries..."
curl -L -o "$GTAR_PATH" "$TAR_URL"
chmod +x "$GTAR_PATH"
curl -L -o "$PV_PATH" "$PV_URL"
chmod +x "$PV_PATH"

if ! ssh "$USER@$IP_ADDRESS" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    echo "❌ SSH connection failed to $USER@$IP_ADDRESS. Exiting."
    exit 1
fi

echo -e "\n🔗 Validating remote path on $IP_ADDRESS..."
if ! ssh "$USER@$IP_ADDRESS" "mkdir -p \"$REMOTE_PATH\" && test -w \"$REMOTE_PATH\""; then
    echo "❌ Remote path $REMOTE_PATH is not writable or accessible. Exiting."
    exit 1
fi

REMOTE_SPACE=$(ssh "$USER@$IP_ADDRESS" "df -h \"$REMOTE_PATH\" | tail -1 | awk '{print \$4}'")
echo "✅ Remote path is accessible. Free space: $REMOTE_SPACE"

cd "$SOURCE_PATH" || { echo "❌ Source path $SOURCE_PATH not found. Exiting."; exit 1; }

# Build dynamic excludes
echo -e "\n🔧 Building dynamic exclude list..."
EXCLUDES=(
    '*.sock' '.DS_Store' '.TemporaryItems' '.Trashes' '.Spotlight-V100'
    '.fseventsd' '.PreviousSystemInformation' '.DocumentRevisions-V100'
    '.vol' '.VolumeIcon.icns' '.PKInstallSandboxManager-SystemSoftware'
    '.MobileBackups' '.com.apple.TimeMachine' '.AppleDB' '.AppleDesktop'
    '.AppleDouble' '.CFUserTextEncoding' '.hotfiles.btree' '.metadata_never_index'
    '.com.apple.timemachine.donotpresent' 'lost+found' 'Library'
)

EXCLUDE_FLAGS=()
for pattern in "${EXCLUDES[@]}"; do
    if compgen -G "$pattern" > /dev/null; then
        EXCLUDE_FLAGS+=( "--exclude=$pattern" )
    fi
done

echo "⏳ Starting tar transfer..."

COPYFILE_DISABLE=1 "$GTAR_PATH" -cf - \
    --ignore-failed-read \
    "${EXCLUDE_FLAGS[@]}" \
    . 2> "$LOG_FILE" | "$PV_PATH" -p -t -e -b -r | ssh "$USER@$IP_ADDRESS" "cd \"$REMOTE_PATH\" && tar -xf -"

echo -e "\n✅ Transfer complete."

SKIPPED_COUNT=$(grep -c "Cannot" "$LOG_FILE" || true)
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo -e "\n⚠️  Transfer skipped $SKIPPED_COUNT files or directories:"
    grep "Cannot" "$LOG_FILE"
    echo "📄 Full log of skipped files saved to: $LOG_FILE"
else
    echo "✅ No files were skipped."
fi

ELAPSED_TIME=$((SECONDS - START_TIME))
echo -e "\n⏱ Transfer completed in $((ELAPSED_TIME / 60)) minutes and $((ELAPSED_TIME % 60)) seconds."

if [ "$ELAPSED_TIME" -lt 300 ]; then
    echo -e "\n⚠️  Transfer completed suspiciously fast. Here's the executed command:"
    echo "cd \"$SOURCE_PATH\" && COPYFILE_DISABLE=1 \"$GTAR_PATH\" -cf - [excludes] | \"$PV_PATH\" | ssh \"$USER@$IP_ADDRESS\" \"cd \\\"$REMOTE_PATH\\\" && tar -xf -\""
fi

echo -e "\n🛠 Temporary files retained at: $TMP_DIR"
