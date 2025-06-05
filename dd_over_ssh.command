#!/bin/bash

# === Ontrack Tar Transfer Utility - V1.106 ===
# Automates remote detection and data transfer over SSH using GNU tar and pv.

clear

# Display ASCII welcome art and header
echo ""
echo "██████╗ ███╗   ██╗████████╗██████╗  █████╗  ██████╗██╗  ██╗"
echo "██╔═══██╗████╗  ██║╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝"
echo "██║   ██║██╔██╗ ██║   ██║   ██████╔╝███████║██║     █████╔╝ "
echo "██║   ██║██║╚██╗██║   ██║   ██╔═══╝ ██╔══██║██║     ██╔═██╗ "
echo "╚██████╔╝██║ ╚████║   ██║   ██║     ██║  ██║╚██████╗██║  ██╗"
echo " ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
echo "              TAR TRANSFER SENDER UTILITY V1.106"
echo ""
echo "🔍 Scanning for Ontrack Receiver..."

# Auto-detect subnet and scan for listener
MY_IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
SUBNET=$(echo "$MY_IP" | awk -F. '{print $1"."$2"."$3}')
PORT=12345
TMP_DIR=$(mktemp -d)

# Parallel scan
for i in {1..254}; do
  (
    TARGET="$SUBNET.$i"
    RESPONSE=$(nc -G 1 "$TARGET" $PORT 2>/dev/null)
    if [ -n "$RESPONSE" ]; then
      echo "$TARGET:$RESPONSE" >> "$TMP_DIR/listeners.txt"
    fi
  ) &
done
wait

# Process results
if [ -f "$TMP_DIR/listeners.txt" ]; then
  while IFS= read -r LINE; do
    TARGET=$(echo "$LINE" | cut -d':' -f1)
    PAYLOAD=$(echo "$LINE" | cut -d':' -f2-)
    IFS=':' read -r REMOTE_USER REMOTE_IP REMOTE_DEST <<< "$PAYLOAD"
    echo "✅ Found listener at $TARGET"
    echo "👤 User: $REMOTE_USER"
    echo "📁 Path: $REMOTE_DEST"
    read -rp "Connect to this receiver? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
      break
    fi
  done < "$TMP_DIR/listeners.txt"
else
  echo "❌ Failed to detect remote listener. Ensure the receiver script is running."
  exit 1
fi

# Auto-suggest source path
DEFAULT_SOURCE=$(mount | grep -i "Macintosh HD Data" | awk '{print $3}' | head -n 1)
DEFAULT_SOURCE=${DEFAULT_SOURCE:-/Volumes/Macintosh\ HD\ Data}
read -rp "📂 Source directory [${DEFAULT_SOURCE}]: " SOURCE_OVERRIDE
SOURCE_PATH="${SOURCE_OVERRIDE:-$DEFAULT_SOURCE}"

# Unescape any drag-and-dropped path if wrapped in quotes
SOURCE_PATH=$(eval echo "$SOURCE_PATH")

# Detect architecture and download matching tar + pv
ARCH=$(uname -m)
echo "\n🔧 Architecture: $ARCH"
if [ "$ARCH" = "x86_64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_x86_64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_x86_64"
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_arm64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
LOG_FILE="$TMP_DIR/skipped_files.log"

# Download binaries
curl -s -L -o "$GTAR_PATH" "$TAR_URL"
chmod +x "$GTAR_PATH"
curl -s -L -o "$PV_PATH" "$PV_URL"
chmod +x "$PV_PATH"

# Validate SSH connection
if ! ssh "$REMOTE_USER@$REMOTE_IP" "echo OK" >/dev/null 2>&1; then
    echo "❌ SSH failed to connect to $REMOTE_USER@$REMOTE_IP"
    exit 1
fi

# Confirm remote path is writable
if ! ssh "$REMOTE_USER@$REMOTE_IP" "mkdir -p \"$REMOTE_DEST\" && test -w \"$REMOTE_DEST\""; then
    echo "❌ Remote path $REMOTE_DEST not writable"
    exit 1
fi

# Change to source dir
cd "$SOURCE_PATH" || { echo "❌ Source path not found: $SOURCE_PATH"; exit 1; }

# Run tar transfer (no compression)
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
    . 2> "$LOG_FILE" | "$PV_PATH" -p -t -e -b -r | \
    ssh "$REMOTE_USER@$REMOTE_IP" "cd \"$REMOTE_DEST\" && tar -xvf -"

# Transfer complete
ELAPSED_TIME=$((SECONDS - START_TIME))
echo "\n✅ Transfer complete in $((ELAPSED_TIME / 60))m $((ELAPSED_TIME % 60))s."

# Check for skipped files
SKIPPED_COUNT=$(grep -c "Cannot" "$LOG_FILE" || true)
if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo "⚠️  Skipped $SKIPPED_COUNT files:"
    grep "Cannot" "$LOG_FILE"
    echo "📄 Skipped log: $LOG_FILE"
else
    echo "✅ No files were skipped."
fi

# Diagnostic command if transfer too quick
if [ "$ELAPSED_TIME" -lt 300 ]; then
    echo "\n⚠️  Transfer ended quickly. Diagnostic command was:"
    echo "cd \"$SOURCE_PATH\" && COPYFILE_DISABLE=1 \"$GTAR_PATH\" -cvf - [...] | \"$PV_PATH\" | ssh \"$REMOTE_USER@$REMOTE_IP\" \"cd \"$REMOTE_DEST\" && tar -xvf -\""
fi

# Keep temp dir
echo "\n🛠 Temp files retained in $TMP_DIR"
