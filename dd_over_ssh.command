#!/bin/bash

# Safely exit on error
set -e

# Prompt for parameters if not passed
USERNAME="$1"
IPADDR="$2"
SOURCE_PATH="$3"
DEST_PATH="$4"

if [ -z "$USERNAME" ]; then
  read -rp "Enter SSH username: " USERNAME
fi
if [ -z "$IPADDR" ]; then
  read -rp "Enter remote IP address: " IPADDR
fi
if [ -z "$SOURCE_PATH" ]; then
  read -rp "Enter local source path (absolute or relative): " SOURCE_PATH
fi
if [ -z "$DEST_PATH" ]; then
  read -rp "Enter remote destination path: " DEST_PATH
fi

echo "Starting transfer from '$SOURCE_PATH' to '$USERNAME@$IPADDR:$DEST_PATH'..."

# Ensure compatibility by disabling extended attributes and Apple metadata
export COPYFILE_DISABLE=1

# Start timing
start_time=$(date +%s)

# Run transfer using BSD tar with exclusions and compression
tar -czf - \
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
  "$SOURCE_PATH" 2> skipped_files.log | \
ssh "$USERNAME@$IPADDR" "mkdir -p '$DEST_PATH' && cd '$DEST_PATH' && tar -xzf -"

# Timing summary
end_time=$(date +%s)
duration=$((end_time - start_time))

# Summary output
echo "✅ Transfer complete in ${duration}s."
if [ -s skipped_files.log ]; then
  echo "⚠️  Some files were skipped. See 'skipped_files.log' for details."
else
  echo "✅ No files were skipped."
  rm skipped_files.log
fi
