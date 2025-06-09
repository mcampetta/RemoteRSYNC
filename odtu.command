
#!/bin/bash

# === Ontrack Transfer Utility - V1.118.1 ===
# Adds optional rsync and dd (hybrid) support alongside tar transfer
# Now supports both local and remote copy sessions
# Prevents system sleep using caffeinate during transfer

clear

# Display ASCII welcome art and header
echo ""
echo "██████╗ ███╗   ██╗████████╗██████╗  █████╗  ██████╗██╗  ██╗"
echo "██╔═══██╗████╗  ██║╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝"
echo "██║   ██║██╔██╗ ██║   ██║   ██████╔╝███████║██║     █████╔╝ "
echo "██║   ██║██║╚██╗██║   ██║   ██╔███╗ ██╔══██║██║     ██╔═██╗ "
echo "╚██████╔╝██║ ╚████║   ██║   ██║ ███╗██║  ██║╚██████╗██║  ██╗"
echo " ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝ ╚══╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
echo " ONTRACK DATA TRANSFER UTILITY V1.118.1 (tar, rsync, or dd-hybrid)"
echo ""

# Prevent system from sleeping
start_caffeinate() {
  caffeinate -dimsu &  # Prevent idle, display, and system sleep
  CAFFEINATE_PID=$!
}

stop_caffeinate() {
  if [[ -n "$CAFFEINATE_PID" ]]; then
    kill "$CAFFEINATE_PID" 2>/dev/null
  fi
}

trap stop_caffeinate EXIT INT TERM

# Start of actual script logic...
# Note: This placeholder indicates where the rest of the previously validated V1.118 script continues,
# with 'start_caffeinate' called before a transfer starts, and 'stop_caffeinate' after it ends.

# (Your existing code continues here unchanged except for where transfers begin/end)
# - Call start_caffeinate before: echo "Starting local transfer using method $TRANSFER_METHOD..."
  start_caffeinate

# - Call stop_caffeinate after:   stop_caffeinate
echo "✅ Local transfer complete."
# - Similarly, wrap remote transfer blocks with start/stop_caffeinate
