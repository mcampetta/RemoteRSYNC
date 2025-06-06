#!/bin/bash

# === Ontrack Transfer Utility - V1.110 ===
# Adds optional rsync and dd (hybrid) support alongside tar transfer

clear

# Display ASCII welcome art and header
echo ""
echo "██████╗ ███╗   ██╗████████╗██████╗  █████╗  ██████╗██╗  ██╗"
echo "██╔═══██╗████╗  ██║╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝"
echo "██║   ██║██╔██╗ ██║   ██║   ██████╔╝███████║██║     █████╔╝ "
echo "██║   ██║██║╚██╗██║   ██║   ██╔███╗ ██╔══██║██║     ██╔═██╗ "
echo "╚██████╔╝██║ ╚████║   ██║   ██║ ███╗██║  ██║╚██████╗██║  ██╗"
echo " ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝ ╚══╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
echo " ONTRACK DATA TRANSFER UTILITY V1.110 (tar, rsync, or dd-hybrid)"
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
  declare -A UNIQUE_LISTENERS
  LISTENERS=()
  INDEX=1
  while IFS= read -r LINE; do
    TARGET=$(echo "$LINE" | cut -d':' -f1)
    PAYLOAD=$(echo "$LINE" | cut -d':' -f2-)
    R_USER=$(echo "$PAYLOAD" | cut -d':' -f1)
    R_IP=$(echo "$PAYLOAD" | cut -d':' -f2)
    R_DEST=$(echo "$PAYLOAD" | cut -d':' -f3)
    R_IFACE=$(echo "$PAYLOAD" | cut -d':' -f4)
    KEY="$R_USER@$R_IP:$R_DEST"
    if [[ -z "${UNIQUE_LISTENERS[$KEY]}" ]]; then
      UNIQUE_LISTENERS[$KEY]="$R_IFACE"
      IF_TYPE="(${R_IFACE})"
      LISTENERS+=("$R_USER:$R_IP:$R_DEST")
      echo "$INDEX) $R_USER@$R_IP -> $R_DEST $IF_TYPE"
      ((INDEX++))
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

# (rest of the script remains unchanged)
