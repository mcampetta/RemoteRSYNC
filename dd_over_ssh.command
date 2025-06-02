#!/bin/bash

# Usage: ./tar_transfer.sh username ipaddress source_path remote_path

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
    echo "Detected Intel architecture. Using Intel gtar binary."
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/gtararm"
    echo "Detected ARM (Apple Silicon) architecture. Using ARM gtar binary."
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Prepare temporary directory for gtar
TMP_DIR=$(mktemp -d)
GTAR_PATH="$TMP_DIR/gtar"

echo "Downloading gtar binary to $GTAR_PATH..."
curl -L -o "$GTAR_PATH" "$TAR_URL"
chmod +x "$GTAR_PATH"

# Test SSH connection
if ! ssh "$USER@$IP_ADDRESS" "echo 'SSH connection successful'"; then
    echo "SSH connection failed to $USER@$IP_ADDRESS. Exiting."
    exit 1
fi

# Perform tar transfer with comprehensive exclusions
cd "$SOURCE_PATH" || { echo "Source path $SOURCE_PATH not found. Exiting."; exit 1; }

COPYFILE_DISABLE=1 "$GTAR_PATH" -czf - \
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
    . | ssh "$USER@$IP_ADDRESS" "mkdir -p \"$REMOTE_PATH\" && cd \"$REMOTE_PATH\" && tar -xzf -" || {
    echo "Tar transfer failed."
    exit 1
}

echo "Transfer complete."

# Clean up
echo "Cleaning up temporary files..."
rm -rf "$TMP_DIR"
