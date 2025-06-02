#!/bin/bash

# Usage: ./tar_transfer.sh username ipaddress source_path remote_path

# Start timing
START_TIME=$SECONDS

USER="$1"
IP_ADDRESS="$2"
SOURCE_PATH="$3"
REMOTE_PATH="$4"

# Prompt for missing parameters
[ -z "$USER" ] && read -rp "Enter remote username: " USER
[ -z "$IP_ADDRESS" ] && read -rp "Enter remote IP address: " IP_ADDRESS
[ -z "$SOURCE_PATH" ] && read -rp "Enter local source path: " SOURCE_PATH
[ -z "$REMOTE_PATH" ] && read -rp "Enter remote destination path: " REMOTE_PATH

# Normalize SOURCE_PATH
SOURCE_PATH="${SOURCE_PATH%/}"

echo "Detecting machine architecture..."

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/gtarintel"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pvintel"
    echo "Detected Intel architecture. Using Intel gtar and pv binaries."
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/gtararm"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pvarm"
    echo "Detected ARM (Apple Silicon) architecture. Using ARM gtar and pv binaries."
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Prepare temporary directory for gtar, pv, and logs
TMP_DIR=$(mktemp -d)
GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
LOG_FILE="$TMP_DIR/skipped_files.log"

echo "Downloading gtar binary to $GTAR_PATH..."
curl -L -o "$GTAR_PATH" "$TAR_URL"
chmod +x "$GTAR_PATH"

echo "Downloading pv binary to $PV_PATH..."
curl -L -o "$PV_PATH" "$PV_URL"
chmod +x "$PV_PATH"

# Test SSH connection
if ! ssh "$USER@$IP_ADDRESS" "echo 'SSH connection successful'"; then
    echo "SSH connection failed to $USER@$IP_ADDRESS. Exiting."
    exit 1
fi

# Count files to transfer
echo "Counting files to transfer..."
FILE_COUNT=$(find "$SOURCE_PATH" -type f \
    -not -path '*/.Trashes*' \
    -not -path '*/.Spotlight-V100*' \
    -not -path '*/.fseventsd*' \
    -not -path '*/.TemporaryItems*' \
    -not -path '*/.PreviousSystemInformation*' \
    -not -path '*/.DocumentRevisions-V100*' \
    | wc -l)
echo "📦 Total files to transfer: $FILE_COUNT"

# Perform tar transfer with comprehensive exclusions, logging, verbose, and pv progress
cd "$SOURCE_PATH" || { echo "Source path $SOURCE_PATH not found. Exiting."; exit 1; }

COPYFILE_DISABLE=1 "$GTAR_PATH" -czvf - --totals \
    --ignore-failed-read \
    --exclude='*.sock' \
    --exclude='.DS_Store' \
    --exclude='.TemporaryItems' \
    --exclude='.Trashes' \
    --exclude='.Spotlight-V100' \
    --exclude='.fseventsd' \
    --exclude='.PreviousSystemInformation' \
    --exclude='.DocumentRevisions-V100' \
    --exclude='.vol' \
    --exclude='.VolumeIcon.icns' \
    --exclude='.PKInstallSandboxManager-SystemSoftware' \
    --exclude='.MobileBackups' \
    --exclude='.com.apple.TimeMachine' \
    --exclude='.AppleDB' \
    --exclude='.AppleDesktop' \
    --exclude='.AppleDouble' \
    --exclude='.CFUserTextEncoding' \
    --exclude='.hotfiles.btree' \
    --exclude='.metadata_never_index' \
    --exclude='.com.apple.timemachine.donotpresent' \
    --exclude='lost+found' \
    --exclude='Library' \
    . 2> "$LOG_FILE" | "$PV_PATH" -p -t -e -b -r | ssh "$USER@$IP_ADDRESS" "mkdir -p \"$REMOTE_PATH\" && cd \"$REMOTE_PATH\" && tar -xzf -" || {
    echo "Tar transfer failed."
    exit 1
}

echo "Transfer complete."

# Summarize skipped files
SKIPPED_COUNT=$(grep -c "Cannot" "$LOG_FILE" || true)
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo ""
    echo "⚠️ Transfer skipped $SKIPPED_COUNT files or directories:"
    grep "Cannot" "$LOG_FILE"
    echo "Full log of skipped files saved to $LOG_FILE"
else
    echo "✅ No files were skipped."
fi

# Display timing summary
ELAPSED_TIME=$((SECONDS - START_TIME))
echo ""
echo "⏱ Transfer completed in $(($ELAPSED_TIME / 60)) minutes and $(($ELAPSED_TIME % 60)) seconds."

# Clean up
echo "Cleaning up temporary files..."
rm -rf "$TMP_DIR"
