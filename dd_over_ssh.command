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

echo "Transferring contents of $SOURCE_PATH to $USER@$IP_ADDRESS:$REMOTE_PATH using tar over ssh with compression, no metadata, and skipping inaccessible files"

# Test SSH connection
if ! ssh "$USER@$IP_ADDRESS" "echo 'SSH connection successful'"; then
  echo "SSH connection failed to $USER@$IP_ADDRESS. Exiting."
  exit 1
fi

# Perform tar transfer with find filtering readable files
cd "$SOURCE_PATH" || { echo "Source path $SOURCE_PATH not found. Exiting."; exit 1; }

COPYFILE_DISABLE=1 find . \( -type f -o -type d \) -readable \
  -not -path './.TemporaryItems*' \
  -not -path './.Trashes*' \
  -not -path './.Spotlight-V100*' \
  -not -path './.fseventsd*' \
  -not -path './.PreviousSystemInformation*' \
  -not -path '*/Library*' \
  -print0 | tar --null -T - -czf - | ssh "$USER@$IP_ADDRESS" "mkdir -p \"$REMOTE_PATH\" && cd \"$REMOTE_PATH\" && tar -xzf -" || {
  echo "Tar transfer failed."
  exit 1
}

echo "Transfer complete."
