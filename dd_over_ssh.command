#!/bin/bash

# Ontrack Data Ferry - Version V1.102
# Usage: ./tar_transfer.sh username ipaddress source_path remote_path

# ┌─────────────────────────────────────────────┐
# │   🚢 Welcome to Ontrack Tar over SSH script │
# │               Version: V1.102               │
# └─────────────────────────────────────────────┘

echo ""
echo "🚢 Welcome to Ontrack Tar over SSH script"
echo "🔧 Version: V1.102"
echo "-----------------------------------------"
echo ""

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
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_x86_64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_x86_64"
    echo "Detected Intel architecture. Using Intel gtar and pv binaries."
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_arm64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_arm64"
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
if ! ssh "$USER@$IP_ADDRESS" "echo 'SSH connection successful'" >/dev/null 2>&1; then
    echo "SSH connection failed to $USER@$IP_ADDRESS. Exiting."
    exit 1
fi

# Inform user of exact command that will be run
echo ""
echo "🚀 The following command will be executed:"
echo ""
echo "cd \"$SOURCE_PATH\" && COPYFILE_DISABLE=1 \"$GTAR_PATH\" -czvf - --totals \\"
echo "  --ignore-failed-read \\"
echo "  --exclude='*.sock' --exclude='.DS_Store' --exclude='.TemporaryItems' --exclude='.Trashes' \\"
echo "  --exclude='.Spotlight-V100' --exclude='.fseventsd' --exclude='.PreviousSystemInformation' \\"
echo "  --exclude='.DocumentRevisions-V100' --exclude='.vol' --exclude='.VolumeIcon.icns' \\"
echo "  --exclude='.PKInstallSandboxManager-SystemSoftware' --exclude='.MobileBackups' \\"
echo "  --exclude='.com.apple.TimeMachine' --exclude='.AppleDB' --exclude='.AppleDesktop' \\"
echo "  --exclude='.AppleDouble' --exclude='.CFUserTextEncoding' --exclude='.hotfiles.btree' \\"
echo "  --exclude='.metadata_never_index' --exclude='.com.apple.timemachine.donotpresent' \\"
echo "  --exclude='lost+found' --exclude='Library' . 2> \"$LOG_FILE\" | \\"
echo "\"$PV_PATH\" -p -t -e -b -r | ssh \"$USER@$IP_ADDRESS\" \"mkdir -p \\\"$REMOTE_PATH\\\" && cd \\\"$REMOTE_PATH\\\" && tar -xzf -\""
echo ""

read -rp "⚠️  Do you want to proceed? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted by user."
    exit 0
fi

# Change into source directory and run transfer
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
    . 2> "$LOG_FILE" | "$PV_PATH" -p -t -e -b -r | ssh "$USER@$IP_ADDRESS" "mkdir -p \"$REMOTE_PATH\" && cd \"$REMOTE_PATH\" && tar -xzf -"

echo "✅ Transfer complete."

# Summarize skipped files
SKIPPED_COUNT=$(grep -c "Cannot" "$LOG_FILE" || true)
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo ""
    echo "⚠️  Transfer skipped $SKIPPED_COUNT files or directories:"
    grep "Cannot" "$LOG_FILE"
    echo "📄 Full log of skipped files saved to: $LOG_FILE"
else
    echo "✅ No files were skipped."
fi

# Timing summary
ELAPSED_TIME=$((SECONDS - START_TIME))
echo ""
echo "⏱ Transfer completed in $(($ELAPSED_TIME / 60)) minutes and $(($ELAPSED_TIME % 60)) seconds."

# DO NOT DELETE TEMP DIRECTORY (for diagnostics)
echo ""
echo "🛠 Temporary files kept in: $TMP_DIR"
