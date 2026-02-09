#!/bin/bash
# === Ontrack Transfer Utility - V1.1420-hardened ===
# Adds optional rsync and tar support alongside local and remote copy sessions
# Uses downloaded binaries to avoid RecoveryOS tool limitations
# Hardened: strict mode, quoting, APFS detection, logging, integrity checks

# ── Strict mode ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Error handler ────────────────────────────────────────────────────────────
_error_handler() {
  local lineno="$1" cmd="$2" code="$3"
  echo "" >&2
  echo "❌ ERROR on line ${lineno}: command '${cmd}' exited with status ${code}" >&2
}
trap '_error_handler "${LINENO}" "${BASH_COMMAND:-unknown}" "$?"' ERR

# ── Cleanup trap ─────────────────────────────────────────────────────────────
CAFFEINATE_PID=""
TMP_DIR=""
# shellcheck disable=SC2034
SSH_CONTROL_PATH=""  # reserved for future ControlMaster support
LOG_FILE=""
RSYNC_RUNTIME_OPTS=()

cleanup() {
  local ec=$?
  # Stop caffeinate
  if [[ -n "${CAFFEINATE_PID}" ]]; then
    kill "${CAFFEINATE_PID}" 2>/dev/null || true
  fi
  # Remove temp dir
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
  # Close SSH control socket (only if ControlMaster is actually in use).
  # NOTE: ODTU currently does not establish ControlMaster sessions, so we avoid
  # trying to close a socket using a fake host ("dummy"), which can hang or fail.
  # If you later add ControlMaster support, gate this on a known USER_HOST and use:
  # ssh -o BatchMode=yes -o ConnectTimeout=2 -O exit -S "${SSH_CONTROL_PATH}" "${USER_HOST}" || true
  if [[ -n "${LOG_FILE}" && -f "${LOG_FILE}" ]]; then
    log_msg "Script exiting with code ${ec}"
  fi
  exit "${ec}"
}
trap cleanup EXIT

# ── Banner ───────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo "██████╗ ███╗   ██╗████████╗██████╗  █████╗  ██████╗██╗  ██╗"
echo "██╔═══██╗████╗  ██║╚══██╔══╝██╔══██╗██╔══██╗██╔════╝██║ ██╔╝"
echo "██║   ██║██╔██╗ ██║   ██║   ██████╔╝███████║██║     █████╔╝ "
echo "██║   ██║██║╚██╗██║   ██║   ██╔███╗ ██╔══██║██║     ██╔═██╗ "
echo "╚██████╔╝██║ ╚████║   ██║   ██║ ███╗██║  ██║╚██████╗██║  ██╗"
echo " ╚═════╝ ╚═╝  ╚═══╝   ╚═╝   ╚═╝ ╚══╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝"
echo " ONTRACK DATA TRANSFER UTILITY V1.1433-hardened (tar, rsync)"
echo ""

# ── Architecture detection ───────────────────────────────────────────────────
if command -v uname >/dev/null 2>&1; then
  ARCH=$(uname -m)
else
  ARCH=$(arch)
  if [[ "${ARCH}" == "i386" ]]; then
    ARCH="x86_64"
  fi
fi

TMP_DIR=$(mktemp -d)

# ── SSH defaults ─────────────────────────────────────────────────────────────
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
SSH_PASSWORD="ontrack123"

###############################################################################
# Functions                                                                   #
###############################################################################

# ── Logging ──────────────────────────────────────────────────────────────────
init_log() {
  local log_dir="$1"
  mkdir -p "${log_dir}"
  LOG_FILE="${log_dir}/odtu_transfer_$(date +%Y%m%d_%H%M%S).log"
  log_msg "=== ODTU Transfer Log ==="
  log_msg "Start time: $(date)"
  log_msg "Architecture: ${ARCH}"
  log_msg "Hostname: $(hostname 2>/dev/null || echo unknown)"
}

log_msg() {
  local ts
  ts="$(date +%H:%M:%S 2>/dev/null || echo '--:--:--')"
  echo "[${ts}] $*" >> "${LOG_FILE}"
}

log_tool_versions() {
  log_msg "--- Tool versions ---"
  log_msg "rsync: $("${RSYNC_PATH}" --version 2>/dev/null | head -1 || echo 'unknown')"
  log_msg "gtar:  $("${GTAR_PATH}" --version 2>/dev/null | head -1 || echo 'unknown')"
  log_msg "pv:    $("${PV_PATH}" --version 2>/dev/null | head -1 || echo 'unknown')"
  log_msg "sshpass: $("${SSHPASS_PATH}" -V 2>&1 | head -1 || echo 'unknown')"
}

# ── Caffeinate ───────────────────────────────────────────────────────────────
start_caffeinate() {
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -dimsu &
    CAFFEINATE_PID=$!
  else
    echo "ℹ️  caffeinate not available (RecoveryOS) — skipping sleep prevention."
  fi
}

stop_caffeinate() {
  if [[ -n "${CAFFEINATE_PID}" ]]; then
    kill "${CAFFEINATE_PID}" 2>/dev/null || true
    CAFFEINATE_PID=""
  fi
}

# ── SSH helpers ──────────────────────────────────────────────────────────────
verify_ssh_connection() {
  local user_host="$1"
  echo "🔐 Attempting SSH connection using sshpass..."
  # shellcheck disable=SC2086
  "${SSHPASS_PATH}" -p "${SSH_PASSWORD}" ssh ${SSH_OPTIONS} -o ConnectTimeout=5 "${user_host}" "echo OK" >/dev/null 2>&1
}

prompt_for_password() {
  echo ""
  read -rsp "🔑 Enter SSH password for $1: " SSH_PASSWORD
  echo ""
}

# Build a remote shell command with proper quoting via printf %q
remote_cmd() {
  local cmd=""
  local arg
  for arg in "$@"; do
    if [[ -n "${cmd}" ]]; then
      cmd+=" "
    fi
    cmd+=$(printf '%q' "${arg}")
  done
  echo "${cmd}"
}

# ── Path normalization ───────────────────────────────────────────────────────
normalize_path() {
  local p="$1"
  # Trim leading/trailing whitespace
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  # Strip matching surrounding quotes
  if [[ "${p}" =~ ^\".*\"$ || "${p}" =~ ^\'.*\'$ ]]; then
    p="${p:1:${#p}-2}"
  fi
  # If it contains backslashes, interpret escapes via printf %b
  if [[ "${p}" == *\\* ]]; then
    p="$(printf '%b' "${p//%/%%}")"
  fi
  echo "${p}"
}

# ── Readline completion ──────────────────────────────────────────────────────
enable_readline_path_completion() {
  [[ -t 0 && -t 1 ]] || return 0
  local had_errexit=0
  case $- in *e*) had_errexit=1; set +e ;; esac
  bind 'set completion-ignore-case on'      2>/dev/null || true
  bind 'set show-all-if-ambiguous on'       2>/dev/null || true
  bind 'set mark-symlinked-directories on'  2>/dev/null || true
  bind '"\t": complete'                     2>/dev/null || true
  (( had_errexit )) && set -e
  return 0
}

# ── Exclude list editor ─────────────────────────────────────────────────────
init_default_excludes() {
  EXCLUDES=(
    "Dropbox" ".DocumentRevisions-V100"
    "Cloud Storage" "CloudStorage" "OneDrive" "Google Drive" "Box"
    ".DS_Store" ".Spotlight-V100" ".fseventsd" ".vol" ".VolumeIcon.icns"
    ".AppleDB" ".AppleDesktop" ".AppleDouble" ".CFUserTextEncoding"
    ".hotfiles.btree" ".metadata_never_index"
    ".com.apple.timemachine.donotpresent" "lost+found"
    ".PKInstallSandboxManager-SystemSoftware"
    "iCloud Drive" "Creative Cloud Files"
  )
}

edit_excludes() {
  while true; do
    echo ""
    echo "📦 Current Exclude List:"
    for i in "${!EXCLUDES[@]}"; do
      printf "  [%2d] %s\n" "$((i+1))" "${EXCLUDES[$i]}"
    done

    echo ""
    echo "Options:"
    echo "  A - Add new exclude"
    echo "  R - Remove an exclude by number"
    echo "  V - View list again"
    echo "  D - Done (use current list)"
    read -rp "➡️  Enter choice [A/R/V/D]: " action

    case "${action}" in
      [Aa])
        read -rp "Enter value to exclude (e.g., .DS_Store): " new_excl
        new_excl="$(echo "${new_excl}" | xargs)"
        if [[ -n "${new_excl}" ]]; then
          EXCLUDES+=("${new_excl}")
          echo "✅ Added: ${new_excl}"
        fi
        ;;
      [Rr])
        read -rp "Enter the number of the exclude to remove: " idx
        idx=$((idx - 1))
        if [[ ${idx} -ge 0 && ${idx} -lt ${#EXCLUDES[@]} ]]; then
          echo "❌ Removed: ${EXCLUDES[$idx]}"
          unset 'EXCLUDES[idx]'
          EXCLUDES=(${EXCLUDES[@]+"${EXCLUDES[@]}"})
        else
          echo "⚠️ Invalid index."
        fi
        ;;
      [Vv]) continue ;;
      [Dd])
        echo "✅ Final exclude list confirmed."
        break
        ;;
      *) echo "⚠️ Invalid input. Please enter A, R, V, or D." ;;
    esac
  done
}

# Build rsync and tar exclude arrays from EXCLUDES
compile_exclude_flags() {
  RSYNC_EXCLUDES=()
  TAR_EXCLUDES=()
  for excl in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    RSYNC_EXCLUDES+=(--exclude="${excl}")
    TAR_EXCLUDES+=(--exclude="${excl}")
  done
}

# ── Rsync runtime options (strict vs best-effort) ────────────────────────────
# Best-effort helps when you hit Permission denied / transient read errors:
# - resumes (partial)
# - continues past errors (ignore-errors)
# - avoids wasting 15 minutes on restart loops
choose_rsync_runtime_mode() {
  RSYNC_RUNTIME_OPTS=()

  # In limited access mode, force best-effort — strict mode would fail
  # on every permission-denied file and abort the transfer.
  if [[ -n "${LIMITED_ACCESS_MODE}" ]]; then
    echo ""
    echo "ℹ️  Limited access mode: using best-effort rsync (skips unreadable files)."
    RSYNC_RUNTIME_OPTS+=(--partial --partial-dir=.rsync-partial --ignore-errors)
    if "${RSYNC_PATH}" --help 2>&1 | grep -q -- 'progress2'; then
      RSYNC_RUNTIME_OPTS+=(--info=progress2)
    else
      RSYNC_RUNTIME_OPTS+=(--progress)
    fi
  else
    echo ""
    while true; do
      echo "Rsync mode:"
      echo "1) Strict (fail on read/permission errors)"
      echo "2) Best-effort (resume + continue past unreadable files)"
      read -rp "Enter 1 or 2 [2]: " RSYNC_MODE
      RSYNC_MODE="${RSYNC_MODE:-2}"
      case "${RSYNC_MODE}" in
        1|2) break ;;
        *) echo "⚠️ Invalid selection '${RSYNC_MODE}'. Please enter 1 or 2." ; echo "" ;;
      esac
    done

    if [[ "${RSYNC_MODE}" == "2" ]]; then
      RSYNC_RUNTIME_OPTS+=(--partial --partial-dir=.rsync-partial --ignore-errors)
      # No --timeout here: in best-effort mode we want resilience over speed.
      # RecoveryOS volumes and damaged drives can stall reads well beyond 30s.
      # SSH keepalives (ServerAliveInterval in SSH_OPTIONS) already detect
      # dead connections without killing slow-but-progressing transfers.

      # Prefer progress2 if supported (rsync 3.x). Otherwise fallback to --progress.
      if "${RSYNC_PATH}" --help 2>&1 | grep -q -- 'progress2'; then
        RSYNC_RUNTIME_OPTS+=(--info=progress2)
      else
        RSYNC_RUNTIME_OPTS+=(--progress)
      fi
    else
      # Strict: fail on errors but add a generous safety timeout so rsync
      # can never hang indefinitely (e.g. protocol mismatch, stuck read).
      # 5 minutes of zero I/O is well beyond any normal disk stall.
      RSYNC_RUNTIME_OPTS+=(--timeout=300)
      if "${RSYNC_PATH}" --help 2>&1 | grep -q -- 'progress2'; then
        RSYNC_RUNTIME_OPTS+=(--info=progress2)
      else
        RSYNC_RUNTIME_OPTS+=(--progress)
      fi
    fi
  fi

  if [[ -n "${LOG_FILE}" ]]; then
    log_msg "Rsync runtime opts: ${RSYNC_RUNTIME_OPTS[*]+"${RSYNC_RUNTIME_OPTS[*]}"}"
  fi
}

# ── APFS Data volume detection ───────────────────────────────────────────────
# Sets DETECTED_APFS_MOUNT and DATA_DETECT_METHOD as global variables.
# Returns 0 on success, 1 on failure.
# NOTE: Must NOT be called inside a command substitution ($(...)) or the
#       global variables will be lost in the subshell.

# Sanity-check a candidate data volume.  A real customer data volume will
# contain a /Users directory with at least one real home folder.  The synthetic
# /System/Volumes/Data scaffold that exists in RecoveryOS (~27 MB) has only
# system dirs like Shared, Guest, .localized — no actual user homes.
_validate_data_volume() {
  local mount="$1"
  [[ -d "${mount}" ]] || return 1

  # Look for a Users directory with at least one REAL home folder.
  # Exclude system-only directories that exist on the scaffold.
  if [[ -d "${mount}/Users" ]]; then
    local real_users=0
    local entry
    for entry in "${mount}/Users"/*/; do
      [[ -d "${entry}" ]] || continue
      local basename
      basename="$(basename "${entry}")"
      # Skip known system directories
      case "${basename}" in
        Shared|Guest|.localized|_*) continue ;;
      esac
      # A real home folder will have Library, Desktop, or Documents
      if [[ -d "${entry}/Library" || -d "${entry}/Desktop" || -d "${entry}/Documents" ]]; then
        real_users=$((real_users + 1))
      fi
    done
    if [[ "${real_users}" -gt 0 ]]; then
      return 0
    fi
  fi

  return 1
}

detect_apfs_data_volume() {
  DATA_DETECT_METHOD=""
  DETECTED_APFS_MOUNT=""

  # Method 1: diskutil apfs list — look for the Data role volume
  if command -v diskutil >/dev/null 2>&1; then
    local data_mount
    # IMPORTANT: Mount points commonly contain spaces (e.g. "/Volumes/Macintosh HD - Data").
    # So we must capture the full remainder of the line, not $NF.
    data_mount=$(
      diskutil apfs list 2>/dev/null | awk '
        /^[[:space:]]*Role:[[:space:]]*/ {
          role=$0
          sub(/^[[:space:]]*Role:[[:space:]]*/, "", role)
        }
        /^[[:space:]]*Mount Point:[[:space:]]*/ {
          mp=$0
          sub(/^[[:space:]]*Mount Point:[[:space:]]*/, "", mp)
          # Accept "Data" role, including formats like "(Data)" or "Data, something"
          if (role ~ /(^|[[:space:]]|\()Data(\)|$|,)/) print mp
        }
      ' | head -1
    )
    # Trim whitespace
    data_mount="${data_mount#"${data_mount%%[![:space:]]*}"}"
    data_mount="${data_mount%"${data_mount##*[![:space:]]}"}"
    if [[ -n "${data_mount}" && -d "${data_mount}" ]]; then
      if _validate_data_volume "${data_mount}"; then
        DATA_DETECT_METHOD="diskutil apfs list (Data role)"
        DETECTED_APFS_MOUNT="${data_mount}"
        return 0
      else
        echo "⚠️  Found Data volume at ${data_mount} but it appears empty (no user data)."
        echo "   This is likely the system scaffold, not the customer data volume."
      fi
    fi
  fi

  # Method 2: well-known path — also validate it has real content
  if [[ -d "/System/Volumes/Data" ]]; then
    if _validate_data_volume "/System/Volumes/Data"; then
      DATA_DETECT_METHOD="/System/Volumes/Data fallback"
      DETECTED_APFS_MOUNT="/System/Volumes/Data"
      return 0
    fi
  fi

  DATA_DETECT_METHOD=""
  return 1
}

# ── Largest-used-volume heuristic ────────────────────────────────────────────
convert_to_bytes() {
  local val="$1"
  local num="${val%[kKMGTP]}"
  local unit="${val: -1}"
  if ! [[ "${num}" =~ ^[0-9.]+$ ]]; then
    echo 0
    return
  fi
  case "${unit}" in
    T) awk "BEGIN { printf \"%0.f\", ${num} * 1000000000000 }" ;;
    G) awk "BEGIN { printf \"%0.f\", ${num} * 1000000000 }" ;;
    M) awk "BEGIN { printf \"%0.f\", ${num} * 1000000 }" ;;
    K|k) awk "BEGIN { printf \"%0.f\", ${num} * 1000 }" ;;
    *)  awk "BEGIN { printf \"%0.f\", ${num} }" ;;
  esac
}

find_largest_volume() {
  local job_filter="${1:-}"
  DETECTED_MOUNT=""
  DETECTED_USED=""
  DETECTED_TOTAL=""
  local df_output
  df_output=$(df -Hl | awk 'NR>1 {
    # Reconstruct mount point from field 9 onwards
    mp=""; for(i=9;i<=NF;i++) mp=(mp ? mp " " $i : $i);
    print $2, $3, mp
  }' | grep -v "My Passport")

  if [[ -n "${job_filter}" ]]; then
    df_output=$(echo "${df_output}" | grep -v "${job_filter}")
  fi

  # Check for Ontrack-named volumes before filtering them out
  local ontrack_volumes=""
  ontrack_volumes=$(echo "${df_output}" | grep -i "ontrack" || true)
  if [[ -n "${ontrack_volumes}" ]]; then
    echo ""
    echo "⚠️  The following volume(s) contain 'Ontrack' in their name and were filtered:"
    echo "${ontrack_volumes}" | while IFS= read -r ov; do
      local ov_mount
      ov_mount=$(echo "${ov}" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}')
      echo "    - ${ov_mount}"
    done
    read -rp "Include Ontrack volume(s) anyway? (y/N): " include_ontrack
    if [[ "${include_ontrack}" =~ ^[Yy]$ ]]; then
      echo "✅ Including Ontrack volume(s) in detection."
    else
      df_output=$(echo "${df_output}" | grep -vi "ontrack")
    fi
  fi
  df_output=$(echo "${df_output}" | sed '/^$/d')

  local largest_bytes=0
  local largest_mount=""
  local largest_used=""
  local largest_total=""

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local total used mount_point used_bytes
    total=$(echo "${line}" | awk '{print $1}')
    used=$(echo "${line}" | awk '{print $2}')
    # Mount point is everything from field 3 onward
    mount_point=$(echo "${line}" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":""); print ""}')
    used_bytes=$(convert_to_bytes "${used}")

    echo "🔎 Inspecting: ${mount_point} (${used} used → ${used_bytes} bytes)"

    if [[ "${used_bytes}" -gt "${largest_bytes}" ]]; then
      largest_bytes="${used_bytes}"
      largest_mount="${mount_point}"
      largest_used="${used}"
      largest_total="${total}"
    fi
  done <<< "${df_output}"

  DETECTED_MOUNT="${largest_mount}"
  DETECTED_USED="${largest_used}"
  DETECTED_TOTAL="${largest_total}"
}

# ── Source volume selection (combines APFS detect + heuristic) ────────────────
select_source_volume() {
  local job_filter="${1:-}"
  local suggested=""
  local method=""

  echo "🔍 Searching for customer source volume..."

  # Try APFS Data volume detection first (called directly, NOT in a subshell)
  if detect_apfs_data_volume; then
    suggested="${DETECTED_APFS_MOUNT}"
    method="${DATA_DETECT_METHOD}"
    echo "📀 Detected APFS Data volume: ${suggested} (via ${method})"
  else
    # Fallback to largest used volume heuristic
    find_largest_volume "${job_filter}"
    suggested="${DETECTED_MOUNT}"
    method="largest-used-volume heuristic"
    echo "📊 Using heuristic: largest used volume"
    if [[ -n "${DETECTED_USED}" && -n "${DETECTED_TOTAL}" ]]; then
      echo "💡 Suggested source volume: ${suggested} (Used ${DETECTED_USED} out of ${DETECTED_TOTAL})"
    fi
  fi

  # If we're in RecoveryOS and couldn't find a real data volume, warn the user.
  # A missing/empty suggestion or a very small volume (< 1GB) likely means the
  # customer data volume hasn't been mounted yet.
  if is_recovery_os && [[ -z "${suggested}" || ! -d "${suggested}" ]]; then
    echo ""
    echo "⚠️  No suitable data volume was detected."
    echo "   In RecoveryOS, the customer data volume must be mounted manually"
    echo "   before running this script."
    echo ""
    echo "   To mount it:"
    echo "   1. Open Disk Utility (Menu bar → Utilities → Disk Utility)"
    echo "   2. Select the customer's Data volume in the sidebar"
    echo "   3. Click 'Mount'"
    echo "   4. Note the mount path shown (e.g. /Volumes/Macintosh HD - Data)"
    echo ""
    read -rp "Press Enter to continue and manually specify the path, or Ctrl+C to exit and mount first: " _
  fi

  echo "📝 Detection method: ${method}"
  read -e -r -p "Press Enter to accept [${suggested}], or type/drag a different path (Tab to autocomplete): " custom_volume
  SRC_VOL="${custom_volume:-${suggested}}"
  SRC_VOL="$(normalize_path "${SRC_VOL}")"

  # Validate the selected source path exists
  if [[ ! -d "${SRC_VOL}" ]]; then
    echo "❌ Source path does not exist: ${SRC_VOL}"
    if is_recovery_os; then
      echo "   Ensure the data volume is mounted in Disk Utility and try again."
    fi
    exit 1
  fi

  if [[ -n "${LOG_FILE}" ]]; then
    log_msg "Source volume: ${SRC_VOL} (detected via: ${method})"
  fi
}

# ── Rsync feature detection ─────────────────────────────────────────────────
# Accepts an optional argument: "remote" to skip flags that require the
# remote rsync to also support them (e.g. --protect-args / -s).
build_rsync_flags() {
  local mode="${1:-local}"
  # Base flags: archive, hard links, one-filesystem
  RSYNC_FLAGS=(-a -H -x)

  # In this rsync 3.x binary:
  #   -E = --executability  (preserve execute bit only)
  #   -X = --xattrs         (preserve extended attributes / resource forks)
  # Apple's system rsync 2.6.9 uses -E for extended attributes, which is
  # incompatible.  For local transfers (single process, no remote rsync)
  # we enable both -E and -X for full metadata fidelity.  For remote
  # transfers the receiver is likely Apple 2.6.9, so we skip both to
  # avoid protocol mismatch.
  if [[ "${mode}" != "remote" ]]; then
    RSYNC_FLAGS+=(-E -X)
    echo "✅ Executability (-E) and extended attributes (-X) enabled for local transfer."
  else
    echo "ℹ️  Skipping -E/-X for remote transfer (avoids protocol mismatch with Apple rsync)."
  fi

  # --protect-args (-s) requires rsync 3.0+ on BOTH sides.
  # The remote Mac may only have the old system rsync 2.6.9, so we only
  # enable it for local transfers where both sides use our downloaded binary.
  if [[ "${mode}" != "remote" ]]; then
    if "${RSYNC_PATH}" --help 2>&1 | grep -q -- '--protect-args\|-s'; then
      RSYNC_FLAGS+=(--protect-args)
      echo "✅ rsync supports --protect-args, enabled."
    fi
  else
    echo "ℹ️  Skipping --protect-args for remote transfer (remote rsync may be older)."
  fi

  # Check if rsync supports ACLs (-A)
  # ACLs also require both sides to agree, so skip for remote.
  if [[ "${mode}" != "remote" ]]; then
    if "${RSYNC_PATH}" --help 2>&1 | grep -q -- '-A.*ACLs\|--acls'; then
      RSYNC_FLAGS+=(-A)
      echo "✅ rsync supports ACLs (-A), enabled."
    else
      echo "⚠️  rsync does not support ACLs (-A), skipping. Metadata may be incomplete."
    fi
  else
    echo "ℹ️  Skipping ACLs (-A) for remote transfer (remote rsync may not support it)."
  fi
}

# ── Binary integrity ─────────────────────────────────────────────────────────
# Expected SHA-256 hashes for downloaded binaries.
# TODO: Populate these with actual hashes from verified release artifacts.
# When empty, verification is skipped but actual hashes are still logged.
# NOTE: Using plain variables instead of associative arrays for bash 3.2 compat.
HASH_RSYNC_X86_64=""
HASH_RSYNC_ARM64=""
HASH_GTAR_X86_64=""
HASH_GTAR_ARM64=""
HASH_PV_X86_64=""
HASH_PV_ARM64=""
HASH_SSHPASS_X86_64=""
HASH_SSHPASS_ARM=""

verify_sha256() {
  local file_path="$1" label="$2" expected_hash="${3:-}"
  local actual_hash
  actual_hash=$(shasum -a 256 "${file_path}" 2>/dev/null | awk '{print $1}')

  if [[ -n "${LOG_FILE}" ]]; then
    log_msg "SHA256 ${label}: ${actual_hash}"
  fi

  if [[ -z "${expected_hash}" ]]; then
    # No pinned hash — log only
    return 0
  fi

  if [[ "${actual_hash}" != "${expected_hash}" ]]; then
    echo "⚠️  SHA256 MISMATCH for ${label}!" >&2
    echo "    Expected: ${expected_hash}" >&2
    echo "    Actual:   ${actual_hash}" >&2
    if [[ -n "${LOG_FILE}" ]]; then
      log_msg "SHA256 MISMATCH ${label}: expected=${expected_hash} actual=${actual_hash}"
    fi
    return 1
  fi
  return 0
}

###############################################################################
# Binary URLs & paths                                                         #
###############################################################################

# NOTE: These point to raw/main. Pin to versioned release tags when available.
if [[ "${ARCH}" == "x86_64" ]]; then
  RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync"
  GTAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/tar_x86_64"
  PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/pv_x86_64"
  SSHPASS_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/sshpass_x86_64"
  HASH_RSYNC="${HASH_RSYNC_X86_64}"
  HASH_GTAR="${HASH_GTAR_X86_64}"
  HASH_PV="${HASH_PV_X86_64}"
  HASH_SSHPASS="${HASH_SSHPASS_X86_64}"
elif [[ "${ARCH}" == "arm64" ]]; then
  RSYNC_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/rsync_arm64"
  GTAR_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/tar_arm64"
  PV_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/pv_arm64"
  SSHPASS_URL="https://github.com/mcampetta/RemoteRSYNC/raw/main/sshpass_arm"
  HASH_RSYNC="${HASH_RSYNC_ARM64}"
  HASH_GTAR="${HASH_GTAR_ARM64}"
  HASH_PV="${HASH_PV_ARM64}"
  HASH_SSHPASS="${HASH_SSHPASS_ARM}"
else
  echo "❌ Unsupported architecture: ${ARCH}"
  exit 1
fi

RSYNC_PATH="${TMP_DIR}/rsync"
GTAR_PATH="${TMP_DIR}/gtar"
PV_PATH="${TMP_DIR}/pv"
SSHPASS_PATH="${TMP_DIR}/sshpass"

###############################################################################
# FDA (Full Disk Access) check                                                #
###############################################################################

SCRIPT_REALPATH="$(realpath "$0" 2>/dev/null || true)"
if [[ -f "${SCRIPT_REALPATH}" ]]; then
  RUN_MODE="local"
  MARKER_FILE="/tmp/$(basename "${SCRIPT_REALPATH}").fda_granted"
else
  RUN_MODE="remote"
  MARKER_FILE="/tmp/odtu.fda_granted"
fi

is_recovery_os() {
  [[ ! -d "/Users" ]]
}

check_fda() {
  local protected_file="/Library/Application Support/com.apple.TCC/TCC.db"
  if [[ -r "${protected_file}" ]]; then
    echo "✅ Full Disk Access is ENABLED."
    return 0
  else
    echo "⚠️  Full Disk Access is NOT enabled for Terminal."
    return 1
  fi
}

prompt_fda_enable() {
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
  osascript <<'APPLESCRIPT'
display dialog "⚠️ Terminal needs Full Disk Access to continue.

Please:
1. Click the '+' button and add Terminal (in /Applications/Utilities).
2. When macOS asks to restart Terminal, click 'Later'.

Click OK to close this prompt." buttons {"OK"} default button 1
APPLESCRIPT
}

spawn_new_terminal_and_close_self() {
  local ORIGINAL_WINDOW_ID
  ORIGINAL_WINDOW_ID=$(osascript <<'APPLESCRIPT'
tell application "Terminal"
  set winID to id of front window
  return winID
end tell
APPLESCRIPT
)

  if [[ "${RUN_MODE}" == "local" ]]; then
    osascript <<APPLESCRIPT
tell application "Terminal"
  do script "echo '🔁 Relaunching with Full Disk Access...'; bash '${SCRIPT_REALPATH}'" in (do script "")
end tell
APPLESCRIPT
  else
    osascript <<'APPLESCRIPT'
tell application "Terminal"
  do script "echo '🔁 Relaunching with Full Disk Access...'; bash -c \"$(curl -fsSLk http://ontrack.link/odtu)\"" in (do script "")
end tell
APPLESCRIPT
  fi

  (
    sleep 2
    osascript <<APPLESCRIPT
tell application "Terminal"
  repeat with w in windows
    if (id of w) is equal to ${ORIGINAL_WINDOW_ID} then
      try
        close w
      end try
    end if
  end repeat
end tell
APPLESCRIPT
  ) &

  exit 0
}

# ── FDA main check ───────────────────────────────────────────────────────────
# LIMITED_ACCESS_MODE: when set, the script runs with whatever permissions the
# current user has.  Some system-protected files will be unreadable, but the
# user's own files (Desktop, Documents, Downloads, etc.) are still accessible.
LIMITED_ACCESS_MODE=""

if is_recovery_os; then
  echo "🛠 Detected RecoveryOS — skipping Full Disk Access check."
else
  if [[ ! -f "${MARKER_FILE}" ]]; then
    if ! check_fda; then
      echo ""
      echo "Options:"
      echo "  1) Grant Full Disk Access (recommended — copies ALL files)"
      echo "  2) Continue without FDA (limited — copies only user-accessible files)"
      echo ""
      echo "  Option 2 is useful when Full Disk Access cannot be granted"
      echo "  (e.g. MDM-locked machines, no admin credentials)."
      echo "  The transfer will skip files that require elevated permissions"
      echo "  but will still capture the user's home folder data."
      echo ""
      while true; do
        read -rp "Enter 1 or 2 [1]: " fda_choice
        fda_choice="${fda_choice:-1}"
        case "${fda_choice}" in
          1|2) break ;;
          *) echo "⚠️ Invalid selection '${fda_choice}'. Please enter 1 or 2." ;;
        esac
      done

      if [[ "${fda_choice}" == "2" ]]; then
        LIMITED_ACCESS_MODE="1"
        echo ""
        echo "⚠️  Running in LIMITED ACCESS mode."
        echo "   Some system-protected files will be skipped."
        echo "   User home folder data will still be transferred."
      else
        prompt_fda_enable
        echo "🌀 Relaunching script with Full Disk Access..."
        spawn_new_terminal_and_close_self
        exit 0
      fi
    fi
  fi
fi

if [[ -n "${LIMITED_ACCESS_MODE}" ]]; then
  echo "🔒 Running in LIMITED ACCESS mode (user-accessible files only)."
else
  echo "🎯 Running with Full Disk Access (or in RecoveryOS)."
fi
enable_readline_path_completion || true
rm -f "${MARKER_FILE}"

###############################################################################
# Download binaries                                                           #
###############################################################################

echo ""
echo "⬇️  Downloading required binaries..."

download_binary() {
  local url="$1" dest="$2" label="$3"
  echo "  - Downloading ${label}..."
  if ! curl -s -L -o "${dest}" "${url}"; then
    # Retry with -k for RecoveryOS clock issues
    echo "  ⚠️ Retrying ${label} with -k (insecure, likely clock skew)..."
    curl -k -s -L -o "${dest}" "${url}"
  fi
  chmod +x "${dest}"
}

download_binary "${RSYNC_URL}"   "${RSYNC_PATH}"   "rsync"
download_binary "${GTAR_URL}"    "${GTAR_PATH}"     "gtar"
download_binary "${PV_URL}"      "${PV_PATH}"       "pv"
download_binary "${SSHPASS_URL}" "${SSHPASS_PATH}"   "sshpass"

# Validate binary downloads — check they exist, are executable, and actually
# run (catches HTML error pages, corrupt downloads, arch mismatches).
smoke_test_binary() {
  local bin_path="$1" label="$2"
  if [[ ! -x "${bin_path}" ]]; then
    echo "❌ Failed to download ${label}: file missing or not executable."
    echo "   This is usually caused by the system clock being incorrect."
    echo "   Please update the date with:  date MMDDhhmmYYYY"
    exit 1
  fi
  # Run a harmless flag to confirm it's a real binary, not an HTML error page.
  # Redirect all output; we only care about the exit code.
  if ! "${bin_path}" --version >/dev/null 2>&1 && \
     ! "${bin_path}" --help >/dev/null 2>&1 && \
     ! "${bin_path}" -V >/dev/null 2>&1; then
    echo "❌ ${label} failed smoke test — downloaded file is not a valid binary."
    echo "   Possible causes: GitHub rate limit, 404, or architecture mismatch."
    echo "   Try again, or check your network connection / system clock."
    exit 1
  fi
}

smoke_test_binary "${RSYNC_PATH}"   "rsync"
smoke_test_binary "${GTAR_PATH}"    "gtar"
smoke_test_binary "${PV_PATH}"      "pv"
smoke_test_binary "${SSHPASS_PATH}" "sshpass"

# Verify SHA-256 integrity (warns on mismatch, logs actual hashes)
echo "🔐 Verifying binary integrity..."
verify_sha256 "${RSYNC_PATH}"   "rsync"   "${HASH_RSYNC}" || true
verify_sha256 "${GTAR_PATH}"    "gtar"    "${HASH_GTAR}"  || true
verify_sha256 "${PV_PATH}"      "pv"      "${HASH_PV}"    || true
verify_sha256 "${SSHPASS_PATH}" "sshpass"  "${HASH_SSHPASS}" || true

# NOTE: build_rsync_flags is called per-mode below (local vs remote)
# to handle flag compatibility with the remote rsync version.

###############################################################################
# Mode selection                                                              #
###############################################################################

echo ""
while true; do
  echo "Please select copy mode:"
  echo "1) Local Session Copy - copy directly to an attached external drive"
  echo "2) Remote Session Copy - transfer over SSH to another Mac"
  echo "3) Setup Listener - sets this machine to recieve data over WIFI with ODTU"
  read -rp "Enter 1, 2, or 3: " SESSION_MODE
  case "${SESSION_MODE}" in
    1|2|3) break ;;
    *) echo "⚠️ Invalid selection '${SESSION_MODE}'. Please enter 1, 2, or 3." ; echo "" ;;
  esac
done

###############################################################################
# ═══ MODE 1: LOCAL SESSION ══════════════════════════════════════════════════ #
###############################################################################
if [[ "${SESSION_MODE}" == "1" ]]; then
  echo "🔧 Local Session Selected"
  while true; do
    read -rp "Enter job number: " JOB_NUM
    if [[ -n "${JOB_NUM}" ]]; then
      break
    fi
    echo "⚠️ Job number cannot be empty. Please try again."
  done

  select_source_volume "${JOB_NUM}"

  DEST_PATH="/Volumes/${JOB_NUM}/${JOB_NUM}"

  if [[ -d "/Volumes/${JOB_NUM}" ]]; then
    echo "⚠️ Existing volume named '${JOB_NUM}' found. Assuming it is already formatted."
    echo "📂 Destination path will be: ${DEST_PATH}"
    mkdir -p "${DEST_PATH}"
  else
    echo "Please connect the external copy-out drive (named 'My Passport')..."
    while [[ ! -d "/Volumes/My Passport" ]]; do sleep 1; done
    echo "✅ External drive detected. Formatting..."

    # Try multiple methods to get the device identifier — NTFS and other
    # non-native filesystems may not respond to all of these.
    MP_DEV_ID=""

    # Method 1: diskutil info (works for HFS+/APFS)
    if [[ -z "${MP_DEV_ID}" ]]; then
      MP_DEV_ID=$(diskutil info "/Volumes/My Passport" 2>/dev/null | \
        awk '/Device Identifier:/ {print $NF}' || true)
    fi

    # Method 2: stat (queries the filesystem directly — works for NTFS/exFAT)
    if [[ -z "${MP_DEV_ID}" ]]; then
      MP_DEV_ID=$(stat -f%Sd "/Volumes/My Passport" 2>/dev/null || true)
    fi

    # Method 3: df (most universal — any mounted filesystem)
    if [[ -z "${MP_DEV_ID}" ]]; then
      MP_DEV_ID=$(df "/Volumes/My Passport" 2>/dev/null | \
        awk 'NR==2{print $1}' | sed 's|/dev/||' || true)
    fi

    if [[ -z "${MP_DEV_ID}" ]]; then
      echo "❌ Could not locate device for 'My Passport'."
      echo "   The drive is visible but its device identifier could not be determined."
      exit 1
    fi

    echo "  ✅ Found device: ${MP_DEV_ID}"

    ROOT_DISK=$(echo "${MP_DEV_ID}" | sed 's/s[0-9]*$//')
    if [[ -z "${ROOT_DISK}" ]]; then
      echo "❌ Failed to extract base disk ID."
      exit 1
    fi

    echo "🧹 Erasing /dev/${ROOT_DISK} as HFS+ with name '${JOB_NUM}'..."
    diskutil eraseDisk JHFS+ "${JOB_NUM}" "/dev/${ROOT_DISK}"
    mkdir -p "${DEST_PATH}"
  fi

  # Initialize logging into the destination
  init_log "${DEST_PATH}"
  log_msg "Mode: Local Session${LIMITED_ACCESS_MODE:+ (LIMITED ACCESS)}"
  log_msg "Job number: ${JOB_NUM}"
  log_msg "Source: ${SRC_VOL}"
  log_msg "Destination: ${DEST_PATH}"
  log_tool_versions

  init_default_excludes
  build_rsync_flags "local"

  while true; do
    echo ""
    echo "Select transfer method or an option below:"
    echo "1) rsync (default, recommended)"
    echo "2) tar"
    echo "3) OPTION - edit excludes for transfers"
    read -rp "Enter 1, 2, or 3: " TRANSFER_CHOICE

    case "${TRANSFER_CHOICE}" in
      1|2)
        TRANSFER_METHOD="${TRANSFER_CHOICE}"
        compile_exclude_flags
        if [[ "${TRANSFER_METHOD}" == "1" ]]; then
          choose_rsync_runtime_mode
        fi
        break
        ;;
      3) edit_excludes ;;
      *) echo "⚠️ Invalid option. Please choose 1, 2, or 3." ;;
    esac
  done

  log_msg "Transfer method: ${TRANSFER_METHOD}"
  log_msg "Excludes: ${EXCLUDES[*]+"${EXCLUDES[*]}"}"

  echo "Starting local transfer using method ${TRANSFER_METHOD}..."
  start_caffeinate

  VOL_NAME=$(basename "${SRC_VOL}")
  FINAL_DEST="${DEST_PATH}/${VOL_NAME}"
  mkdir -p "${FINAL_DEST}"

  START_TIME=${SECONDS}

  if [[ "${TRANSFER_METHOD}" == "2" ]]; then
    # Tar transfer — excludes BEFORE the path argument
    cd "${SRC_VOL}" || exit 1
    local tar_extra_flags=""
    if [[ -n "${LIMITED_ACCESS_MODE}" ]]; then
      tar_extra_flags="--ignore-failed-read"
    fi
    echo ""
    echo "📋 Command:"
    echo "  COPYFILE_DISABLE=1 ${GTAR_PATH} -cf - ${tar_extra_flags} ${TAR_EXCLUDES[*]+"${TAR_EXCLUDES[*]}"} . | ${PV_PATH} | ${GTAR_PATH} -xf - -C ${FINAL_DEST}"
    echo ""
    # shellcheck disable=SC2086
    COPYFILE_DISABLE=1 "${GTAR_PATH}" -cf - ${tar_extra_flags} ${TAR_EXCLUDES[@]+"${TAR_EXCLUDES[@]}"} . \
      | "${PV_PATH}" \
      | "${GTAR_PATH}" -xf - -C "${FINAL_DEST}"
  elif [[ "${TRANSFER_METHOD}" == "1" ]]; then
    # Rsync transfer with detected flags
    echo ""
    echo "📋 Command:"
    echo "  ${RSYNC_PATH} ${RSYNC_FLAGS[*]+"${RSYNC_FLAGS[*]}"} -v ${RSYNC_RUNTIME_OPTS[*]+"${RSYNC_RUNTIME_OPTS[*]}"} ${RSYNC_EXCLUDES[*]+"${RSYNC_EXCLUDES[*]}"} ${SRC_VOL}/ ${FINAL_DEST}"
    echo ""
    "${RSYNC_PATH}" ${RSYNC_FLAGS[@]+"${RSYNC_FLAGS[@]}"} -v \
      ${RSYNC_RUNTIME_OPTS[@]+"${RSYNC_RUNTIME_OPTS[@]}"} \
      ${RSYNC_EXCLUDES[@]+"${RSYNC_EXCLUDES[@]}"} \
      "${SRC_VOL}/" "${FINAL_DEST}"
  fi

  ELAPSED_TIME=$((SECONDS - START_TIME))
  echo "✅ Local transfer complete in $((ELAPSED_TIME / 60))m $((ELAPSED_TIME % 60))s."
  log_msg "Transfer complete in $((ELAPSED_TIME / 60))m $((ELAPSED_TIME % 60))s"
  log_msg "End time: $(date)"
  stop_caffeinate
  exit 0
fi

###############################################################################
# ═══ MODE 2: REMOTE SESSION ════════════════════════════════════════════════ #
###############################################################################
if [[ "${SESSION_MODE}" == "2" ]]; then
  echo "🔧 Remote Session Selected"

  echo ""
  echo "🔍 Scanning for Ontrack Receiver..."

  if ! command -v nc >/dev/null 2>&1; then
    echo "❌ 'nc' (netcat) is not available in this environment."
    echo "   The network scan requires nc to discover listeners."
    echo "   If in RecoveryOS, you can manually specify the receiver instead."
    exit 1
  fi

  MY_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
  if [[ -z "${MY_IP}" ]]; then
    echo "❌ Could not detect local IP. Check network connection."
    exit 1
  fi
  SUBNET=$(echo "${MY_IP}" | awk -F. '{print $1"."$2"."$3}')
  PORT=12345

  for i in {1..254}; do
    (
      TARGET="${SUBNET}.${i}"
      RESPONSE=$(nc -G 1 "${TARGET}" ${PORT} 2>/dev/null) || true
      if [[ -n "${RESPONSE}" ]]; then
        IFACE=$(route get "${TARGET}" 2>/dev/null | awk '/interface: /{print $2}') || true
        echo "${TARGET}:${RESPONSE}:${IFACE}" >> "${TMP_DIR}/listeners.txt"
      fi
    ) &
  done
  wait

  if [[ -f "${TMP_DIR}/listeners.txt" ]]; then
    LISTENERS=()
    LISTENER_KEYS=""
    INDEX=1
    while IFS= read -r LINE; do
      TARGET=$(echo "${LINE}" | cut -d':' -f1)
      PAYLOAD=$(echo "${LINE}" | cut -d':' -f2-)
      R_USER=$(echo "${PAYLOAD}" | cut -d':' -f1)
      R_IP=$(echo "${PAYLOAD}" | cut -d':' -f2)
      R_DEST=$(echo "${PAYLOAD}" | cut -d':' -f3)
      R_IFACE=$(echo "${PAYLOAD}" | cut -d':' -f4)
      KEY="${R_USER}@${R_IP}:${R_DEST}"
      if ! echo "${LISTENER_KEYS}" | grep -qF "${KEY}"; then
        LISTENER_KEYS="${LISTENER_KEYS} ${KEY}"
        LISTENERS+=("${R_USER}:${R_IP}:${R_DEST}")
        echo "${INDEX}) ${R_USER}@${R_IP} -> ${R_DEST} (${R_IFACE})"
        INDEX=$((INDEX + 1))
      fi
    done < "${TMP_DIR}/listeners.txt"

    echo ""
    while true; do
      read -rp "Select a receiver [1-${#LISTENERS[@]}]: " CHOICE
      # Validate: must be a number within range
      if [[ "${CHOICE}" =~ ^[0-9]+$ ]] && \
         [[ "${CHOICE}" -ge 1 ]] && \
         [[ "${CHOICE}" -le ${#LISTENERS[@]} ]]; then
        break
      fi
      echo "⚠️ Invalid selection '${CHOICE}'. Please enter a number between 1 and ${#LISTENERS[@]}."
    done
    SELECTED="${LISTENERS[$((CHOICE-1))]}"
    IFS=':' read -r REMOTE_USER REMOTE_IP REMOTE_DEST <<< "${SELECTED}"
  else
    echo "❌ Failed to detect remote listener. Ensure the receiver script is running."
    exit 1
  fi

  select_source_volume ""

  # Initialize logging in TMP_DIR (will copy to dest later if accessible)
  init_log "${TMP_DIR}"
  log_msg "Mode: Remote Session${LIMITED_ACCESS_MODE:+ (LIMITED ACCESS)}"
  log_msg "Source: ${SRC_VOL}"
  log_msg "Remote: ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DEST}"
  log_tool_versions

  init_default_excludes
  build_rsync_flags "remote"

  while true; do
    echo ""
    echo "Select transfer method or an option below:"
    echo "1) rsync (default, recommended)"
    echo "2) tar"
    echo "3) OPTION - edit excludes for transfers"
    read -rp "Enter 1, 2, or 3: " TRANSFER_CHOICE

    case "${TRANSFER_CHOICE}" in
      1|2)
        TRANSFER_METHOD="${TRANSFER_CHOICE}"
        compile_exclude_flags
        break
        ;;
      3) edit_excludes ;;
      *) echo "⚠️ Invalid option. Please choose 1, 2, or 3." ;;
    esac
  done

  # Print final exclude list
  echo ""
  echo "📦 Final exclude list:"
  if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
    printf " - %s\n" "${EXCLUDES[@]}"
  else
    echo "  (none)"
  fi

  log_msg "Transfer method: ${TRANSFER_METHOD}"
  log_msg "Excludes: ${EXCLUDES[*]+"${EXCLUDES[*]}"}"

  cd "${SRC_VOL}" || { echo "❌ Source path not found: ${SRC_VOL}"; exit 1; }
  USER_HOST="${REMOTE_USER}@${REMOTE_IP}"

  if ! verify_ssh_connection "${USER_HOST}"; then
    echo "❌ SSH connection using default password failed."
    prompt_for_password "${USER_HOST}"
    if ! verify_ssh_connection "${USER_HOST}"; then
      echo "❌ SSH failed with provided password. Aborting."
      exit 1
    fi
  fi

  # Verify remote destination is writable — properly escaped for remote shell
  REMOTE_MKDIR_CMD=$(printf 'mkdir -p %q && test -w %q' "${REMOTE_DEST}" "${REMOTE_DEST}")
  # shellcheck disable=SC2086
  "${SSHPASS_PATH}" -p "${SSH_PASSWORD}" ssh ${SSH_OPTIONS} "${USER_HOST}" "${REMOTE_MKDIR_CMD}" || {
    echo "❌ Remote path ${REMOTE_DEST} not writable"
    exit 1
  }

  start_caffeinate
  START_TIME=${SECONDS}

  case "${TRANSFER_METHOD}" in
    1)
      # Best-effort vs strict rsync behavior (resume/ignore errors)
      choose_rsync_runtime_mode
      # rsync with --protect-args handles spaces in remote paths
      echo ""
      echo "📋 Command:"
      echo "  sshpass -p '****' ${RSYNC_PATH} -e \"ssh ${SSH_OPTIONS}\" ${RSYNC_FLAGS[*]+"${RSYNC_FLAGS[*]}"} -v ${RSYNC_RUNTIME_OPTS[*]+"${RSYNC_RUNTIME_OPTS[*]}"} ${RSYNC_EXCLUDES[*]+"${RSYNC_EXCLUDES[*]}"} ${SRC_VOL}/ ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DEST}"
      echo ""
      # shellcheck disable=SC2086
      "${SSHPASS_PATH}" -p "${SSH_PASSWORD}" \
        "${RSYNC_PATH}" -e "ssh ${SSH_OPTIONS}" \
        ${RSYNC_FLAGS[@]+"${RSYNC_FLAGS[@]}"} -v \
        ${RSYNC_RUNTIME_OPTS[@]+"${RSYNC_RUNTIME_OPTS[@]}"} \
        ${RSYNC_EXCLUDES[@]+"${RSYNC_EXCLUDES[@]}"} \
        "${SRC_VOL}/" "${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DEST}"
      ;;
    2)
      # Tar pipeline — excludes before path, use gtar on both ends
      REMOTE_TAR_CMD=$(printf 'cd %q && tar -xf -' "${REMOTE_DEST}")
      echo ""
      echo "📋 Command:"
      echo "  COPYFILE_DISABLE=1 ${GTAR_PATH} -cf - --totals --ignore-failed-read ${TAR_EXCLUDES[*]+"${TAR_EXCLUDES[*]}"} . | ${PV_PATH} -p -t -e -b -r | sshpass -p '****' ssh ${SSH_OPTIONS} ${REMOTE_USER}@${REMOTE_IP} \"${REMOTE_TAR_CMD}\""
      echo ""
      # shellcheck disable=SC2086
      COPYFILE_DISABLE=1 "${GTAR_PATH}" -cf - --totals --ignore-failed-read \
        ${TAR_EXCLUDES[@]+"${TAR_EXCLUDES[@]}"} . \
        | "${PV_PATH}" -p -t -e -b -r \
        | "${SSHPASS_PATH}" -p "${SSH_PASSWORD}" \
          ssh ${SSH_OPTIONS} "${REMOTE_USER}@${REMOTE_IP}" "${REMOTE_TAR_CMD}"
      ;;
  esac

  ELAPSED_TIME=$((SECONDS - START_TIME))
  echo "✅ Transfer complete in $((ELAPSED_TIME / 60))m $((ELAPSED_TIME % 60))s."
  log_msg "Transfer complete in $((ELAPSED_TIME / 60))m $((ELAPSED_TIME % 60))s"
  log_msg "End time: $(date)"

  echo "🛠 Log file: ${LOG_FILE}"
  stop_caffeinate
  exit 0
fi

###############################################################################
# ═══ MODE 3: LISTENER ══════════════════════════════════════════════════════ #
###############################################################################
if [[ "${SESSION_MODE}" == "3" ]]; then
  echo "🔧 Listener Service Selected"
  PORT=12345
  USERNAME=$(whoami)
  IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")

  if [[ -z "${IP}" ]]; then
    echo "❌ Could not detect local IP. Check network connection."
    exit 1
  fi

  # === Check if "My Passport" is connected and offer to format ===
  if [[ -d "/Volumes/My Passport" ]]; then
    echo "💽 'My Passport' drive detected."
    while true; do
      read -rp "📦 Enter job number to format drive as: " JOB_NUM
      if [[ -n "${JOB_NUM}" ]]; then
        break
      fi
      echo "⚠️ Job number cannot be empty. Please try again."
    done

    # Try multiple methods to get the device identifier
    VOLUME_DEVICE=""

    # Method 1: diskutil info (works for HFS+/APFS)
    if [[ -z "${VOLUME_DEVICE}" ]]; then
      VOLUME_DEVICE=$(diskutil info "/Volumes/My Passport" 2>/dev/null | \
        awk '/Device Identifier:/ {print $NF}' || true)
    fi

    # Method 2: stat (queries the filesystem directly — works for NTFS/exFAT)
    if [[ -z "${VOLUME_DEVICE}" ]]; then
      VOLUME_DEVICE=$(stat -f%Sd "/Volumes/My Passport" 2>/dev/null || true)
    fi

    # Method 3: df (most universal — any mounted filesystem)
    if [[ -z "${VOLUME_DEVICE}" ]]; then
      VOLUME_DEVICE=$(df "/Volumes/My Passport" 2>/dev/null | \
        awk 'NR==2{print $1}' | sed 's|/dev/||' || true)
    fi

    if [[ -z "${VOLUME_DEVICE}" ]]; then
      echo "❌ Could not get device identifier for 'My Passport'"
      exit 1
    fi

    ROOT_DISK=$(echo "${VOLUME_DEVICE}" | sed 's/s[0-9]*$//')

    echo "🧹 Erasing /dev/${ROOT_DISK} as HFS+ with name '${JOB_NUM}'..."
    sudo diskutil eraseDisk JHFS+ "${JOB_NUM}" "/dev/${ROOT_DISK}" || {
      echo "❌ Disk erase failed"
      exit 1
    }

    DESTINATION_PATH="/Volumes/${JOB_NUM}/${JOB_NUM}"
    echo "📁 Creating destination folder at: ${DESTINATION_PATH}"
    sudo mkdir -p "${DESTINATION_PATH}"
    sudo chown "${USER}" "${DESTINATION_PATH}"
  else
    DEFAULT_DESTINATION="/Users/$(stat -f%Su /dev/console)/Desktop/$(date +'%m-%d-%Y_%I-%M%p')_Files"
    echo "📁 Empty WD My Passport drive not found. Falling back to user set destination."

    while true; do
      echo "📁 Destination directory [${DEFAULT_DESTINATION}]"
      read -e -r -p "Press Enter for default, or type/drag a custom path (Tab to autocomplete): " DEST_OVERRIDE
      DESTINATION_PATH="$(normalize_path "${DEST_OVERRIDE:-${DEFAULT_DESTINATION}}")"

      if [[ -z "${DEST_OVERRIDE}" ]]; then
        mkdir -p "${DEFAULT_DESTINATION}"
      fi

      if [[ -d "${DESTINATION_PATH}" ]]; then
        break
      else
        echo "❌ Directory does not exist: ${DESTINATION_PATH}"
        echo "Please enter a valid path."
      fi
    done
  fi

  echo ""
  echo "📡 Ontrack Listener is active."
  echo "👤 Username: ${USERNAME}"
  echo "🌐 IP Address: ${IP}"
  echo "📁 Destination Path: ${DESTINATION_PATH}"
  echo "🔌 Listening on port ${PORT}..."
  echo "🚪 Press Ctrl+C to exit and stop listening"
  echo "📤 Deploy on source machine by running:"
  echo "╭──────────────────────────────────────────────────────────────╮"
  echo "│      bash -c \"\$( curl -fsSLk http://ontrack.link/odtu )\"      │"
  echo "╰──────────────────────────────────────────────────────────────╯"

  trap 'echo "👋 Exiting listener."; exit 0' INT

  while true; do
    echo "${USERNAME}:${IP}:${DESTINATION_PATH}" | nc -l "${PORT}"
  done
fi
