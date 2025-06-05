#!/bin/bash

# Ontrack Tar Transfer Utility - V1.106
# Description: Transfers files over SSH using GNU tar and pv, with exclusions and diagnostics.
# Author: Ontrack Engineering

# Start timing
START_TIME=$SECONDS

# Welcome message
echo "\n🚀  Ontrack Tar Transfer Utility - V1.106"
echo "========================================="
echo "📁 Efficiently transfer files over SSH with built-in exclusions, progress, and error logging."
echo ""

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

# Setup SSH multiplexing
CONTROL_PATH="$HOME/.ssh/ontrack_mux_%r@%h:%p"
SSH_CMD="ssh -o ControlMaster=auto -o ControlPath=$CONTROL_PATH -o ControlPersist=24h"

# Start master connection early to cache credentials
echo -e "\n🔌 Establishing master SSH connection for multiplexing..."
$SSH_CMD -Nf "$USER@$IP_ADDRESS"

# Detect architecture
echo "\n🔍 Detecting machine architecture..."
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

# Prepare temporary directory for gtar, pv, and logs
TMP_DIR=$(mktemp -d)
GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
LOG_FILE="$TMP_DIR/skipped_files.log"

# Download binaries
echo "\n🔽  Downloading GNU tar and pv binaries..."
curl -L -o "$GTAR_PATH" "$TAR_URL"
chmod +x "$GTAR_PATH"
curl -L -o "$PV_PATH" "$PV_URL"
chmod +x "$PV_PATH"

# Test remote path validity
echo "\n🔗 Validating remote path on $IP_ADDRESS..."
if ! $SSH_CMD "$USER@$IP_ADDRESS" "mkdir -p \"$REMOTE_PATH\" && test -w \"$REMOTE_PATH\""; then
    echo "❌ Remote path $REMOTE_PATH is not writable or accessible. Exiting."
    exit 1
fi

# Check remote disk space
REMOTE_SPACE=$($SSH_CMD "$USER@$IP_ADDRESS" "df -h \"$REMOTE_PATH\" | tail -1 | awk '{print \$4}'")
echo "✅ Remote path is accessible. Free space: $REMOTE_SPACE"

# Change into source directory
cd "$SOURCE_PATH" || { echo "❌ Source path $SOURCE_PATH not found. Exiting."; exit 1; }

# Perform tar transfer
COPYFILE_DISABLE=1 "$GTAR_PATH" -cvf - --totals \
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
    . 2> "$LOG_FILE" | "$PV_PATH" -p -t -e -b -r | $SSH_CMD "$USER@$IP_ADDRESS" "cd \"$REMOTE_PATH\" && tar -xvf -"

# Completion message
echo "\n📅 Transfer complete."

# Summarize skipped files
SKIPPED_COUNT=$(grep -c "Cannot" "$LOG_FILE" || true)
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo "\n⚠️ Transfer skipped $SKIPPED_COUNT files or directories:"
    grep "Cannot" "$LOG_FILE"
    echo "📄 Full log of skipped files saved to: $LOG_FILE"
else
    echo "✅ No files were skipped."
fi

# Timing summary
ELAPSED_TIME=$((SECONDS - START_TIME))
echo "\n🕒 Transfer completed in $((ELAPSED_TIME / 60)) minutes and $((ELAPSED_TIME % 60)) seconds."

# Diagnostic output if unexpectedly fast
if [ "$ELAPSED_TIME" -lt 300 ]; then
    echo "\n⚠️ Transfer completed too quickly. Displaying executed command for diagnostics:"
    echo "cd \"$SOURCE_PATH\" && COPYFILE_DISABLE=1 \"$GTAR_PATH\" -cvf - --totals [..excludes..] | \"$PV_PATH\" | ssh -o ControlPath=$CONTROL_PATH \"$USER@$IP_ADDRESS\" 'cd \"$REMOTE_PATH\" && tar -xvf -'"
fi

# Show where temp files are kept
echo "\n🛠 Temporary files retained at: $TMP_DIR"
