#!/bin/bash

# === Ontrack Transfer Utility - V1.115 ===
# Adds optional rsync and dd (hybrid) support alongside tar transfer
# Now supports both local and remote copy sessions
# Uses downloaded binaries to avoid RecoveryOS tool limitations

clear

# Display ASCII welcome art and header
echo ""
echo "██████╗ ███╗   ██╗████████╗██████╗  █████╗  ██████╗██╗  ██╗"
echo "██╔═══██╗████╗  ██║╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝"
echo "██║   ██║██╔██╗ ██║   ██║   ██████╔╝███████║██║     █████╔╝ "
echo "██║   ██║██║╚██╗██║   ██║   ██╔███╗ ██╔══██║██║     ██╔═██╗ "
echo "╚██████╔╝██║ ╚████║   ██║   ██║ ███╗██║  ██║╚██████╗██║  ██╗"
echo " ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝ ╚══╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
echo " ONTRACK DATA TRANSFER UTILITY V1.116 (tar, rsync, or dd-hybrid)"
echo ""


TMP_DIR=$(mktemp -d)
ARCH=$(uname -m)

# Define URLs for static binaries
if [[ "$ARCH" == "x86_64" ]]; then
  RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync"
  GTAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/tar_x86_64"
  PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/pv_x86_64"
elif [[ "$ARCH" == "arm64" ]]; then
  RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync_arm"
  RSYNC_URL2="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync.samba"
  GTAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/tar_arm64"
  PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/pv_arm64"
else
  echo "❌ Unsupported architecture"
  exit 1
fi

RSYNC_PATH="$TMP_DIR/rsync"
RSYNC_PATH2="$TMP_DIR/rsync.samba"
GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"

echo "⬇️  Downloading required binaries..."
echo "  - Downloading rsync..."
curl -s -L -o "$RSYNC_PATH" "$RSYNC_URL" && chmod +x "$RSYNC_PATH"
echo "  - Downloading rsync.samba..."
curl -s -L -o "$RSYNC_PATH2" "$RSYNC_URL2" && chmod +x "$RSYNC_PATH2"
echo "  - Downloading gtar..."
curl -s -L -o "$GTAR_PATH" "$GTAR_URL" && chmod +x "$GTAR_PATH"
echo "  - Downloading pv..."
curl -s -L -o "$PV_PATH" "$PV_URL" && chmod +x "$PV_PATH"

# Validate binary downloads
for BIN in "$GTAR_PATH" "$PV_PATH" "$RSYNC_PATH" "$RSYNC_PATH2"; do
  if [ ! -x "$BIN" ]; then
    echo ""
    echo "❌ Failed to download required binary: $BIN"
    echo "This is usually caused by the system clock being incorrect."
    echo "Please update the date with the following command format:"
    echo ""
    echo "    date MMDDhhmmYYYY"
    echo ""
    echo "For example, to set the date to June 6th, 2025 at 10:35 AM:"
    echo "    date 060610352025"
    echo ""
    echo "After updating the date, rerun the script."
    exit 1
  fi
done

echo "Please select copy mode:"
echo "1) Local Session Copy - copy directly to an attached external drive"
echo "2) Remote Session Copy - transfer over SSH to another Mac"
read -rp "Enter 1 or 2: " SESSION_MODE

if [[ "$SESSION_MODE" == "1" ]]; then
  echo "🔧 Local Session Selected"
  read -rp "Enter job number: " JOB_NUM

  echo "Searching for customer source volume..."
  LARGEST_SRC=$(df -Hl | grep -v "My Passport" | grep -v "$JOB_NUM" | awk '{print $3,$NF}' | sort -hr | head -n1 | awk '{print $2}')
  echo "Suggested source volume: $LARGEST_SRC"
  read -rp "Press enter to confirm or drag a different volume: " CUSTOM_SRC
  SRC_VOL="${CUSTOM_SRC:-$LARGEST_SRC}"

  DEST_PATH="/Volumes/$JOB_NUM/$JOB_NUM"

  if [ -d "/Volumes/$JOB_NUM" ]; then
    echo "⚠️ Existing volume named '$JOB_NUM' found. Assuming it is already formatted."
    echo "📂 Destination path will be: $DEST_PATH"
    mkdir -p "$DEST_PATH"
  else
    echo "Please connect the external copy-out drive (named 'My Passport')..."
    while [ ! -d /Volumes/My\ Passport ]; do sleep 1; done
    echo "✅ External drive detected. Formatting..."

    DISK_ID=$(diskutil list | grep "My Passport" | awk '{print $NF}' | head -n1)
    if [[ "$DISK_ID" == *s* ]]; then
      DISK_ID="${DISK_ID%%s*}"
    fi
    diskutil eraseDisk JHFS+ "$JOB_NUM" "/dev/$DISK_ID"

    mkdir -p "$DEST_PATH"
  fi

  echo "Select transfer method:"
  echo "1) tar"
  echo "2) rsync"
  echo "3) dd hybrid"
  read -rp "Enter choice [1-3]: " TRANSFER_METHOD

  echo "Starting local transfer using method $TRANSFER_METHOD..."
  cd "$SRC_VOL" || exit 1

  EXCLUDES=(--exclude="Dropbox" --exclude="Volumes" --exclude=".DocumentRevisions-V100" --exclude="Cloud Storage")

  if [[ "$TRANSFER_METHOD" == "1" ]]; then
    COPYFILE_DISABLE=1 "$GTAR_PATH" -cvf - . "${EXCLUDES[@]}" | "$PV_PATH" | tar -xvf - -C "$DEST_PATH"
  elif [[ "$TRANSFER_METHOD" == "2" ]]; then
    "$RSYNC_PATH" -av "${EXCLUDES[@]}" "$SRC_VOL/" "$DEST_PATH"
  elif [[ "$TRANSFER_METHOD" == "3" ]]; then
    echo "Creating directory structure first..."
    "$RSYNC_PATH" -av --dirs "${EXCLUDES[@]}" "$SRC_VOL/" "$DEST_PATH"
    echo "Copying file contents using dd..."
    find . -type f \( ! -path "*/Dropbox/*" ! -path "*/Volumes/*" ! -path "*/.DocumentRevisions-V100/*" ! -path "*/Cloud Storage/*" \) | while read -r FILE; do
      SRC_FULL="$SRC_VOL/$FILE"
      DST_FULL="$DEST_PATH/$FILE"
      mkdir -p "$(dirname "$DST_FULL")"
      dd if="$SRC_FULL" of="$DST_FULL" bs=1m status=progress
    done
  fi

  echo "✅ Local transfer complete."
  exit 0
fi


# === Remote Session Logic Continues Here ===
# Placeholder: Add your existing remote transfer logic here.


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
      IFACE=$(route get "$TARGET" 2>/dev/null | awk '/interface: /{print $2}')
      echo "$TARGET:$RESPONSE:$IFACE" >> "$TMP_DIR/listeners.txt"
    fi
  ) &
done
wait

# Process results
if [ -f "$TMP_DIR/listeners.txt" ]; then
  LISTENERS=()
  LISTENER_KEYS=""
  INDEX=1
  while IFS= read -r LINE; do
    TARGET=$(echo "$LINE" | cut -d':' -f1)
    PAYLOAD=$(echo "$LINE" | cut -d':' -f2-)
    R_USER=$(echo "$PAYLOAD" | cut -d':' -f1)
    R_IP=$(echo "$PAYLOAD" | cut -d':' -f2)
    R_DEST=$(echo "$PAYLOAD" | cut -d':' -f3)
    R_IFACE=$(echo "$PAYLOAD" | cut -d':' -f4)
    KEY="$R_USER@$R_IP:$R_DEST"
    if ! echo "$LISTENER_KEYS" | grep -q "$KEY"; then
      LISTENER_KEYS="$LISTENER_KEYS $KEY"
      LISTENERS+=("$R_USER:$R_IP:$R_DEST")
      echo "$INDEX) $R_USER@$R_IP -> $R_DEST ($R_IFACE)"
      INDEX=$((INDEX + 1))
    fi
  done < "$TMP_DIR/listeners.txt"

  echo ""
  read -rp "Select a receiver [1-${#LISTENERS[@]}]: " CHOICE
  SELECTED=${LISTENERS[$((CHOICE-1))]}
  IFS=':' read -r REMOTE_USER REMOTE_IP REMOTE_DEST <<< "$SELECTED"
else
  echo "❌ Failed to detect remote listener. Ensure the receiver script is running."
  exit 1
fi

# Validate likely source path candidates
VALID_PATHS=(/Volumes/Data "/Volumes/Macintosh HD Data" "/Volumes/Macintosh HD")
DEFAULT_SOURCE=""

for CANDIDATE in "${VALID_PATHS[@]}"; do
  if [ -d "$CANDIDATE/Users" ] || [ -d "$CANDIDATE/home" ]; then
    DEFAULT_SOURCE="$CANDIDATE"
    break
  fi
done

DEFAULT_SOURCE=${DEFAULT_SOURCE:-/Volumes/Data}
echo ""
echo "📂 Suggested source directory: $DEFAULT_SOURCE"
read -rp "Override source directory? (Leave blank to use default): " SOURCE_OVERRIDE
SOURCE_PATH="${SOURCE_OVERRIDE:-$DEFAULT_SOURCE}"
SOURCE_PATH=$(eval echo "$SOURCE_PATH")

echo ""
echo "Select transfer method:"
echo "1) tar (default)"
echo "2) rsync"
echo "3) hybrid (rsync directory tree + dd files)"
read -rp "Enter 1, 2, or 3: " METHOD_CHOICE
TRANSFER_METHOD=${METHOD_CHOICE:-1}

ARCH=$(uname -m)
echo "\n🔧 Architecture: $ARCH"
if [ "$ARCH" = "x86_64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_x86_64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_x86_64"
    RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/rsync"
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_arm64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_arm64"
    RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/rsync_arm"
    RSYNC_URL2="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/rsync.samba"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
RSYNC_PATH="$TMP_DIR/rsync"
RSYNC_PATH2="$TMP_DIR/rsync.samba"
LOG_FILE="$TMP_DIR/skipped_files.log"
CONTROL_PATH="$TMP_DIR/ssh-ctl"
SSH_OPTIONS="-o ControlMaster=auto -o ControlPath=$CONTROL_PATH -o ControlPersist=10m"

curl -s -L -o "$GTAR_PATH" "$TAR_URL" && chmod +x "$GTAR_PATH"
curl -s -L -o "$PV_PATH" "$PV_URL" && chmod +x "$PV_PATH"
curl -s -L -o "$RSYNC_PATH" "$RSYNC_URL" && chmod +x "$RSYNC_PATH"
curl -s -L -o "$RSYNC_PATH2" "$RSYNC_URL2" && chmod +x "$RSYNC_PATH2"

if ! ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "echo OK" >/dev/null 2>&1; then
    echo "❌ SSH failed to connect to $REMOTE_USER@$REMOTE_IP"
    exit 1
fi

if ! ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "mkdir -p \"$REMOTE_DEST\" && test -w \"$REMOTE_DEST\""; then
    echo "❌ Remote path $REMOTE_DEST not writable"
    exit 1
fi

cd "$SOURCE_PATH" || { echo "❌ Source path not found: $SOURCE_PATH"; exit 1; }

set +e
START_TIME=$SECONDS

EXCLUDES=(
  '*.sock' '.DS_Store' '.TemporaryItems' '.Trashes' '.Spotlight-V100'
  '.fseventsd' '.PreviousSystemInformation' '.DocumentRevisions-V100'
  '.vol' '.VolumeIcon.icns' '.PKInstallSandboxManager-SystemSoftware'
  '.MobileBackups' '.com.apple.TimeMachine' '.AppleDB' '.AppleDesktop'
  '.AppleDouble' '.CFUserTextEncoding' '.hotfiles.btree' '.metadata_never_index'
  '.com.apple.timemachine.donotpresent' 'lost+found' 'Library' 'Volumes'
  'Dropbox' 'OneDrive' 'Google Drive' 'Box' 'iCloud Drive' 'Creative Cloud Files'
)

case "$TRANSFER_METHOD" in
  2)
    echo "🔁 Running rsync..."
    RSYNC_EXCLUDES=( )
    for EXCL in "${EXCLUDES[@]}"; do RSYNC_EXCLUDES+=(--exclude="$EXCL"); done
    "$RSYNC_PATH" -av --progress "${RSYNC_EXCLUDES[@]}" . "$REMOTE_USER@$REMOTE_IP:$REMOTE_DEST"
    TRANSFER_STATUS=$?
    ;;
  3)
    echo "🔁 Running hybrid rsync + dd..."
    RSYNC_EXCLUDES=( )
    for EXCL in "${EXCLUDES[@]}"; do RSYNC_EXCLUDES+=(--exclude="$EXCL"); done
    "$RSYNC_PATH" -av -f "+ */" -f "- *" "${RSYNC_EXCLUDES[@]}" . "$REMOTE_USER@$REMOTE_IP:$REMOTE_DEST"
    find . -type f | while read -r FILE; do
      SKIP=false
      for EXCL in "${EXCLUDES[@]}"; do
        [[ "$FILE" == *"$EXCL"* ]] && SKIP=true && break
      done
      if [ "$SKIP" = false ]; then
        echo "📤 Sending: $FILE"
        dd if="$FILE" bs=1M 2>/dev/null | ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "dd of=\"$REMOTE_DEST/$FILE\" bs=1M 2>/dev/null"
      fi
    done
    TRANSFER_STATUS=$?
    ;;
  *)
    echo "🔁 Running tar..."
    TAR_EXCLUDES=( )
    for EXCL in "${EXCLUDES[@]}"; do TAR_EXCLUDES+=(--exclude="$EXCL"); done
    COPYFILE_DISABLE=1 "$GTAR_PATH" -cvf - --totals --ignore-failed-read "${TAR_EXCLUDES[@]}" . 2> "$LOG_FILE" |
      "$PV_PATH" -p -t -e -b -r |
      ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "cd \"$REMOTE_DEST\" && tar -xvf -"
    TRANSFER_STATUS=$?
    ;;
esac

ELAPSED_TIME=$((SECONDS - START_TIME))
echo "\n✅ Transfer complete in $((ELAPSED_TIME / 60))m $((ELAPSED_TIME % 60))s."

if [ "$TRANSFER_METHOD" = "1" ]; then
  SKIPPED_COUNT=$(grep -c "Cannot" "$LOG_FILE" || true)
  if [ "$SKIPPED_COUNT" -gt 0 ]; then
    echo "⚠️  Skipped $SKIPPED_COUNT files:"
    grep "Cannot" "$LOG_FILE"
    echo "📄 Skipped log: $LOG_FILE"
  else
    echo "✅ No files were skipped."
  fi
fi

if [ "$TRANSFER_STATUS" -ne 0 ]; then
  echo "⚠️ Warning: Transfer exited with code $TRANSFER_STATUS."
fi

if [ "$ELAPSED_TIME" -lt 300 ]; then
  echo "\n⚠️  Transfer ended quickly. Diagnostic mode:"
  echo "cd \"$SOURCE_PATH\" && [...]"
fi

ssh -O exit -o ControlPath="$CONTROL_PATH" "$REMOTE_USER@$REMOTE_IP" 2>/dev/null

echo "\n🛠 Temp files retained in $TMP_DIR"
