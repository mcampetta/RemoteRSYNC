#!/bin/bash

# === Ontrack Transfer Utility - V1.1413 ===
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
echo " ONTRACK DATA TRANSFER UTILITY V1.1413 (tar, rsync, or dd-hybrid)"
echo ""


TMP_DIR=$(mktemp -d)

# Try local uname first
if command -v uname >/dev/null 2>&1; then
  ARCH=$(uname -m)
else
  # Fallback to `arch` in Recovery
  ARCH=$(arch)

  # Normalize i386 to x86_64 (common in RecoveryOS)
  if [ "$ARCH" = "i386" ]; then
    ARCH="x86_64"
  fi
fi



 ########################################################################################################
 #All functions will go in this section, they help the script run correctly and operate like subroutines#
 #Start of functions here                                                                               #
 ########################################################################################################

start_caffeinate() {
  caffeinate -dimsu &  # keep display, system, and idle sleep prevented
  CAFFEINATE_PID=$!
}
stop_caffeinate() {
  if [[ -n "$CAFFEINATE_PID" ]]; then
    kill "$CAFFEINATE_PID" 2>/dev/null
  fi
}

verify_ssh_connection() {
  local user_host="$1"
  echo "🔐 Attempting SSH connection using sshpass..."
  "$SSHPASS_PATH" -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$user_host" "echo OK" >/dev/null 2>&1
}

prompt_for_password() {
  echo ""
  read -rsp "🔑 Enter SSH password for $1: " SSH_PASSWORD
  echo ""
}

 ########################################################################################################
 #All functions will go in this section, they help the script run correctly and operate like subroutines#
 #End of functions here                                                                               #
 ########################################################################################################

SSH_PASSWORD="ontrack123"

# Define URLs for static binaries
if [[ "$ARCH" == "x86_64" ]]; then
  RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync"
  GTAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/tar_x86_64"
  PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/pv_x86_64"
  SSHPASS_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/sshpass_x86_64"
elif [[ "$ARCH" == "arm64" ]]; then
  RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync_arm64"
  GTAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/tar_arm64"
  PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/pv_arm64"
  SSHPASS_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/sshpass_arm"
else
  echo "❌ Unsupported architecture"
  exit 1
fi

RSYNC_PATH="$TMP_DIR/rsync"
GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
SSHPASS_PATH="$TMP_DIR/sshpass"

set -e

# -- Determine Run Mode (local or curl-piped) --
SCRIPT_REALPATH="$(realpath "$0" 2>/dev/null || true)"
if [ -f "$SCRIPT_REALPATH" ]; then
  RUN_MODE="local"
  MARKER_FILE="/tmp/$(basename "$SCRIPT_REALPATH").fda_granted"
else
  RUN_MODE="remote"
  MARKER_FILE="/tmp/odtu.fda_granted"
fi

# -- RecoveryOS Detection --
is_recovery_os() {
  [[ ! -d "/Users" ]]
}

# -- FDA Check --
check_fda() {
  local protected_file="/Library/Application Support/com.apple.TCC/TCC.db"
  if [ -r "$protected_file" ]; then
    echo "✅ Full Disk Access is ENABLED."
    return 0
  else
    echo "⚠️  Full Disk Access is NOT enabled for Terminal."
    return 1
  fi
}

# -- Prompt User to Enable FDA Manually --
prompt_fda_enable() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  osascript <<EOF
display dialog "⚠️ Terminal needs Full Disk Access to continue.

Please:
1. Click the '+' button and add Terminal (in /Applications/Utilities).
2. When macOS asks to restart Terminal, click 'Later'.

Click OK to close this prompt." buttons {"OK"} default button 1
EOF
}

spawn_new_terminal_and_close_self() {
  # Step 1: Get current Terminal window number (1-based index)
  local ORIGINAL_WINDOW_ID
  ORIGINAL_WINDOW_ID=$(osascript <<EOF
tell application "Terminal"
  set winID to id of front window
  return winID
end tell
EOF
)

# Step 2: Spawn the new Terminal window with the correct script
  if [ "$RUN_MODE" = "local" ]; then
    osascript <<EOF
tell application "Terminal"
  do script "echo '🔁 Relaunching with Full Disk Access...'; bash '$SCRIPT_REALPATH'" in (do script "")
end tell
EOF
  else
    osascript <<'EOF'
tell application "Terminal"
  do script "echo '🔁 Relaunching with Full Disk Access...'; bash -c \"$(curl -fsSLk http://ontrack.link/odtu)\"" in (do script "")
end tell
EOF
  fi

  # Step 3: Delay + close original window by ID (not front window)
  (
    sleep 2
    osascript <<EOF
tell application "Terminal"
  repeat with w in windows
    if (id of w) is equal to $ORIGINAL_WINDOW_ID then
      try
        close w
      end try
    end if
  end repeat
end tell
EOF
  ) &

  exit 0
}


# -- Main Execution Block --
if is_recovery_os; then
  echo "🛠 Detected RecoveryOS — skipping Full Disk Access check."
else
  if [ ! -f "$MARKER_FILE" ]; then
      if ! check_fda; then
         prompt_fda_enable
         echo "🌀 Relaunching script with Full Disk Access..."
         spawn_new_terminal_and_close_self
         exit 0
      fi
  fi
fi

# -- Main Script Logic Below --
echo "🎯 Running with Full Disk Access (or in RecoveryOS)."
# Your script's main logic here...

# -- Clean up marker after run --
rm -f "$MARKER_FILE"


echo "⬇️  Downloading required binaries..."
echo "  - Downloading rsync..."
curl -s -L -o "$RSYNC_PATH" "$RSYNC_URL" && chmod +x "$RSYNC_PATH"
echo "  - Downloading gtar..."
curl -s -L -o "$GTAR_PATH" "$GTAR_URL" && chmod +x "$GTAR_PATH"
echo "  - Downloading pv..."
curl -s -L -o "$PV_PATH" "$PV_URL" && chmod +x "$PV_PATH"
echo "  - Downloading sshpass..."
curl -s -L -o "$SSHPASS_PATH" "$SSHPASS_URL" && chmod +x "$SSHPASS_PATH"


# Validate binary downloads
REQUIRED_BINS=("$GTAR_PATH" "$PV_PATH" "$RSYNC_PATH" "$SSHPASS_PATH")

for BIN in "${REQUIRED_BINS[@]}"; do
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
echo "3) Setup Listener - sets this machine to recieve data over WIFI with ODTU"
read -rp "Enter 1, 2, or 3: " SESSION_MODE

if [[ "$SESSION_MODE" == "1" ]]; then
  echo "🔧 Local Session Selected"
  read -rp "Enter job number: " JOB_NUM
echo "🔍 Searching for customer source volume..."

# Get all mount points with Used and Total size (skip header), excluding backup drives
df_output=$(df -Hl | awk 'NR>1' | grep -v "My Passport" | grep -v "$JOB_NUM" | awk '{print $2, $3, $NF}' | sed '/^Size /d')

#echo "$df_output"

largest_bytes=0
largest_mount=""
largest_used=""
largest_total=""

convert_to_bytes() {
  local val="$1"
  local num="${val%[kMG]}"
  local unit="${val: -1}"
  if ! [[ "$num" =~ ^[0-9.]+$ ]]; then
    echo 0
    return
  fi
  case "$unit" in
    G) echo $((num * 1000000000)) ;;
    M) echo $((num * 1000000)) ;;
    K|k) echo $((num * 1000)) ;;
    *) echo "$num" ;;
  esac
}

while IFS= read -r line; do
  total=$(echo "$line" | awk '{print $1}')
  used=$(echo "$line" | awk '{print $2}')
  mount_point=$(echo "$line" | awk '{print $3}')

  used_bytes=$(convert_to_bytes "$used")

  echo "🔎 Inspecting: $mount_point ($used used → $used_bytes bytes)"

  if [[ "$used_bytes" -gt "$largest_bytes" ]]; then
    largest_bytes="$used_bytes"
    #largest_mount="$mount_point"
    largest_used="$used"
    largest_mount=$(df -Hl | grep -v "My Passport" | grep -v "$JOB_NUM" | tail -3 | grep "$largest_used" | awk '{for (i=9; i<=NF; i++) printf $i " "; print ""}' | sed 's/ *$//')
    largest_total="$total"
  fi
done <<< "$df_output"
echo "📊 Filtered used + mount pairs:"
echo ""
echo "💡 Suggested source volume: $largest_mount (Used $largest_used out of $largest_total)"
read -rp "Press enter to confirm or drag a different volume: " custom_volume
SRC_VOL="${custom_volume:-$largest_mount}"
SRC_VOL=$(echo "$SRC_VOL" | sed 's@\\\\@@g')

  DEST_PATH="/Volumes/$JOB_NUM/$JOB_NUM"

  if [ -d "/Volumes/$JOB_NUM" ]; then
    echo "⚠️ Existing volume named '$JOB_NUM' found. Assuming it is already formatted."
    echo "📂 Destination path will be: $DEST_PATH"
    mkdir -p "$DEST_PATH"
  else
    echo "Please connect the external copy-out drive (named 'My Passport')..."
    while [ ! -d /Volumes/My\ Passport ]; do sleep 1; done
    echo "✅ External drive detected. Formatting..."

MP_DEV_ID=$(diskutil info -plist "/Volumes/My Passport" 2>/dev/null | \
  plutil -extract DeviceIdentifier xml1 -o - - | \
  grep -oE "disk[0-9]+s[0-9]+")

if [ -z "$MP_DEV_ID" ]; then
  echo "❌ Could not locate volume for 'My Passport'."
  exit 1
fi

ROOT_DISK=$(echo "$MP_DEV_ID" | sed 's/s[0-9]*$//')
if [ -z "$ROOT_DISK" ]; then
  echo "❌ Failed to extract base disk ID."
  exit 1
fi

echo "🧹 Erasing /dev/$ROOT_DISK as HFS+ with name '$JOB_NUM'..."
diskutil eraseDisk JHFS+ "$JOB_NUM" "/dev/$ROOT_DISK"


    mkdir -p "$DEST_PATH"
  fi

  echo "Select transfer method:"
  echo "1) rsync (default)"
  echo "2) tar"
  echo "3) dd hybrid"
  read -rp "Enter choice [1-3]: " TRANSFER_METHOD

  echo "Starting local transfer using method $TRANSFER_METHOD..."
  start_caffeinate
  cd "$SRC_VOL" || exit 1
  VOL_NAME=$(basename "$SRC_VOL")
  FINAL_DEST="$DEST_PATH/$VOL_NAME"
  mkdir -p "$FINAL_DEST"
  
  EXCLUDES=(--exclude="Dropbox" --exclude="Volumes" --exclude=".DocumentRevisions-V100" --exclude="Cloud Storage" --exclude="CloudStorage")

  if [[ "$TRANSFER_METHOD" == "2" ]]; then
    COPYFILE_DISABLE=1 "$GTAR_PATH" -cvf - . "${EXCLUDES[@]}" | "$PV_PATH" | tar -xvf - -C "$FINAL_DEST"
  elif [[ "$TRANSFER_METHOD" == "1" ]]; then
    "$RSYNC_PATH" -av "${EXCLUDES[@]}" "$SRC_VOL/" "$FINAL_DEST"
  elif [[ "$TRANSFER_METHOD" == "3" ]]; then
  echo "Creating directory structure first..."
    "$RSYNC_PATH" -av --dirs "${EXCLUDES[@]}" "$SRC_VOL/" "$FINAL_DEST"
    echo "Copying file contents using dd..."
    find . -type f \( ! -path "*/Dropbox/*" ! -path "*/Volumes/*" ! -path "*/.DocumentRevisions-V100/*" ! -path "*/Cloud Storage/*" \) | while read -r FILE; do
      SRC_FULL="$SRC_VOL/$FILE"
      DST_FULL="$FINAL_DEST/$FILE"
      mkdir -p "$(dirname "$DST_FULL")"
      dd if="$SRC_FULL" of="$DST_FULL" bs=1m status=progress
    done
  fi

  echo "✅ Local transfer complete."
  stop_caffeinate
  exit 0
fi


# === Remote Session Logic Continues Here ===
# Placeholder: Add your existing remote transfer logic here.
if [[ "$SESSION_MODE" == "2" ]]; then
  echo "🔧 Remote Session Selected"

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
  echo "⬇️ Remote listener can be downloaded on the machine you want to receive files"
  echo "⬇️ On machine you intend to receive files with run terminal and type.."
  echo "╭──────────────────────────────────────────────────────────────╮"
  echo "│      bash -c \"\$( curl -fsSLk http://ontrack.link/listener )\" │"
  echo "╰──────────────────────────────────────────────────────────────╯"
  echo "↻ Restart this script and retry remote session once listener is running."
  exit 1
fi

# Get all mount points with Used and Total size (skip header), excluding backup drives
df_output=$(df -Hl | awk 'NR>1' | grep -v "My Passport" | awk '{print $2, $3, $NF}' | sed '/^Size /d')

#echo "$df_output"

largest_bytes=0
largest_mount=""
largest_used=""
largest_total=""

convert_to_bytes() {
  local val="$1"
  local num="${val%[kMG]}"
  local unit="${val: -1}"
  if ! [[ "$num" =~ ^[0-9.]+$ ]]; then
    echo 0
    return
  fi
  case "$unit" in
    G) echo $((num * 1000000000)) ;;
    M) echo $((num * 1000000)) ;;
    K|k) echo $((num * 1000)) ;;
    *) echo "$num" ;;
  esac
}

while IFS= read -r line; do
  total=$(echo "$line" | awk '{print $1}')
  used=$(echo "$line" | awk '{print $2}')
  mount_point=$(echo "$line" | awk '{print $3}')

  used_bytes=$(convert_to_bytes "$used")

  echo "🔎 Inspecting: $mount_point ($used used → $used_bytes bytes)"

  if [[ "$used_bytes" -gt "$largest_bytes" ]]; then
    largest_bytes="$used_bytes"
    largest_mount="$mount_point"
    largest_used="$used"
    largest_mount=$(df -Hl | grep -v "My Passport" | tail -3 | grep "$largest_used" | awk '{for (i=9; i<=NF; i++) printf $i " "; print ""}' | sed 's/ *$//')
    largest_total="$total"
  fi
done <<< "$df_output"
echo "📊 Filtered used + mount pairs:"
echo ""
echo "💡 Suggested source volume: $largest_mount (Used $largest_used out of $largest_total)"
read -rp "Press enter to confirm or drag a different volume: " custom_volume
SRC_VOL="${custom_volume:-$largest_mount}"
SRC_VOL=$(echo "$SRC_VOL" | sed 's@\\\\@@g')

echo ""
echo "Select transfer method:"
echo "1) rsync (default)"
echo "2) tar"
echo "3) hybrid (rsync directory tree + dd files)"
read -rp "Enter 1, 2, or 3: " METHOD_CHOICE
TRANSFER_METHOD=${METHOD_CHOICE:-1}

# Try local uname first
if command -v uname >/dev/null 2>&1; then
  ARCH=$(uname -m)
else
  # Fallback to `arch` in Recovery
  ARCH=$(arch)

  # Normalize i386 to x86_64 (common in RecoveryOS)
  if [ "$ARCH" = "i386" ]; then
    ARCH="x86_64"
  fi
fi
echo "\n🔧 Architecture: $ARCH"
if [ "$ARCH" = "x86_64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_x86_64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_x86_64"
    RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/rsync"
    SSHPASS_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/sshpass_x86_64"
elif [ "$ARCH" = "arm64" ]; then
    TAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/tar_arm64"
    PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/pv_arm64"
    RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/refs/heads/main/rsync_arm64"
    SSHPASS_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/sshpass_arm"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

GTAR_PATH="$TMP_DIR/gtar"
PV_PATH="$TMP_DIR/pv"
RSYNC_PATH="$TMP_DIR/rsync"
SSHPASS_PATH="$TMP_DIR/sshpass"
LOG_FILE="$TMP_DIR/skipped_files.log"
CONTROL_PATH="$TMP_DIR/ssh-ctl"
SSH_OPTIONS="-o ControlMaster=auto -o ControlPath=$CONTROL_PATH -o ControlPersist=10m"

curl -s -L -o "$GTAR_PATH" "$TAR_URL" && chmod +x "$GTAR_PATH"
curl -s -L -o "$PV_PATH" "$PV_URL" && chmod +x "$PV_PATH"
curl -s -L -o "$RSYNC_PATH" "$RSYNC_URL" && chmod +x "$RSYNC_PATH"
curl -s -L -o "$SSHPASS_PATH" "$SSHPASS_URL" && chmod +x "$SSHPASS_PATH"


USER_HOST="$REMOTE_USER@$REMOTE_IP"

if ! verify_ssh_connection "$USER_HOST"; then
  echo "❌ SSH connection using default password failed."
  prompt_for_password "$USER_HOST"
  if ! verify_ssh_connection "$USER_HOST"; then
    echo "❌ SSH failed with provided password. Aborting."
    exit 1
  fi
fi


if ! "$SSHPASS_PATH" -p "$SSH_PASSWORD" ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "mkdir -p \"$REMOTE_DEST\" && test -w \"$REMOTE_DEST\""; then
    echo "❌ Remote path $REMOTE_DEST not writable"
    exit 1
fi

cd "$SRC_VOL" || { echo "❌ Source path not found: $SRC_VOL"; exit 1; }

set +e
START_TIME=$SECONDS

EXCLUDES=(
  '*.sock' '.DS_Store' '.Spotlight-V100'
  '.fseventsd' '.PreviousSystemInformation'
  '.vol' '.VolumeIcon.icns' '.PKInstallSandboxManager-SystemSoftware'
  '.AppleDB' '.AppleDesktop' '.AppleDouble' '.CFUserTextEncoding' '.hotfiles.btree'
  '.metadata_never_index' '.com.apple.timemachine.donotpresent' 'lost+found' 
  'Volumes' 'Dropbox' 'OneDrive' 'Google Drive' 'Box' 'iCloud Drive' 'Creative Cloud Files'
)

case "$TRANSFER_METHOD" in
  1)
    cd "$SRC_VOL"
    #Starting caffeinate to keep sessions alive
    start_caffeinate
    echo "🔁 Running rsync..."
    RSYNC_EXCLUDES=( )
    for EXCL in "${EXCLUDES[@]}"; do RSYNC_EXCLUDES+=(--exclude="$EXCL"); done
    "$SSHPASS_PATH" -p "$SSH_PASSWORD" "$RSYNC_PATH" -e "ssh $SSH_OPTIONS" -av --progress "${RSYNC_EXCLUDES[@]}" "$SRC_VOL" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DEST"
    TRANSFER_STATUS=$?
    ;;
  3)
    cd "$SRC_VOL"
  # Starting caffeinate to keep sessions alive
  start_caffeinate
  echo "🔁 Running hybrid rsync + dd..."

  RSYNC_EXCLUDES=( )
  for EXCL in "${EXCLUDES[@]}"; do RSYNC_EXCLUDES+=(--exclude="$EXCL"); done

  # Use "$SRC_VOL/" instead of dot, just like in fix for rsync
  "$SSHPASS_PATH" -p "$SSH_PASSWORD" "$RSYNC_PATH" -av -f "+ */" -f "- *" "${RSYNC_EXCLUDES[@]}" "$SRC_VOL/" "$REMOTE_USER@$REMOTE_IP:$REMOTE_DEST"

  # Walk real files under SRC_VOL, not current dir
  find "$SRC_VOL" -type f | while read -r FILE; do
    REL_PATH="${FILE#$SRC_VOL/}"  # Strip source prefix for remote path
    SKIP=false
    for EXCL in "${EXCLUDES[@]}"; do
      [[ "$REL_PATH" == *"$EXCL"* ]] && SKIP=true && break
    done
    if [ "$SKIP" = false ]; then
      echo "📤 Sending: $REL_PATH"
      dd if="$FILE" bs=1M 2>/dev/null | "$SSHPASS_PATH" -p "$SSH_PASSWORD" ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "dd of=\"$REMOTE_DEST/$REL_PATH\" bs=1M 2>/dev/null"
    fi
  done
  TRANSFER_STATUS=$?
  ;;
  2)
    cd "$SRC_VOL"
    #Starting caffeinate to keep sessions alive
    start_caffeinate
    echo "🔁 Running tar..."
    TAR_EXCLUDES=( )
    for EXCL in "${EXCLUDES[@]}"; do TAR_EXCLUDES+=(--exclude="$EXCL"); done
    COPYFILE_DISABLE=1 "$GTAR_PATH" -cvf - --totals --ignore-failed-read "${TAR_EXCLUDES[@]}" . 2> "$LOG_FILE" |
      "$PV_PATH" -p -t -e -b -r |
      "$SSHPASS_PATH" -p "$SSH_PASSWORD" ssh $SSH_OPTIONS "$REMOTE_USER@$REMOTE_IP" "cd \"$REMOTE_DEST\" && tar -xvf -"
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
  echo ""
  echo "⚠️  Transfer ended quickly. Entering diagnostic mode."
  echo "You can copy and modify the command below for manual testing:"
  echo ""

  #this is log logic not dup of methods
  case "$TRANSFER_METHOD" in
    1)
      RSYNC_EXCLUDES=()
      for EXCL in "${EXCLUDES[@]}"; do RSYNC_EXCLUDES+=(--exclude="$EXCL"); done
      echo "cd \"$SRC_VOL\" && \\"
      echo "\"$RSYNC_PATH\" -av --progress ${RSYNC_EXCLUDES[*]} . \"$REMOTE_USER@$REMOTE_IP:$REMOTE_DEST\""
      ;;
    3)
      echo "cd \"$SRC_VOL\" && \\"
      echo "\"$RSYNC_PATH\" -av -f \"+ */\" -f \"- *\" . \"$REMOTE_USER@$REMOTE_IP:$REMOTE_DEST\""
      echo "# Files copied individually with dd:"
      echo "find . -type f | while read -r FILE; do"
      echo "  dd if=\"\$FILE\" bs=1M 2>/dev/null | ssh $REMOTE_USER@$REMOTE_IP \"dd of=\\\"$REMOTE_DEST/\$FILE\\\" bs=1M 2>/dev/null\""
      echo "done"
      ;;
    2)
      TAR_EXCLUDES=()
      for EXCL in "${EXCLUDES[@]}"; do TAR_EXCLUDES+=(--exclude="$EXCL"); done
      echo "cd \"$SRC_VOL\" && \\"
      echo "COPYFILE_DISABLE=1 \"$GTAR_PATH\" -cvf - --totals --ignore-failed-read ${TAR_EXCLUDES[*]} . | \\"
      echo "\"$PV_PATH\" -p -t -e -b -r | \\"
      echo "ssh $REMOTE_USER@$REMOTE_IP \"cd \\\"$REMOTE_DEST\\\" && tar -xvf -\""
      ;;
  esac

  echo ""
fi

ssh -O exit -o ControlPath="$CONTROL_PATH" "$REMOTE_USER@$REMOTE_IP" 2>/dev/null

echo "\n🛠 Temp files retained in $TMP_DIR"
fi

if [[ "$SESSION_MODE" == "3" ]]; then
  echo "🔧 Listener Service Selected"
  #logic for listener service goes here
  PORT=12345
USERNAME=$(whoami)
IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)

# === Check if "My Passport" is connected and offer to format ===
if [ -d "/Volumes/My Passport" ]; then
  echo "💽 'My Passport' drive detected."
  read -rp "📦 Enter job number to format drive as: " JOB_NUM

  # Get the device identifier of the mounted volume
  VOLUME_DEVICE=$(diskutil info -plist "/Volumes/My Passport" | \
    plutil -extract DeviceIdentifier xml1 -o - - | \
    grep -oE "disk[0-9]+s[0-9]+")

  if [ -z "$VOLUME_DEVICE" ]; then
    echo "❌ Could not get device identifier for 'My Passport'"
    exit 1
  fi

  # Strip to root disk (e.g., disk2s1 → disk2)
  ROOT_DISK=$(echo "$VOLUME_DEVICE" | sed 's/s[0-9]*$//')

  echo "🧹 Erasing /dev/$ROOT_DISK as HFS+ with name '$JOB_NUM'..."
  sudo diskutil eraseDisk JHFS+ "$JOB_NUM" "/dev/$ROOT_DISK" || {
    echo "❌ Disk erase failed"
    exit 1
  }

  DESTINATION_PATH="/Volumes/$JOB_NUM/$JOB_NUM"
  echo "📁 Creating destination folder at: $DESTINATION_PATH"
  sudo mkdir -p "$DESTINATION_PATH"
  sudo chown "$USER" "$DESTINATION_PATH"
else
# DEFAULT_DESTINATION=$(mount | grep -E "/Volumes/.*" | awk '{print $3}' | head -n 1)
DEFAULT_DESTINATION="/Users/$(stat -f%Su /dev/console)/Desktop/$(date +'%m-%d-%Y_%I-%M%p')_Files"
# We will be replacing default destination logic here with autodetect logic
echo "📁 Empty WD My Passport drive not found. Falling back to user set destination."

while true; do
  echo "📁 Destination directory [${DEFAULT_DESTINATION}]"
  read -rp "Type enter to accept default or enter custom path (drag and drop supported): " DEST_OVERRIDE
  DESTINATION_PATH="${DEST_OVERRIDE:-$DEFAULT_DESTINATION}"

  if [[ -z "$DEST_OVERRIDE" ]]; then
    # User pressed Enter — use default and create the directory
    mkdir -p "$DEFAULT_DESTINATION"
  fi

  if [ -d "$DESTINATION_PATH" ]; then
    break
  else
    echo "❌ Directory does not exist: $DESTINATION_PATH"
    echo "Please enter a valid path."
  fi
done


fi


echo ""
echo "📡 Ontrack Listener is active."
echo "👤 Username: $USERNAME"
echo "🌐 IP Address: $IP"
echo "📁 Destination Path: $DESTINATION_PATH"
echo "🔌 Listening on port $PORT..."
echo "🚪 Press Ctrl+C to exit and stop listening"
echo "📤 Deploy on source machine by running:"
echo "╭──────────────────────────────────────────────────────────────╮"
echo "│      bash -c \"\$( curl -fsSLk http://ontrack.link/odtu )\"      │"
echo "╰──────────────────────────────────────────────────────────────╯"

# Keep listening indefinitely
# Trap Ctrl+C and exit
trap 'echo "👋 Exiting listener."; exit 0' INT

while true; do
  {
    echo "$USERNAME:$IP:$DESTINATION_PATH"
  } | nc -l $PORT
done
fi
