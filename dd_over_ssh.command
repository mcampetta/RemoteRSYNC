#!/bin/bash

# Prompt for missing inputs
if [ -z "$1" ]; then read -p "Enter SSH username: " USERNAME; else USERNAME=$1; fi
if [ -z "$2" ]; then read -p "Enter SSH IP address: " IPADDR; else IPADDR=$2; fi
if [ -z "$3" ]; then read -p "Enter SOURCE folder path: " SOURCE_PATH; else SOURCE_PATH=$3; fi
if [ -z "$4" ]; then read -p "Enter DESTINATION path on remote host: " DEST_PATH; else DEST_PATH=$4; fi

START_TIME=$(date +%s)

echo "🔐 Connecting to $USERNAME@$IPADDR..."
echo "📦 Compressing and copying files from '$SOURCE_PATH' to '$DEST_PATH'..."

# Perform compressed tar-over-ssh transfer with exclusions
tar -czf - \
  --exclude='.TemporaryItems' \
  --exclude='.Trashes' \
  --exclude='.Spotlight-V100' \
  --exclude='.fseventsd' \
  --exclude='.DS_Store' \
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
  --exclude='*.sock' \
  "$SOURCE_PATH" 2> skipped_files.log | \
ssh "$USERNAME@$IPADDR" "mkdir -p '$DEST_PATH' && cd '$DEST_PATH' && tar -xzf -"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "✅ Transfer complete in $DURATION seconds."

# Show skipped files if any
if [ -s skipped_files.log ]; then
  echo ""
  echo "⚠️ Some files were skipped during transfer:"
  grep -E '^tar:' skipped_files.log | sed 's/^/   /'
  echo "📄 Full log saved to skipped_files.log"
else
  rm -f skipped_files.log
  echo "✅ No files were skipped."
fi
