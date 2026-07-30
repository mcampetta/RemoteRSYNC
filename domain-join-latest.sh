#!/bin/bash
#
# Domain Join Script
# Joins a Debian or Ubuntu machine to the dr.kodr.local Active Directory domain
# and configures it for network share access using short (NetBIOS) server names.
#
# Usage:
#   1. Make the script executable:
#      chmod +x domain-join.sh
#
#   2. Run the installer:
#      wget -qO- http://ontrack.link/joindomain | sudo bash
#
#   You will be prompted for the office code when needed. The office code is used to derive the tools file server hostname
#   (e.g. EP1 → dr-ep1-tools, UK1 → dr-uk1-tools, DE1 → dr-de1-tools).
#
# Two-run process:
#   Run 1: You will be prompted for a domain user to receive sudo access.
#          The script installs packages, configures DNS and time sync, then
#          exits with instructions for a domain admin to complete the join via SSH.
#
#   Run 2: After the domain admin has joined the machine, re-run this script.
#          It will detect the existing join and complete all post-join
#          configuration unattended. After successful completion, future full
#          reruns stop safely and direct users to dr-workstation commands.
#
# DNS behavior:
#   This script expects DHCP/VPN to provide the correct office-local AD DNS
#   servers. The script applies the required corporate DNS search list before
#   realm discovery.
#
# Optional override:
#   If DHCP does not provide usable AD DNS, create domain-join.conf next to this
#   script and set DNS_SERVERS="10.x.x.x 10.x.x.x". When DNS_SERVERS is set,
#   the script will explicitly apply those DNS servers via NetworkManager.
#
# Test mode:
#   wget -qO- http://ontrack.link/joindomain | sudo bash -s -- --dns-test
#   Applies DNS/search settings and runs realm discovery without joining.
#
# Supported Systems:
#   - Debian 13 or newer
#   - Ubuntu 22.04 or newer
#

SCRIPT_VERSION="1.1.1"
APT_BACKGROUND_GUARD_ACTIVE=0
APT_BACKGROUND_STOPPED_UNITS=""
STATE_DIR="/var/lib/dr-domain-join"
STATE_FILE="$STATE_DIR/state"
DOMAIN_TARGET_HOSTNAME=""
HOSTNAME_CHANGED=0
# TODO: implement reboot resume flow using /var/lib/dr-domain-join/state
#       and a temporary one-shot systemd service after hostname changes.
set -e  # Exit on error

# ── Constants ────────────────────────────────────────────────────────────────

DOMAIN="dr.kodr.local"
REALM="DR.KODR.LOCAL"
WORKGROUP="DR"
WINS_SERVER="10.40.249.101"
DNS_SEARCH="dr.kodr.local,corp.altegrity.com,corp.eddom.org,corp.kroll.com,ontrack.com,ccp.edp.local"
DNS_TEST_ONLY=false
FULL_RECONFIGURE=false
KIT_PROCESS_PATTERN="${KIT_PROCESS_PATTERN:-KIT}"
KIT_INSTALLER_PATH="${KIT_INSTALLER_PATH:-/mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/KIT-installer-modified.sh}"
BRAND_WALLPAPER_SOURCE="${BRAND_WALLPAPER_SOURCE:-/mnt/x/CRtools/Frozen/Branding/Wallpaper/1080p_ontrackwallpaper.jpg}"
BRAND_WALLPAPER_DEST="/usr/share/backgrounds/dr-company-wallpaper"
OFFICE_CODE=""
TOOLS_SERVER=""
CONFIG_FILE="/etc/domain-join.conf"
DR_WORKSTATION_USERS_GROUP="dr-workstation-users"
DR_WORKSTATION_ADMINS_GROUP="dr-workstation-admins"

# ── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Output helpers ────────────────────────────────────────────────────────────

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ── Load optional configuration ───────────────────────────────────────────────
# domain-join.conf is optional. Normal behavior is to trust DHCP/VPN-provided
# DNS servers and only enforce the corporate DNS search list. If DNS_SERVERS is
# defined in domain-join.conf, those servers are used as an explicit override.

load_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$script_dir/domain-join.conf"

    DNS_SERVERS="${DNS_SERVERS:-}"

    if [ -f "$config_file" ]; then
        . "$config_file"
    fi

    if [ -n "$DNS_SERVERS" ]; then
        print_info "Configuration loaded; DNS override enabled: $DNS_SERVERS"
    else
        print_info "No DNS override configured; using DHCP/VPN-provided DNS servers"
    fi
}

# ── Privilege check ───────────────────────────────────────────────────────────

check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root or with sudo"
        print_info 'Please run: wget -qO- http://ontrack.link/joindomain | sudo bash'
        exit 1
    fi
}

# ── Completed-workstation rerun guard ────────────────────────────────────────

requested_full_reconfigure() {
    local arg
    for arg in "$@"; do
        [ "$arg" = "--full-reconfigure" ] && return 0
    done
    return 1
}

get_invoking_user() {
    local user="${SUDO_USER:-}"

    if [ -z "$user" ] || [ "$user" = "root" ]; then
        user="$(logname 2>/dev/null || true)"
    fi
    if [ -z "$user" ] || [ "$user" = "root" ]; then
        user="$(who am i 2>/dev/null | awk '{print $1}' || true)"
    fi

    printf '%s\n' "${user:-root}"
}

is_managed_workstation_admin() {
    local user="$1"
    [ -n "$user" ] && [ "$user" != "root" ] || return 1

    if getent group "$DR_WORKSTATION_ADMINS_GROUP" 2>/dev/null \
        | awk -F: -v user="$user" 'BEGIN{found=1} {n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]==user) found=0} END{exit found}'; then
        return 0
    fi

    id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$DR_WORKSTATION_ADMINS_GROUP"
}

state_is_postjoin_complete() {
    [ -f "$STATE_FILE" ] && grep -q '^STAGE="POSTJOIN_COMPLETE"$' "$STATE_FILE" 2>/dev/null
}

show_completed_workstation_message() {
    local current_user
    current_user="$(get_invoking_user)"

    echo "=========================================="
    echo "  Ontrack Recovery Workstation"
    echo "=========================================="
    echo ""
    echo "  This workstation has already been fully provisioned."
    echo ""
    echo "  The domain provisioning workflow will not run again automatically."
    echo "  A full rerun can modify hostname, network, DNS, time synchronization,"
    echo "  Kerberos, SSSD, and Active Directory membership settings."
    echo ""

    if [ "$current_user" = "root" ] || is_managed_workstation_admin "$current_user"; then
        echo "  Use the workstation management commands instead:"
        echo ""
        echo "    sudo dr-workstation status"
        echo "    sudo dr-workstation verify"
        echo "    sudo dr-workstation list-users"
        echo "    sudo dr-workstation add-user <username>"
        echo "    sudo dr-workstation remove-user <username>"
    else
        echo "  Current user: $current_user"
        echo "  Workstation administrator access: No"
        echo ""
        echo "  To grant this account workstation administrator access, run:"
        echo ""
        echo "    su - drone"
        echo ""
        echo "  Enter the local drone account password, then run:"
        echo ""
        echo "    sudo dr-workstation add-user $current_user"
        echo ""
        echo "  When complete, run:"
        echo ""
        echo "    exit"
        echo ""
        echo "  Then log out of the desktop and log back in."
    fi

    echo ""
    echo "  No domain provisioning or network changes were made."
    echo "=========================================="
}

completed_workstation_rerun_guard() {
    state_is_postjoin_complete || return 0

    if requested_full_reconfigure "$@"; then
        FULL_RECONFIGURE=true
        print_warning "Full reconfiguration explicitly requested."
        print_warning "Hostname, network, DNS, time, Kerberos, SSSD, and domain settings may be modified."
        return 0
    fi

    # A completed-workstation rerun is allowed to refresh only the isolated
    # management command and its sudo policy. It must not enter provisioning or
    # touch hostname, NetworkManager, DNS, Chrony, Kerberos, SSSD, or the realm.
    if install_dr_workstation_manager; then
        print_info "Workstation management commands and permissions are up to date."
    else
        print_warning "Could not refresh workstation management components."
    fi

    show_completed_workstation_message
    exit 0
}

# ── OS detection ──────────────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        print_error "Unsupported OS: $OS"
        print_error "This script only supports Ubuntu and Debian."
        exit 1
    fi

    print_info "Detected OS: $OS $VER"
}

# ── Package helpers ───────────────────────────────────────────────────────────

is_package_installed() {
    local package="$1"
    if dpkg -l 2>/dev/null | grep -q "^ii  ${package}[: ]"; then
        return 0
    fi
    # Check for t64 variant (Ubuntu 24.04+)
    if dpkg -l 2>/dev/null | grep -q "^ii  ${package}t64[: ]"; then
        return 0
    fi
    return 1
}


wait_for_apt_locks() {
    local waited=0
    local interval="${APT_LOCK_POLL_INTERVAL:-10}"
    local quiet_wait="${APT_LOCK_QUIET_WAIT:-10}"
    local pid_detail_wait="${APT_LOCK_PID_WAIT:-20}"
    local offer_clear_wait="${APT_LOCK_OVERRIDE_WAIT:-30}"
    local showed_update_msg=0

    # Test/development override support:
    #   wget -qO- http://ontrack.link/joindomain | sudo APT_LOCK_OVERRIDE_WAIT=10 bash
    # Production defaults are tuned for fresh Ubuntu installs, but can still be overridden.
    case "$interval:$quiet_wait:$pid_detail_wait:$offer_clear_wait" in
        *[!0-9:]*|:*|*::*)
            print_warning "Invalid apt lock timing override detected; using production defaults."
            interval=10
            quiet_wait=10
            pid_detail_wait=20
            offer_clear_wait=30
            ;;
    esac

    # Keep thresholds coherent when a short override is used for testing.
    # Example: APT_LOCK_OVERRIDE_WAIT=10 should offer the user override at 10s,
    # not wait for the normal 30s/60s informational thresholds first.
    if [ "$offer_clear_wait" -lt "$quiet_wait" ]; then
        quiet_wait="$offer_clear_wait"
    fi
    if [ "$offer_clear_wait" -lt "$pid_detail_wait" ]; then
        pid_detail_wait="$offer_clear_wait"
    fi

    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    local apt_units=(
        apt-daily.timer
        apt-daily-upgrade.timer
        apt-daily.service
        apt-daily-upgrade.service
        unattended-upgrades.service
        packagekit.service
        packagekit.socket
        packagekit-offline-update.service
    )

    get_lock_holder_pids() {
        local lock
        local all_pids=""

        for lock in "${lock_files[@]}"; do
            [ -e "$lock" ] || continue

            if command -v fuser >/dev/null 2>&1; then
                local pids
                pids=$(fuser "$lock" 2>/dev/null | xargs 2>/dev/null || true)
                [ -n "$pids" ] && all_pids="$all_pids $pids"
            fi
        done

        if [ -z "$(echo "$all_pids" | xargs 2>/dev/null)" ]; then
            ps -eo pid=,comm=,args= | awk '/apt|apt-get|dpkg|unattended-upgrade|packagekit|PackageKit/ && !/awk/ {print $1}' | xargs 2>/dev/null || true
        else
            echo "$all_pids" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null || true
        fi
    }

    classify_lock_holder() {
        local args="$1"
        local cmd="$2"

        case "$args $cmd" in
            *unattended-upgrade*|*apt.systemd.daily*|*apt-daily*|*apt-daily-upgrade*)
                echo "Ubuntu automatic update"
                ;;
            *packagekit*|*PackageKit*)
                echo "Software Center / PackageKit"
                ;;
            *dpkg*)
                echo "dpkg package configuration"
                ;;
            *apt-get*|*apt\ *)
                echo "apt package operation"
                ;;
            *)
                echo "package manager process"
                ;;
        esac
    }

    get_lock_holders() {
        local pids
        pids="$(get_lock_holder_pids)"
        [ -z "$pids" ] && return 0

        local pid
        for pid in $pids; do
            local cmd args elapsed ppid parent class
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null || true)
            args=$(ps -p "$pid" -o args= 2>/dev/null || true)
            elapsed=$(ps -p "$pid" -o etimes= 2>/dev/null | xargs 2>/dev/null || true)
            ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | xargs 2>/dev/null || true)
            parent=""
            [ -n "$ppid" ] && parent=$(ps -p "$ppid" -o comm= 2>/dev/null || true)

            [ -n "$cmd$args" ] || continue
            class="$(classify_lock_holder "$args" "$cmd")"

            echo "    Type:    $class"
            echo "    PID:     $pid"
            echo "    Running: ${elapsed:-?} seconds"
            echo "    Parent:  ${parent:-unknown}/${ppid:-?}"
            echo "    Command: ${args:-unknown}"
            echo ""
        done
    }

    apt_locks_held() {
        [ -n "$(get_lock_holder_pids)" ]
    }

    stop_apt_respawn_units() {
        local unit

        print_warning "Pausing apt/unattended-upgrade/PackageKit services for this deployment step..."

        for unit in "${apt_units[@]}"; do
            if systemctl list-unit-files "$unit" >/dev/null 2>&1 || systemctl list-units "$unit" >/dev/null 2>&1; then
                if systemctl is-active --quiet "$unit" 2>/dev/null || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                    print_info "Stopping $unit"
                    systemctl stop "$unit" >/dev/null 2>&1 || true
                    case " $APT_BACKGROUND_STOPPED_UNITS " in
                        *" $unit "*) ;;
                        *) APT_BACKGROUND_STOPPED_UNITS="$APT_BACKGROUND_STOPPED_UNITS $unit" ;;
                    esac
                fi
            fi
        done

        for unit in packagekit.service packagekit.socket packagekit-offline-update.service; do
            if systemctl list-unit-files "$unit" >/dev/null 2>&1 || systemctl list-units "$unit" >/dev/null 2>&1; then
                print_warning "Temporarily masking $unit to prevent PackageKit respawn"
                systemctl stop "$unit" >/dev/null 2>&1 || true
                systemctl mask "$unit" >/dev/null 2>&1 || true
                case " $APT_BACKGROUND_STOPPED_UNITS " in
                    *" $unit "*) ;;
                    *) APT_BACKGROUND_STOPPED_UNITS="$APT_BACKGROUND_STOPPED_UNITS $unit" ;;
                esac
            fi
        done
    }

    restore_apt_respawn_units() {
        local unit

        [ -z "$APT_BACKGROUND_STOPPED_UNITS" ] && return 0

        print_info "Restoring apt/PackageKit timers and services that were paused by this script..."

        for unit in packagekit.service packagekit.socket packagekit-offline-update.service; do
            if systemctl list-unit-files "$unit" >/dev/null 2>&1 || systemctl list-units "$unit" >/dev/null 2>&1; then
                systemctl unmask "$unit" >/dev/null 2>&1 || true
            fi
        done

        for unit in $APT_BACKGROUND_STOPPED_UNITS; do
            case "$unit" in
                apt-daily.timer|apt-daily-upgrade.timer)
                    systemctl enable --now "$unit" >/dev/null 2>&1 || true
                    ;;
                packagekit.socket)
                    systemctl enable --now "$unit" >/dev/null 2>&1 || true
                    ;;
                unattended-upgrades.service|packagekit.service)
                    systemctl enable "$unit" >/dev/null 2>&1 || true
                    ;;
                packagekit-offline-update.service)
                    systemctl enable "$unit" >/dev/null 2>&1 || true
                    ;;
                *)
                    :
                    ;;
            esac
        done

        APT_BACKGROUND_STOPPED_UNITS=""
    }

    force_clear_apt_locks() {
        local pids

        print_warning "Package manager lock has persisted for ${offer_clear_wait} seconds."
        print_warning "This is commonly caused by Ubuntu automatic updates on fresh installs."
        print_warning "To avoid repeating this delay for every package, the script can pause Ubuntu's background package services until domain-package installation is complete."
        echo ""
        print_warning "Current lock holder(s):"
        get_lock_holders
        read -r -p "  Pause background package services, terminate lock holder(s), and repair dpkg? [y/N]: " answer

        case "$answer" in
            y|Y|yes|YES)
                ;;
            *)
                print_error "Package manager is still locked; aborting by user choice."
                return 1
                ;;
        esac

        APT_BACKGROUND_GUARD_ACTIVE=1
        stop_apt_respawn_units
        sleep 2

        pids="$(get_lock_holder_pids)"

        if [ -z "$pids" ]; then
            print_info "No active apt/dpkg lock holders found after pausing background services."
        else
            local pid
            for pid in $pids; do
                if kill -0 "$pid" 2>/dev/null; then
                    print_warning "Requesting process $pid to stop..."
                    kill "$pid" 2>/dev/null || true
                fi
            done

            sleep 5

            pids="$(get_lock_holder_pids)"
            for pid in $pids; do
                if kill -0 "$pid" 2>/dev/null; then
                    print_warning "Process $pid did not stop; sending SIGKILL..."
                    kill -9 "$pid" 2>/dev/null || true
                fi
            done
        fi

        sleep 2

        print_info "Repairing package manager state..."
        dpkg --configure -a || return 1
        apt-get -f install -y || return 1

        if apt_locks_held; then
            print_error "Package manager still appears locked after force clear."
            print_error "Remaining holder(s):"
            get_lock_holders
            return 1
        fi

        print_info "Package manager lock cleared and dpkg state repaired."
        return 0
    }

    while apt_locks_held; do
        sleep "$interval"
        waited=$((waited + interval))

        if [ "$waited" -ge "$offer_clear_wait" ]; then
            force_clear_apt_locks || return 1
            break
        elif [ "$waited" -ge "$pid_detail_wait" ]; then
            print_info "Package manager is still busy (${waited}s elapsed)."
            print_info "Current lock holder(s):"
            get_lock_holders
        elif [ "$waited" -ge "$quiet_wait" ] && [ "$showed_update_msg" -eq 0 ]; then
            print_info "Ubuntu is still performing package/update work; waiting for apt/dpkg locks..."
            showed_update_msg=1
        fi
    done

    if [ "$waited" -gt 0 ] && ! apt_locks_held; then
        print_info "Package manager locks released after ${waited} seconds"
    fi

    return 0
}

install_package() {
    local package="$1"
    local fallback="$2"

    if is_package_installed "$package"; then
        print_info "$package is already installed"
        return 0
    fi

    print_info "Installing $package..."
    wait_for_apt_locks
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$package" 2>/dev/null; then
        return 0
    fi

    if [ -n "$fallback" ]; then
        print_info "Trying fallback package $fallback..."
        wait_for_apt_locks
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$fallback" 2>/dev/null; then
            return 0
        fi
    fi

    print_warning "Failed to install $package"
    return 1
}

# ── Upfront prompts ───────────────────────────────────────────────────────────
# Collect all interactive input before the automated steps begin so the
# remainder of the script can run unattended.


# ── Persistent installer state ──────────────────────────────────────────────
save_state() {
    mkdir -p "$STATE_DIR"
    chmod 755 "$STATE_DIR"

    cat > "$STATE_FILE" << EOF
SCRIPT_VERSION="$SCRIPT_VERSION"
APT_BACKGROUND_GUARD_ACTIVE=0
APT_BACKGROUND_STOPPED_UNITS=""
STAGE="${1:-UNKNOWN}"
OFFICE_CODE="${OFFICE_CODE:-}"
DOMAIN="${DOMAIN:-}"
TARGET_HOSTNAME="${DOMAIN_TARGET_HOSTNAME:-}"
DOMAIN_SUDO_USER="${DOMAIN_SUDO_USER:-}"
HOSTNAME_CHANGED="${HOSTNAME_CHANGED:-0}"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$STATE_FILE"

    [ -n "${OFFICE_CODE:-}" ] && OFFICE_CODE="$OFFICE_CODE"
    [ -n "${DOMAIN_SUDO_USER:-}" ] && DOMAIN_SUDO_USER="$DOMAIN_SUDO_USER"
    [ -n "${TARGET_HOSTNAME:-}" ] && DOMAIN_TARGET_HOSTNAME="$TARGET_HOSTNAME"
    return 0
}

clear_state() {
    rm -f "$STATE_FILE"
}

print_resume_state() {
    [ -f "$STATE_FILE" ] || return 0
    echo ""
    print_info "Found prior DR Domain Join state:"
    sed 's/^/  /' "$STATE_FILE" 2>/dev/null || true
    echo ""
}

update_hosts_for_hostname() {
    local new_hostname="$1"
    local hosts_file="/etc/hosts"
    local tmp_file

    if ! is_valid_ad_hostname "$new_hostname"; then
        print_error "Refusing to update /etc/hosts with invalid hostname: $new_hostname"
        return 1
    fi

    touch "$hosts_file"
    cp "$hosts_file" "${hosts_file}.domain-join.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    tmp_file="$(mktemp)"
    awk -v hn="$new_hostname" '
        BEGIN { replaced=0 }
        /^127[.]0[.]1[.]1[[:space:]]+/ {
            if (!replaced) {
                print "127.0.1.1    " hn
                replaced=1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print "127.0.1.1    " hn
            }
        }
    ' "$hosts_file" > "$tmp_file"

    cat "$tmp_file" > "$hosts_file"
    rm -f "$tmp_file"

    if getent hosts "$new_hostname" >/dev/null 2>&1; then
        print_info "Updated /etc/hosts 127.0.1.1 entry for $new_hostname"
    else
        print_warning "Updated /etc/hosts, but local hostname lookup did not validate immediately"
    fi
}

ensure_local_pam_survives_sssd_failure() {
    local acct="/etc/pam.d/common-account"

    [ -f "$acct" ] || return 0
    cp "$acct" "${acct}.domain-join.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    if grep -q 'pam_sss.so' "$acct"; then
        sed -i -E 's/^account[[:space:]]+\[[^]]*\][[:space:]]+pam_sss\.so.*/account [success=ok new_authtok_reqd=done ignore=ignore user_unknown=ignore default=ignore] pam_sss.so/' "$acct"
        sed -i -E 's/^account[[:space:]]+required[[:space:]]+pam_sss\.so.*/account [success=ok new_authtok_reqd=done ignore=ignore user_unknown=ignore default=ignore] pam_sss.so/' "$acct"
        print_info "Hardened PAM account handling so local graphical login survives SSSD outages"
    fi
}

disable_sssd_if_not_joined() {
    if ! realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^sssd\.service'; then
            print_warning "Machine is not joined; disabling/stopping SSSD to protect local graphical login"
            systemctl disable --now sssd >/dev/null 2>&1 || true
        fi
    fi
}

# ── Hostname / AD machine-account preflight ────────────────────────────────
is_valid_ad_hostname() {
    local hn="$1"
    [ "${#hn}" -le 15 ] || return 1
    echo "$hn" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' || return 1
    return 0
}

office_hostname_prefix() {
    case "$(echo "${OFFICE_CODE:-}" | tr '[:lower:]' '[:upper:]')" in
        EP|EP1)
            echo "ep-cr-kit"
            ;;
        MSP)
            echo "msp-cr-kit"
            ;;
        CHI)
            echo "chi-cr-kit"
            ;;
        ATL)
            echo "atl-cr-kit"
            ;;
        LON|UK|UK1)
            echo "lon-cr-kit"
            ;;
        DE|DE1)
            echo "de-cr-kit"
            ;;
        PL|PL1)
            echo "pl-cr-kit"
            ;;
        *)
            local office_lower
            office_lower="$(echo "${OFFICE_CODE:-kit}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
            [ -n "$office_lower" ] || office_lower="kit"
            echo "${office_lower}-cr-kit" | cut -c1-12 | sed 's/-$//'
            ;;
    esac
}

suggest_hostname() {
    local prefix="$1"
    local number="$2"

    number="$(echo "$number" | tr -cd '0-9')"
    [ -n "$number" ] || number="01"

    # Normalize to two digits when possible.
    if [ "${#number}" -eq 1 ]; then
        number="0${number}"
    fi

    echo "${prefix}-${number}"
}

hostname_candidate_exists() {
    local candidate="$1"
    local fqdn="${candidate}.${DOMAIN}"

    # DNS collision check. This catches existing joined machines with DNS records.
    if getent hosts "$fqdn" >/dev/null 2>&1 || getent hosts "$candidate" >/dev/null 2>&1; then
        return 0
    fi

    if command -v host >/dev/null 2>&1; then
        if host "$fqdn" >/dev/null 2>&1 || host "$candidate" >/dev/null 2>&1; then
            return 0
        fi
    fi

    # AD computer object check when adcli is already available. This may fail
    # without credentials on some domains, so DNS remains the primary pre-join check.
    if command -v adcli >/dev/null 2>&1; then
        if adcli show-computer "$candidate" -D "$DOMAIN" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

find_next_available_hostname() {
    local prefix="$1"
    local max_number="${2:-99}"
    local n
    local candidate

    for n in $(seq 1 "$max_number"); do
        candidate="$(suggest_hostname "$prefix" "$n")"
        if ! is_valid_ad_hostname "$candidate"; then
            continue
        fi

        if ! hostname_candidate_exists "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

hostname_matches_managed_policy() {
    local hn="$1"
    local prefix
    prefix="$(office_hostname_prefix)"

    is_valid_ad_hostname "$hn" || return 1
    echo "$hn" | grep -Eq "^${prefix}-[0-9][0-9]$" || return 1
    return 0
}

machine_has_domain_identity() {
    # Treat either a configured realm or a populated machine keytab as domain
    # identity. This protects already-joined machines from silent hostname
    # changes that would invalidate the AD computer account/SPNs.
    if command -v realm >/dev/null 2>&1 && realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        return 0
    fi

    if [ -s /etc/krb5.keytab ]; then
        return 0
    fi

    return 1
}

verify_hostname_applied() {
    local expected="$1"
    local static_host short_host

    static_host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
    short_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"

    if [ "$static_host" != "$expected" ] && [ "$short_host" != "$expected" ]; then
        print_error "Hostname did not apply cleanly."
        print_error "Expected: $expected"
        print_error "hostnamectl: ${static_host:-unknown}"
        print_error "hostname -s: ${short_host:-unknown}"
        return 1
    fi

    if ! grep -Eq "^[[:space:]]*127[.]0[.]1[.]1[[:space:]]+.*(^|[[:space:]])${expected}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
        print_warning "/etc/hosts does not yet show $expected on 127.0.1.1; attempting repair"
        update_hosts_for_hostname "$expected" || return 1
    fi

    print_info "Hostname verified locally: $expected"
    return 0
}


prompt_for_ad_hostname() {
    local prefix
    prefix="$(office_hostname_prefix)"

    echo "  Hostname prefix: $prefix"
    echo "  Managed names are assigned sequentially."
    echo ""
    echo "  Important:"
    echo "    Final AD collision checking happens in the domain-admin helper."
    echo "    The local pre-join script cannot reliably see all AD computer objects."
    echo ""

    local suggested
    suggested="$(suggest_hostname "$prefix" "01")"

    echo "  Temporary starting hostname:"
    echo "    $suggested"
    echo ""
    echo "  This is only a local starting hostname for the technician phase."
    echo "  It is not an availability claim. The domain admin helper will query"
    echo "  Active Directory and allocate the final hostname before joining."
    echo ""

    read -r -p "  Apply this temporary starting hostname? [Y/n]: " use_suggested
    use_suggested="${use_suggested:-Y}"

    case "$use_suggested" in
        y|Y|yes|YES)
            DOMAIN_TARGET_HOSTNAME="$suggested"
            return 0
            ;;
    esac

    echo "  Enter a workstation number or a full hostname."
    echo "  Examples:"
    echo "    7 becomes ${prefix}-07"
    echo "    ${prefix}-12 is accepted directly"
    echo ""

    local input
    local proposed
    local confirm

    while true; do
        read -r -p "  Workstation number or hostname: " input

        if echo "$input" | grep -Eq '^[0-9]+$'; then
            proposed="$(suggest_hostname "$prefix" "$input")"
        else
            proposed="$(echo "$input" | tr '[:upper:]' '[:lower:]')"
        fi

        if ! is_valid_ad_hostname "$proposed"; then
            print_warning "Hostname '$proposed' is not AD-safe."
            print_warning "Use 15 characters or fewer, letters/numbers/hyphens only."
            continue
        fi

        echo ""
        echo "------------------------------------------"
        echo "  Proposed temporary starting hostname: $proposed"
        echo "------------------------------------------"
        echo "  This is not an availability claim. Final hostname allocation will"
        echo "  be performed by the domain-admin helper using Active Directory."
        read -r -p "  Apply this temporary starting hostname? [Y/n]: " confirm
        confirm="${confirm:-Y}"

        case "$confirm" in
            y|Y|yes|YES)
                DOMAIN_TARGET_HOSTNAME="$proposed"
                return 0
                ;;
            *)
                echo ""
                print_info "Let's choose another workstation number or hostname."
                ;;
        esac
    done
}

validate_or_fix_hostname() {
    local hn
    hn="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"

    if is_valid_ad_hostname "$hn" && hostname_matches_managed_policy "$hn"; then
        print_info "Hostname is AD-safe and follows managed naming policy: $hn"
        return 0
    fi

    echo ""
    echo "=========================================="
    echo "  Hostname Policy"
    echo "=========================================="
    echo "  Current hostname: $hn"
    echo "  Required pattern: $(office_hostname_prefix)-NN"
    echo ""

    if ! is_valid_ad_hostname "$hn"; then
        print_warning "Current hostname is not AD-safe."
        print_warning "Hostnames should be 15 characters or fewer and contain only letters, numbers, and hyphens."
    elif ! hostname_matches_managed_policy "$hn"; then
        print_warning "Current hostname is AD-safe but does not follow the managed workstation naming policy."
    fi

    echo ""
    read -r -p "  Apply managed hostname policy now? [Y/n]: " answer
    answer="${answer:-Y}"

    case "$answer" in
        y|Y|yes|YES)
            prompt_for_ad_hostname

            if [ -z "$DOMAIN_TARGET_HOSTNAME" ]; then
                print_error "Internal error: hostname prompt did not set DOMAIN_TARGET_HOSTNAME."
                return 1
            fi

            if machine_has_domain_identity; then
                print_warning "Existing domain identity or keytab detected."
                print_warning "Changing hostname on an already-joined machine requires cleanup/reboot before rejoin."
                print_warning "The script will set the hostname, update /etc/hosts, save state, and stop."
                print_warning "After reboot, remove/rejoin the machine through the domain-admin handoff flow."
                read -r -p "  Continue with hostname change anyway? [y/N]: " joined_answer
                case "$joined_answer" in
                    y|Y|yes|YES) ;;
                    *)
                        print_error "Hostname change cancelled."
                        return 1
                        ;;
                esac
            fi

            print_info "Setting hostname to $DOMAIN_TARGET_HOSTNAME"
            hostnamectl set-hostname "$DOMAIN_TARGET_HOSTNAME"
            update_hosts_for_hostname "$DOMAIN_TARGET_HOSTNAME"
            verify_hostname_applied "$DOMAIN_TARGET_HOSTNAME" || return 1

            HOSTNAME_CHANGED=1

            if machine_has_domain_identity; then
                ensure_local_pam_survives_sssd_failure
                disable_sssd_if_not_joined
                save_state "REBOOT_REQUIRED_AFTER_HOSTNAME"
                print_warning "Hostname changed on a machine with existing domain identity."
                print_warning "A reboot is required before continuing."
                exit 20
            fi

            save_state "PREJOIN_HOSTNAME_APPLIED"
            print_info "Hostname applied before first domain join; continuing without reboot."
            return 0
            ;;
        *)
            if is_valid_ad_hostname "$hn"; then
                print_warning "Proceeding with existing AD-safe hostname outside managed policy: $hn"
                return 0
            fi

            print_error "Cannot safely continue with hostname '$hn'."
            print_error "Please choose a managed AD-safe hostname and rerun this script."
            return 1
            ;;
    esac
}


validate_existing_join() {
    if ! realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        return 1
    fi

    print_info "Existing domain membership detected; validating machine account..."

    if ! command -v adcli >/dev/null 2>&1; then
        print_warning "adcli is not available yet; skipping machine-account validation"
        return 0
    fi

    if adcli testjoin -D "$DOMAIN" >/dev/null 2>&1; then
        print_info "Machine account validation succeeded"
        systemctl enable --now sssd >/dev/null 2>&1 || true
        return 0
    fi

    echo ""
    print_warning "Machine appears joined, but the machine account is not valid yet."
    echo ""
    echo "=========================================="
    echo "  Domain Join Pending AD Replication"
    echo "=========================================="
    echo ""
    echo "  The workstation is joined to $DOMAIN, but machine-account"
    echo "  validation did not succeed yet. This can happen shortly after"
    echo "  a domain join while Active Directory replicates the new computer"
    echo "  account between domain controllers."
    echo ""
    echo "  Recommended action:"
    echo "    Wait 15-30 minutes, then rerun the provisioning command:"
    echo ""
    echo "      wget -qO- http://ontrack.link/joindomain | sudo bash"
    echo ""
    echo "  Do not clean up or rejoin unless this continues to fail after"
    echo "  AD replication has had time to complete, or a domain admin confirms"
    echo "  the AD computer object is stale or incorrect."
    echo "=========================================="
    echo ""
    save_state "DOMAIN_JOIN_PENDING_REPLICATION"
    ensure_local_pam_survives_sssd_failure
    return 1
}



install_domain_admin_join_helper() {
    local helper="/usr/local/sbin/dr-domain-admin-join"
    local motd="/etc/update-motd.d/99-dr-domain-join"
    local profiled="/etc/profile.d/dr-domain-join.sh"

    mkdir -p /usr/local/sbin

    cat > "$helper" << EOF
#!/bin/bash
set -euo pipefail

DOMAIN="$DOMAIN"
REALM="$REALM"
OFFICE_CODE="${OFFICE_CODE:-EP1}"
SCRIPT_VERSION="$SCRIPT_VERSION"
STATE_DIR="$STATE_DIR"
STATE_FILE="$STATE_FILE"

print_info() { echo "[INFO] \$*"; }
print_warn() { echo "[WARN] \$*" >&2; }
print_error() { echo "[ERROR] \$*" >&2; }

save_join_state() {
    mkdir -p "\$STATE_DIR"
    chmod 755 "\$STATE_DIR"
    cat > "\$STATE_FILE" << STATEEOF
SCRIPT_VERSION="\$SCRIPT_VERSION"
STAGE="\${1:-DOMAIN_JOIN_COMPLETE}"
OFFICE_CODE="\$OFFICE_CODE"
DOMAIN="\$DOMAIN"
TARGET_HOSTNAME="\${2:-}"
HOSTNAME_CHANGED="1"
STATEEOF
    chmod 600 "\$STATE_FILE"
}

cleanup_local_join_state() {
    local reset_stage="\${1:-WAITING_FOR_ADMIN}"
    local reset_host="\${2:-\$(hostnamectl --static 2>/dev/null || hostname)}"

    echo ""
    print_warn "Returning local workstation to a clean pre-join state..."

    realm leave "\$DOMAIN" >/dev/null 2>&1 || true
    rm -f /etc/krb5.keytab
    rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
    systemctl stop sssd >/dev/null 2>&1 || true
    systemctl disable sssd >/dev/null 2>&1 || true

    save_join_state "\$reset_stage" "\$reset_host"

    print_info "Local domain join state cleaned."
    print_info "Installer state reset to \$reset_stage."
    print_info "After AD-side cleanup or replication settling, rerun the admin helper:"
    echo "  sudo /usr/local/sbin/dr-domain-admin-join"
}

explain_join_validation_failure() {
    local failed_host="\${1:-\$(hostnamectl --static 2>/dev/null || hostname)}"

    echo ""
    echo "=========================================="
    echo "  Machine Account Validation Failed"
    echo "=========================================="
    echo ""
    echo "  The domain join command completed, but this workstation could not"
    echo "  validate its machine account for:"
    echo ""
    echo "    \${failed_host}"
    echo ""
    echo "  This is often temporary immediately after a successful join."
    echo "  Active Directory may need time to replicate the new computer account"
    echo "  between domain controllers before adcli testjoin succeeds."
    echo ""
    echo "  Recommended first action:"
    echo "    1. Wait 15-30 minutes."
    echo "    2. Have the technician rerun the main provisioning command:"
    echo ""
    echo "       wget -qO- http://ontrack.link/joindomain | sudo bash"
    echo ""
    echo "  Do not clean up or rejoin unless this continues to fail after"
    echo "  replication has had time to complete, or you know the AD object"
    echo "  is stale, duplicated, or incorrect."
    echo ""
    echo "  Advanced recovery option:"
    echo "    This helper can clean local realm/keytab/SSSD state so the"
    echo "    workstation can be rejoined later. It will not delete AD objects."
    echo "=========================================="
    echo ""
}

office_hostname_prefix() {
    case "\$(echo "\${OFFICE_CODE:-}" | tr '[:lower:]' '[:upper:]')" in
        EP|EP1) echo "ep-cr-kit" ;;
        MSP) echo "msp-cr-kit" ;;
        CHI) echo "chi-cr-kit" ;;
        ATL) echo "atl-cr-kit" ;;
        LON|UK|UK1) echo "lon-cr-kit" ;;
        DE|DE1) echo "de-cr-kit" ;;
        PL|PL1) echo "pl-cr-kit" ;;
        *)
            local office_lower
            office_lower="\$(echo "\${OFFICE_CODE:-kit}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
            [ -n "\$office_lower" ] || office_lower="kit"
            echo "\${office_lower}-cr-kit" | cut -c1-12 | sed 's/-\$//'
            ;;
    esac
}

is_valid_ad_hostname() {
    local hn="\$1"
    [ "\${#hn}" -le 15 ] || return 1
    echo "\$hn" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\$' || return 1
    return 0
}

suggest_hostname() {
    local prefix="\$1"
    local number="\$2"
    number="\$(echo "\$number" | tr -cd '0-9')"
    [ -n "\$number" ] || number="01"
    if [ "\${#number}" -eq 1 ]; then
        number="0\${number}"
    fi
    echo "\${prefix}-\${number}"
}

domain_to_base_dn() {
    echo "\$DOMAIN" | awk -F. '{
        for (i = 1; i <= NF; i++) {
            if (i > 1) printf ",";
            printf "DC=%s", \$i;
        }
        printf "\n";
    }'
}

discover_ldap_dcs() {
    local dc_hosts=""

    # Kerberos/GSSAPI LDAP binds must target real DC hostnames with valid
    # ldap/<dc-fqdn> service principals. Query every discovered DC because AD
    # replication lag can make one DC falsely report that a recently-created
    # computer object does not exist.
    if command -v dig >/dev/null 2>&1; then
        dc_hosts="\$(dig +short _ldap._tcp.\$DOMAIN SRV 2>/dev/null \
            | sort -n -k1,1 -k2,2 \
            | awk '{print \$4}' \
            | sed 's/[.]\$//' \
            | awk 'NF && !seen[\$0]++' || true)"
    fi

    if [ -z "\$dc_hosts" ] && command -v host >/dev/null 2>&1; then
        dc_hosts="\$(host -t SRV _ldap._tcp.\$DOMAIN 2>/dev/null \
            | awk '{print \$NF}' \
            | sed 's/[.]\$//' \
            | awk 'NF && !seen[\$0]++' || true)"
    fi

    if [ -z "\$dc_hosts" ]; then
        print_error "Unable to discover LDAP domain controllers from _ldap._tcp.\$DOMAIN."
        return 1
    fi

    echo "\$dc_hosts"
}

join_dc() {
    # Use the first reachable DC from the allocator list for join-time validation
    # attempts. realmd may still choose its own DC internally, so post-join
    # validation includes retries to allow AD replication to settle.
    echo "\$LDAP_DCS" | awk 'NF {print; exit}'
}

ldap_search_computer_object() {
    local ldap_dc="\$1"
    local base_dn="\$2"
    local sam="\$3"

    # Disable reverse-DNS canonicalization for this process. Some lab/DC
    # networks lack matching PTR records, and rdns canonicalization can make
    # GSSAPI request the wrong service principal.
    #
    # Important: this search must be completely non-interactive. On some
    # OpenLDAP builds, referrals/SASL chatter can appear to hang at the first
    # no-match result. -Q suppresses SASL progress output, referrals=false
    # prevents referral chasing, timeout bounds the query, and </dev/null
    # guarantees ldapsearch cannot wait for keyboard input.
    timeout 15s env KRB5_CONFIG=/tmp/dr-domain-admin-krb5.conf         ldapsearch -LLL -Q -Y GSSAPI -N         -o nettimeout=10         -o timelimit=10         -o referrals=false         -H "ldap://\$ldap_dc"         -b "\$base_dn"         -s sub         "(&(objectClass=computer)(sAMAccountName=\$sam))" dn </dev/null
}

ad_computer_exists() {
    local candidate="\$1"
    local sam
    local base_dn
    local output
    local rc
    local dc
    local successful_queries=0
    local failed_queries=0

    sam="\$(echo "\$candidate" | tr '[:lower:]' '[:upper:]')\$"
    base_dn="\$(domain_to_base_dn)"

    # Authoritative check: search every discovered AD DC for the computer
    # object's sAMAccountName. A single positive match means the hostname is
    # occupied. This prevents replication-lag collisions where one DC says
    # "not found" while another DC already has the object.
    for dc in \$LDAP_DCS; do
        set +e
        output="\$(ldap_search_computer_object "\$dc" "\$base_dn" "\$sam" 2>&1)"
        rc=\$?
        set -e

        if [ "\$rc" -ne 0 ]; then
            failed_queries=\$((failed_queries + 1))
            echo "    AD: query failed on \$dc while checking \$candidate" >&2
            echo "\$output" | sed 's/^/      /' >&2
            continue
        fi

        successful_queries=\$((successful_queries + 1))

        if echo "\$output" | grep -qi '^dn:'; then
            echo "    AD: computer object exists for \$candidate on \$dc" >&2
            echo "\$output" | sed 's/^/      /' >&2
            return 0
        fi
    done

    if [ "\$successful_queries" -eq 0 ]; then
        print_error "LDAP computer-object query failed on every discovered DC while checking \$candidate."
        print_error "Refusing to allocate a hostname when AD cannot be queried authoritatively."
        exit 1
    fi

    if [ "\$failed_queries" -gt 0 ]; then
        print_warn "One or more DCs could not be queried while checking \$candidate."
        print_warn "Continuing because at least one authoritative LDAP query completed successfully."
    fi

    echo "    AD: no computer object found for \$candidate on any queried DC" >&2
    return 1
}

show_dns_diagnostic() {
    local candidate="\$1"
    if getent hosts "\${candidate}.\${DOMAIN}" >/dev/null 2>&1 || getent hosts "\$candidate" >/dev/null 2>&1; then
        echo "    DNS: record exists for \$candidate (diagnostic only; AD remains authoritative)" >&2
    else
        echo "    DNS: no record found for \$candidate (diagnostic only)" >&2
    fi
}

find_next_available_ad_hostname() {
    local prefix
    local n
    local candidate

    prefix="\$(office_hostname_prefix)"

    for n in \$(seq 1 99); do
        candidate="\$(suggest_hostname "\$prefix" "\$n")"
        is_valid_ad_hostname "\$candidate" || continue
        echo "  checking AD computer object: \$candidate" >&2
        show_dns_diagnostic "\$candidate"
        if ! ad_computer_exists "\$candidate"; then
            echo "\$candidate"
            return 0
        fi
    done

    return 1
}

update_hosts_for_hostname_admin() {
    local new_hostname="\$1"
    local hosts_file="/etc/hosts"
    local fqdn="\${new_hostname}.\${DOMAIN}"
    local tmp_file

    touch "\$hosts_file"
    cp "\$hosts_file" "\${hosts_file}.dr-domain-admin-join.bak.\$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    tmp_file="\$(mktemp)"
    awk -v hn="\$new_hostname" -v fqdn="\$fqdn" '
        BEGIN { replaced=0 }
        /^127[.]0[.]1[.]1[[:space:]]+/ {
            if (!replaced) {
                print "127.0.1.1    " fqdn "    " hn
                replaced=1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print "127.0.1.1    " fqdn "    " hn
            }
        }
    ' "\$hosts_file" > "\$tmp_file"

    cat "\$tmp_file" > "\$hosts_file"
    rm -f "\$tmp_file"
}

print_banner() {
    echo "=========================================="
    echo "  DR Domain Admin Join Helper"
    echo "  Version \$SCRIPT_VERSION"
    echo "=========================================="
    echo ""
}

print_banner

if [ "\$(id -u)" -ne 0 ]; then
    print_error "Run this helper with sudo:"
    echo "  sudo /usr/local/sbin/dr-domain-admin-join"
    exit 1
fi

for required in realm adcli kinit hostnamectl ldapsearch; do
    if ! command -v "\$required" >/dev/null 2>&1; then
        print_error "Required command not found: \$required"
        print_error "Have the technician rerun the provisioning script to complete package installation."
        exit 1
    fi
done

current_host="\$(hostnamectl --static 2>/dev/null || hostname)"
echo "Current hostname: \$current_host"
echo "Domain:           \$DOMAIN"
echo "Office code:      \$OFFICE_CODE"
echo "Hostname policy:  \$(office_hostname_prefix)-##"
echo ""

if realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
    print_warn "This machine already appears joined to a realm."
    realm list || true
    echo ""
    print_info "Validating existing machine account..."
    if adcli testjoin -D "\$DOMAIN"; then
        print_info "Join is OK."
        save_join_state "DOMAIN_JOIN_COMPLETE" "\$current_host"
        exit 0
    fi
    explain_join_validation_failure "\$current_host"
    save_join_state "DOMAIN_JOIN_PENDING_REPLICATION" "\$current_host"
    read -r -p "Advanced recovery: clean local join state now? [y/N]: " rejoin
    rejoin="\${rejoin:-N}"
    case "\$rejoin" in
        y|Y|yes|YES)
            cleanup_local_join_state "WAITING_FOR_ADMIN" "\$current_host"
            ;;
        *)
            print_warn "Leaving local join material in place. Wait 15-30 minutes, then rerun the main provisioning script."
            exit 1
            ;;
    esac
fi

echo "Enter the domain admin username that has permission to query and join AD computer objects."
read -r -p "Domain admin username: " admin_user

if [ -z "\$admin_user" ]; then
    print_error "Domain admin username is required."
    exit 1
fi

case "\$admin_user" in
    *@*) kerberos_principal="\$admin_user" ;;
    *) kerberos_principal="\${admin_user}@\${REALM}" ;;
esac

echo ""
print_info "Authenticating to Active Directory as \$kerberos_principal for authoritative hostname allocation..."
print_info "You may be prompted for the domain admin password."
kdestroy >/dev/null 2>&1 || true
if ! kinit "\$kerberos_principal"; then
    print_error "Kerberos authentication failed. Cannot query AD authoritatively."
    exit 1
fi

LDAP_DCS="\$(discover_ldap_dcs)"
if [ -z "\$LDAP_DCS" ]; then
    print_error "Cannot query AD authoritatively without discovered LDAP domain controllers."
    exit 1
fi
print_info "Using LDAP domain controller(s) for AD queries:"
echo "\$LDAP_DCS" | sed 's/^/  /'
JOIN_DC="\$(join_dc)"

cat > /tmp/dr-domain-admin-krb5.conf << KRB5EOF
[libdefaults]
    default_realm = \$REALM
    rdns = false
    dns_canonicalize_hostname = false
    udp_preference_limit = 0

[domain_realm]
    .\$DOMAIN = \$REALM
    \$DOMAIN = \$REALM
KRB5EOF
chmod 600 /tmp/dr-domain-admin-krb5.conf
trap 'rm -f /tmp/dr-domain-admin-krb5.conf' EXIT

echo ""
print_info "Querying Active Directory for the first unused managed hostname..."
next_host=""

if next_host="\$(find_next_available_ad_hostname)"; then
    print_info "Allocated hostname from AD: \$next_host"
else
    print_error "No available managed hostname found from 01 through 99."
    exit 1
fi

if [ "\$current_host" != "\$next_host" ]; then
    echo ""
    print_warn "Current hostname:      \$current_host"
    print_warn "AD-allocated hostname: \$next_host"
    read -r -p "Rename this machine to \$next_host before joining? [Y/n]: " rename_answer
    rename_answer="\${rename_answer:-Y}"
    case "\$rename_answer" in
        y|Y|yes|YES)
            hostnamectl set-hostname "\$next_host"
            update_hosts_for_hostname_admin "\$next_host"
            current_host="\$next_host"
            print_info "Hostname updated to \$current_host"
            ;;
        *)
            print_error "Refusing to join with a hostname that was not allocated from AD."
            exit 1
            ;;
    esac
else
    update_hosts_for_hostname_admin "\$next_host"
    print_info "Hostname already matches AD allocation. /etc/hosts refreshed."
fi

echo ""
print_info "Performing final pre-join collision check across discovered DCs..."
if ad_computer_exists "\$current_host"; then
    print_error "Hostname \$current_host is no longer available in Active Directory."
    print_error "Another join may have created this object, or AD replication has caught up."
    print_error "Rerun this helper to allocate the next managed hostname."
    exit 1
fi

print_info "Joining \$current_host to \$DOMAIN..."
print_info "You may be prompted for the domain admin password again by realmd."
if ! realm join -v "\$DOMAIN" -U "\$admin_user"; then
    print_error "realm join failed."
    exit 1
fi

echo ""
print_info "Validating machine account with adcli testjoin..."
validation_ok=0
for attempt in 1 2 3 4 5 6; do
    if adcli testjoin -D "\$DOMAIN"; then
        validation_ok=1
        break
    fi
    print_warn "Machine-account validation failed on attempt \$attempt; waiting for AD replication/SSSD to settle..."
    systemctl restart sssd >/dev/null 2>&1 || true
    sleep 10
done

if [ "\$validation_ok" -eq 1 ]; then
    print_info "Join is OK."
    save_join_state "DOMAIN_JOIN_COMPLETE" "\$current_host"
else
    explain_join_validation_failure "\$current_host"
    save_join_state "DOMAIN_JOIN_PENDING_REPLICATION" "\$current_host"
    read -r -p "Advanced recovery: clean local join state now? [y/N]: " cleanup_answer
    cleanup_answer="\${cleanup_answer:-N}"
    case "\$cleanup_answer" in
        y|Y|yes|YES)
            cleanup_local_join_state "WAITING_FOR_ADMIN" "\$current_host"
            exit 1
            ;;
        *)
            print_warn "Leaving local join material in place so AD replication can settle."
            print_warn "Wait 15-30 minutes, then rerun the main provisioning script."
            exit 1
            ;;
    esac
fi

echo ""
print_info "Restarting SSSD..."
systemctl enable --now sssd >/dev/null 2>&1 || systemctl restart sssd || true

echo ""
echo "=========================================="
echo "  Domain join validated"
echo "=========================================="
echo ""
echo "Return to the local technician and have them rerun:"
echo '  wget -qO- http://ontrack.link/joindomain | sudo bash'
echo ""
EOF

    chmod 755 "$helper"
    chown root:root "$helper"

    # SSH/MOTD reminder for domain admins. This is intentionally short and only
    # appears while the machine is not yet validly joined.
    mkdir -p /etc/update-motd.d
    cat > "$motd" << 'EOF'
#!/bin/sh
if command -v realm >/dev/null 2>&1 && realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
    if command -v adcli >/dev/null 2>&1 && adcli testjoin -D dr.kodr.local >/dev/null 2>&1; then
        exit 0
    fi
fi

if [ -x /usr/local/sbin/dr-domain-admin-join ]; then
    echo ""
    echo "=========================================="
    echo "  DR Domain Join Pending"
    echo "=========================================="
    echo "  Run: sudo /usr/local/sbin/dr-domain-admin-join"
    echo "=========================================="
    echo ""
fi
EOF
    chmod 755 "$motd"
    chown root:root "$motd"

    cat > "$profiled" << 'EOF'
#!/bin/sh
case "$-" in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

if [ -x /usr/local/sbin/dr-domain-admin-join ]; then
    if command -v realm >/dev/null 2>&1 && realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        if command -v adcli >/dev/null 2>&1 && adcli testjoin -D dr.kodr.local >/dev/null 2>&1; then
            return 0 2>/dev/null || exit 0
        fi
    fi
    echo ""
    echo "DR Domain Join Pending: sudo /usr/local/sbin/dr-domain-admin-join"
    echo ""
fi
EOF
    chmod 644 "$profiled"
    chown root:root "$profiled"

    cat > /etc/motd << 'EOF'
DR Domain Join Pending
Run: sudo /usr/local/sbin/dr-domain-admin-join
EOF

    print_info "Installed domain admin join helper: $helper"
    print_info "Installed SSH login reminders: $motd, $profiled, /etc/motd"
}

print_domain_admin_join_instructions() {
    local short_host
    local fqdn
    local ip_list
    local ssh_user
    local first_ip

    install_domain_admin_join_helper

    short_host="$(hostname -s 2>/dev/null || hostname)"
    fqdn="$(hostname -f 2>/dev/null || hostname)"
    ip_list="$(hostname -I 2>/dev/null | xargs 2>/dev/null || true)"
    ssh_user="${SUDO_USER:-}"

    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" = "root" ]; then
        ssh_user="$(logname 2>/dev/null || whoami)"
    elif [ -z "$ssh_user" ]; then
        ssh_user="$(logname 2>/dev/null || whoami)"
    fi

    echo ""
    echo "=========================================="
    echo "  Domain Admin Action Required"
    echo "=========================================="
    echo ""
    echo "  This machine is prepared but is not joined to:"
    echo "    $DOMAIN"
    echo ""
    echo "  Hostname:"
    echo "    $short_host"
    echo ""
    echo "  Reachable address(es):"
    if [ -n "$ip_list" ]; then
        echo "    $ip_list"
    else
        echo "    <unable to determine IP address>"
    fi
    echo ""
    echo "  Ask a domain admin to SSH into this machine and run:"
    echo ""
    if [ -n "$ip_list" ]; then
        first_ip="$(echo "$ip_list" | awk '{print $1}')"
        echo "    ssh ${ssh_user}@${first_ip}"
    else
        echo "    ssh ${ssh_user}@${fqdn}"
    fi
    echo "    sudo /usr/local/sbin/dr-domain-admin-join"
    echo ""
    echo "  The same command will also be shown to the admin after SSH login."
    echo ""
    echo "  After the helper reports 'Join is OK', rerun this script locally:"
    echo ""
    echo '    wget -qO- http://ontrack.link/joindomain | sudo bash'
    echo ""
    echo "=========================================="
    echo ""
}
print_machine_status() {
    echo ""
    echo "=========================================="
    echo "  Machine Status"
    echo "=========================================="
    echo "  Hostname: $(hostnamectl --static 2>/dev/null || hostname)"
    echo "  Domain:   $DOMAIN"
    if realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        echo "  Realm:    Joined"
        if command -v adcli >/dev/null 2>&1 && adcli testjoin -D "$DOMAIN" >/dev/null 2>&1; then
            echo "  Machine Account: VALID"
        else
            echo "  Machine Account: NOT VALIDATED"
        fi
    else
        echo "  Realm:    Not joined"
        echo "  Machine Account: Not present"
    fi
    echo "=========================================="
    echo ""
}

prompt_sudo_user() {
    echo ""
    echo "  Enter the domain user who will use this workstation."
    echo "  This user will receive the limited Mount DR Tools permission."
    echo "  Enter the short account name only (e.g. jsmith — not jsmith@$DOMAIN)."
    echo "  Leave blank only if no domain user is available yet."
    echo ""
    read -r -p "  Domain username for sudo access (or press Enter to skip): " DOMAIN_SUDO_USER

    # Strip any domain suffix if accidentally included
    DOMAIN_SUDO_USER="${DOMAIN_SUDO_USER%%@*}"
}

# ── Install domain packages ───────────────────────────────────────────────────

install_time_sync_prerequisites() {
    # IMPORTANT: Do not run apt-get here. If the workstation clock is behind or
    # ahead of the repository timestamps, apt will fail with "Release file ...
    # is not valid yet" before we get a chance to repair time. This function is
    # intentionally limited to checking already-present tooling. The full package
    # install occurs after sync_time() has repaired/verified the clock.
    print_info "Checking time/DNS prerequisite tools without using apt..."

    if ! command -v nmcli >/dev/null 2>&1; then
        print_warning "nmcli not found; NetworkManager DNS configuration may not be available"
    fi

    if ! command -v chronyc >/dev/null 2>&1; then
        print_warning "chronyc not found; will try systemd-timesyncd before apt runs"
    fi
}


bootstrap_time_before_apt() {
    # Repair/verify time before apt-get update. On fresh installs, chrony may
    # not be installed yet, so try systemd-timesyncd first and only use chrony
    # if it is already present.
    print_info "Bootstrapping system clock before apt..."

    if systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
        print_info "Trying systemd-timesyncd..."
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
        timedatectl set-ntp true >/dev/null 2>&1 || true

        local count=0
        while [ "$count" -lt 6 ]; do
            if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q '^yes$'; then
                print_info "Clock synchronized via systemd-timesyncd"
                hwclock --systohc >/dev/null 2>&1 || true
                return 0
            fi
            sleep 5
            count=$((count + 1))
        done
    fi

    if command -v chronyc >/dev/null 2>&1; then
        print_info "Trying existing chrony..."
        configure_chrony || true
        systemctl enable --now chrony >/dev/null 2>&1 || true
        chronyc -a burst 4/4 >/dev/null 2>&1 || true
        sleep 2
        chronyc -a makestep >/dev/null 2>&1 || true

        if chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
            print_info "Clock synchronized via chrony"
            hwclock --systohc >/dev/null 2>&1 || true
            return 0
        fi

        if force_step_from_chrony_offset; then
            print_info "Clock stepped from chrony NTP offset"
            systemctl restart chrony >/dev/null 2>&1 || true
            hwclock --systohc >/dev/null 2>&1 || true
            return 0
        fi
    fi

    print_info "Trying HTTP Date header fallback..."
    local http_date=""
    if command -v wget >/dev/null 2>&1; then
        http_date=$(wget -S --spider -T 10 -t 1 http://security.ubuntu.com/ 2>&1             | awk '/^[[:space:]]*Date:/ {sub(/^[[:space:]]*Date:[[:space:]]*/, ""); print; exit}')
    elif command -v curl >/dev/null 2>&1; then
        http_date=$(curl -I --max-time 10 http://security.ubuntu.com/ 2>/dev/null             | awk 'BEGIN{IGNORECASE=1} /^Date:/ {sub(/^Date:[[:space:]]*/, ""); sub(/
$/, ""); print; exit}')
    fi

    if [ -n "$http_date" ]; then
        print_warning "Setting system clock from HTTP Date header: $http_date"
        if date -u -s "$http_date" >/dev/null 2>&1; then
            hwclock --systohc >/dev/null 2>&1 || true
            print_info "Clock set from HTTP Date header"
            return 0
        fi
    fi

    print_warning "Clock synchronization could not be confirmed before apt"
    print_warning "Current time: $(date -R)"
    return 1
}

install_domain_packages() {
    print_info "Installing domain packages..."
    trap 'if [ "$APT_BACKGROUND_GUARD_ACTIVE" -eq 1 ]; then restore_apt_respawn_units; APT_BACKGROUND_GUARD_ACTIVE=0; fi' RETURN

    wait_for_apt_locks || return 1
    apt-get update -qq

    install_package "realmd"
    install_package "sssd"
    install_package "sssd-tools"
    install_package "adcli"
    install_package "samba-common-bin"
    install_package "packagekit"
    install_package "cifs-utils"
    install_package "smbclient"
    install_package "winbind"
    install_package "chrony"

    print_info "Preconfiguring Kerberos default realm..."
    echo "krb5-config krb5-config/default_realm string $REALM" | debconf-set-selections
    echo "krb5-config krb5-config/kerberos_servers string $DOMAIN" | debconf-set-selections
    echo "krb5-config krb5-config/admin_server string $DOMAIN" | debconf-set-selections
    install_package "krb5-user"   # provides klist for keytab and ticket diagnostics

    install_package "dnsutils"    # provides host/nslookup for DNS diagnostics
    install_package "ldap-utils"  # provides ldapsearch for authoritative AD computer-object checks
    install_package "autofs"      # on-demand CIFS mount daemon for DRIP image share access
    install_package "openssh-server"
    install_package "unattended-upgrades"
    install_package "apt-listchanges"
    install_package "needrestart"
    systemctl enable --now ssh > /dev/null 2>&1 || true

    # Home directory creation: oddjob on Debian, libpam-mkhomedir on Ubuntu
    if [[ "$OS" == "debian" ]]; then
        install_package "oddjob"
        install_package "oddjob-mkhomedir"
    else
        install_package "libpam-mkhomedir"
    fi

    if [ "$APT_BACKGROUND_GUARD_ACTIVE" -eq 1 ]; then
        restore_apt_respawn_units
        APT_BACKGROUND_GUARD_ACTIVE=0
    fi
}


# ── No-reboot patch policy for KIT workstations ──────────────────────────────
# These workstations may run KIT jobs for long periods. Install security update
# tooling, allow updates to apply, but never automatically reboot. Reboot need is
# surfaced through syslog and MOTD so technicians can schedule downtime safely.

configure_no_reboot_policy() {
    print_info "Configuring no-auto-reboot update policy for KIT workstations..."

    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/52-kit-workstation << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";

Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

    mkdir -p /etc/needrestart/conf.d
    cat > /etc/needrestart/conf.d/kit.conf << 'EOF'
# Automatically restart affected services after package updates, but do not
# reboot the workstation automatically. Machine reboots remain a manual action.
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF

    cat > /usr/local/bin/kit-reboot-status << 'EOF'
#!/bin/bash
set -euo pipefail

KIT_PATTERN="__KIT_PROCESS_PATTERN__"
REBOOT_REQUIRED="/var/run/reboot-required"
REBOOT_PACKAGES="/var/run/reboot-required.pkgs"

kit_running() {
    pgrep -af "$KIT_PATTERN" >/dev/null 2>&1
}

if [ -f "$REBOOT_REQUIRED" ]; then
    if kit_running; then
        logger -t kit-reboot-status "Reboot required, but KIT appears active; reboot deferred."
        echo "REBOOT_REQUIRED_KIT_ACTIVE"
    else
        logger -t kit-reboot-status "Reboot required and KIT does not appear active; schedule maintenance reboot."
        echo "REBOOT_REQUIRED_KIT_INACTIVE"
    fi
    if [ -f "$REBOOT_PACKAGES" ]; then
        echo "Packages requiring reboot:"
        cat "$REBOOT_PACKAGES"
    fi
else
    if kit_running; then
        echo "NO_REBOOT_REQUIRED_KIT_ACTIVE"
    else
        echo "NO_REBOOT_REQUIRED_KIT_INACTIVE"
    fi
fi
EOF
    sed -i "s|__KIT_PROCESS_PATTERN__|${KIT_PROCESS_PATTERN}|g" /usr/local/bin/kit-reboot-status
    chmod +x /usr/local/bin/kit-reboot-status

    cat > /usr/local/bin/check-reboot-required.sh << 'EOF'
#!/bin/bash
set -euo pipefail
/usr/local/bin/kit-reboot-status >/dev/null || true
EOF
    chmod +x /usr/local/bin/check-reboot-required.sh

    cat > /etc/systemd/system/kit-reboot-check.service << 'EOF'
[Unit]
Description=Check reboot-required state for KIT workstation

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check-reboot-required.sh
EOF

    cat > /etc/systemd/system/kit-reboot-check.timer << 'EOF'
[Unit]
Description=Run KIT reboot-required check hourly

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    mkdir -p /etc/update-motd.d
    cat > /etc/update-motd.d/99-kit-status << 'EOF'
#!/bin/sh
if [ -x /usr/local/bin/kit-reboot-status ]; then
    status=$(/usr/local/bin/kit-reboot-status 2>/dev/null || true)
    case "$status" in
        REBOOT_REQUIRED_KIT_ACTIVE*)
            echo ""
            echo "*** REBOOT REQUIRED - KIT appears active; defer reboot. ***"
            ;;
        REBOOT_REQUIRED_KIT_INACTIVE*)
            echo ""
            echo "*** REBOOT REQUIRED - schedule maintenance reboot. ***"
            ;;
        NO_REBOOT_REQUIRED_KIT_ACTIVE*)
            echo ""
            echo "*** KIT appears active. ***"
            ;;
    esac
fi
EOF
    chmod +x /etc/update-motd.d/99-kit-status

    systemctl daemon-reload
    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
    systemctl enable --now kit-reboot-check.timer >/dev/null 2>&1 || true

    print_info "No-auto-reboot update policy configured"
    print_info "KIT process pattern: ${KIT_PROCESS_PATTERN}"
    print_info "Check status with: /usr/local/bin/kit-reboot-status"
}

# ── NetworkManager helpers ───────────────────────────────────────────────────

get_active_connection() {
    nmcli -t -f NAME,TYPE connection show --active 2>/dev/null \
        | awk -F: '$2 != "loopback" {print $1; exit}'
}

get_active_device() {
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | awk -F: '$2 != "lo" && $2 != "" {print $2; exit}'
}

is_valid_ip_literal() {
    # Accept IPv4 and simple IPv6 literals; reject separators like "|" that can
    # appear in human-formatted nmcli output.
    local value="$1"
    if echo "$value" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        return 0
    fi
    if echo "$value" | grep -Eq '^[0-9A-Fa-f:]+$' && echo "$value" | grep -q ':'; then
        return 0
    fi
    return 1
}

get_current_dns_servers() {
    # Return DHCP/VPN-provided DNS servers for the active non-loopback device,
    # one per line. Filter aggressively so Chrony never receives bogus entries
    # such as "|" from formatted nmcli output.
    local device
    device="$(get_active_device)"

    if [ -z "$device" ]; then
        return 0
    fi

    nmcli -g IP4.DNS,IP6.DNS device show "$device" 2>/dev/null \
        | tr ' |,' '\n' \
        | awk 'NF {gsub(/^ +| +$/, ""); print}' \
        | while read -r dns; do
            if is_valid_ip_literal "$dns"; then
                echo "$dns"
            fi
        done \
        | awk '!seen[$0]++'
}

# ── Configure DNS servers ─────────────────────────────────────────────────────
# Normal behavior: leave DHCP/VPN-provided DNS servers alone.
# Optional behavior: if DNS_SERVERS is set in domain-join.conf, apply it as an
# explicit override. Our EP testing showed DHCP supplied 10.59.4.201/10.59.4.202
# correctly; the failure was missing search domains, not wrong DNS servers.

configure_dns_servers() {
    local connection
    connection="$(get_active_connection)"

    if [ -z "$connection" ]; then
        print_warning "No active NetworkManager connection found — skipping DNS server configuration"
        return 0
    fi

    if [ -z "$DNS_SERVERS" ]; then
        print_info "Keeping DHCP/VPN DNS servers on '$connection'"
        nmcli -g IP4.DNS device show "$(nmcli -g GENERAL.DEVICES connection show "$connection" 2>/dev/null | head -1)" 2>/dev/null || true
        return 0
    fi

    local first_dns
    first_dns=$(echo "$DNS_SERVERS" | awk '{print $1}')
    local current
    current=$(nmcli -g ipv4.dns connection show "$connection" 2>/dev/null || true)
    if echo "$current" | grep -q "$first_dns"; then
        print_info "DNS override already configured on '$connection'"
        return 0
    fi

    print_info "Applying DNS override to connection '$connection': $DNS_SERVERS"
    nmcli connection modify "$connection" ipv4.dns "$DNS_SERVERS"
    nmcli connection up "$connection" > /dev/null
    print_info "DNS override applied"

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl restart systemd-resolved
    fi
}

# ── Configure chrony NTP source ───────────────────────────────────────────────
# Kerberos requires reasonable clock sync. If DNS_SERVERS override is set, use
# those servers as NTP sources. Otherwise, use the DHCP/VPN-provided DNS servers
# currently active on the interface. If none can be determined, leave chrony
# defaults in place and allow sync_time() to warn rather than hard-fail.

configure_chrony() {
    local chrony_conf
    if [ -f "/etc/chrony/chrony.conf" ]; then
        chrony_conf="/etc/chrony/chrony.conf"
    elif [ -f "/etc/chrony.conf" ]; then
        chrony_conf="/etc/chrony.conf"
    else
        print_warning "chrony.conf not found — skipping NTP source configuration"
        return 0
    fi

    local raw_servers=""
    if [ -n "$DNS_SERVERS" ]; then
        raw_servers="$DNS_SERVERS"
    else
        raw_servers="$(get_current_dns_servers | tr '\n' ' ')"
    fi

    local ntp_servers=""
    local server
    for server in $raw_servers; do
        if is_valid_ip_literal "$server"; then
            ntp_servers="$ntp_servers $server"
        else
            print_warning "Ignoring invalid NTP/DNS server token from resolver state: $server"
        fi
    done
    ntp_servers="$(echo "$ntp_servers" | xargs 2>/dev/null || true)"

    if [ -z "$ntp_servers" ]; then
        print_warning "No valid DHCP/VPN DNS servers found to use as NTP sources — leaving chrony defaults in place"
        return 0
    fi

    print_info "Configuring chrony to use current domain DNS/DC servers as NTP sources: $ntp_servers"

    # Clean up bad/duplicate entries from earlier test runs. This keeps the
    # function idempotent and removes malformed lines such as: server | iburst.
    sed -i \
        -e '/^[[:space:]]*server[[:space:]]*|[[:space:]]/d' \
        -e '/^[[:space:]]*makestep[[:space:]]/d' \
        -e '/^[[:space:]]*rtcsync[[:space:]]*$/d' \
        "$chrony_conf"

    # Remove any previous managed block from this script.
    sed -i '/^# BEGIN domain-join chrony sources$/,/^# END domain-join chrony sources$/d' "$chrony_conf"

    # Disable active pool/server lines outside our managed block so the local
    # corporate time sources are preferred where public NTP is blocked.
    sed -i \
        -e 's/^[[:space:]]*pool[[:space:]]/# &/' \
        -e 's/^[[:space:]]*server[[:space:]]/# &/' \
        "$chrony_conf"

    {
        echo ""
        echo "# BEGIN domain-join chrony sources"
        echo "# Added by domain-join.sh for Kerberos/AD time synchronization"
        echo "rtcsync"
        echo "makestep 1.0 3"
        for server in $ntp_servers; do
            echo "server $server iburst prefer"
        done
        echo "# END domain-join chrony sources"
    } >> "$chrony_conf"

    systemctl restart chrony > /dev/null 2>&1 || true
    print_info "chrony NTP sources configured"
}

# ── Time synchronization ──────────────────────────────────────────────────────
# Kerberos authentication (used by Active Directory) requires the client clock
# to be within 5 minutes of the domain controller. A clock that is out of sync
# causes domain joins and logins to fail with cryptic errors. Chrony must be
# running and the clock synchronized before attempting to join.

force_step_from_chrony_offset() {
    # Fallback for large offsets where chrony has valid NTP replies but has not
    # selected a source yet. This reads the measured offset from chronyc ntpdata
    # and steps the system clock once, then writes the corrected time to RTC.
    local sources source offset offset_int abs_offset now_epoch new_epoch
    sources="$(get_current_dns_servers | tr '\n' ' ')"

    for source in $sources; do
        if ! is_valid_ip_literal "$source"; then
            continue
        fi

        offset="$(chronyc ntpdata "$source" 2>/dev/null \
            | awk -F: '/^Offset[[:space:]]*:/ {gsub(/ seconds/, "", $2); gsub(/^ +| +$/, "", $2); print $2; exit}')"

        if [ -z "$offset" ]; then
            continue
        fi

        offset_int="$(awk -v o="$offset" 'BEGIN { printf "%.0f", o }')"
        abs_offset="$(awk -v o="$offset" 'BEGIN { if (o < 0) o = -o; printf "%.0f", o }')"

        if [ "$abs_offset" -ge 300 ]; then
            print_warning "Large clock offset detected from $source: ${offset}s — forcing one-time clock step"
            now_epoch="$(date -u +%s)"
            new_epoch=$((now_epoch + offset_int))
            date -u -s "@$new_epoch" > /dev/null
            hwclock --systohc > /dev/null 2>&1 || true
            return 0
        fi
    done

    return 1
}

sync_time() {
    print_info "Enabling time synchronization via chrony..."
    systemctl enable --now chrony > /dev/null 2>&1

    # Ask chrony to take immediate measurements and step the clock if needed.
    chronyc -a burst 4/4 > /dev/null 2>&1 || true
    sleep 2
    chronyc -a makestep > /dev/null 2>&1 || true

    # If the offset is extremely large, chrony may receive valid NTP replies but
    # still not select a source. Force a one-time step from a valid NTP offset.
    if ! chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
        force_step_from_chrony_offset || true
        systemctl restart chrony > /dev/null 2>&1 || true
        chronyc -a burst 4/4 > /dev/null 2>&1 || true
        sleep 2
        chronyc -a makestep > /dev/null 2>&1 || true
        hwclock --systohc > /dev/null 2>&1 || true
    fi

    print_info "Waiting for clock synchronization (required for Kerberos)..."
    local retries=6   # 6 × 5 s = 30 s maximum wait
    local count=0
    while [ "$count" -lt "$retries" ]; do
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q "^yes$"; then
            print_info "Clock is synchronized"
            return 0
        fi

        if chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
            print_info "Clock is synchronized according to chrony"
            hwclock --systohc > /dev/null 2>&1 || true
            return 0
        fi

        sleep 5
        count=$((count + 1))
    done

    print_warning "Clock synchronization not confirmed after 30 seconds — proceeding anyway"
    print_warning "If the join or login fails, verify with: timedatectl && chronyc tracking && chronyc sources -v"
}

# ── Kerberos configuration ────────────────────────────────────────────────────
# Verify /etc/krb5.conf has the correct default_realm and required settings
# before joining. A stale or incorrectly pre-populated krb5.conf can cause
# realm join to write the wrong realm into the machine keytab, requiring a
# full leave/rejoin to fix. Also sets rdns = false to prevent SSSD GSSAPI
# failures in environments where the DC's IP has no PTR record.

verify_krb5_conf() {
    local krb5_conf="/etc/krb5.conf"
    print_info "Verifying Kerberos configuration ($krb5_conf)..."

    if [ ! -f "$krb5_conf" ]; then
        print_info "$krb5_conf not found — creating with correct settings"
        cat > "$krb5_conf" << EOF
[libdefaults]
    default_realm = $REALM
    udp_preference_limit = 0
    rdns = false

[realms]
    $REALM = {
        kdc = $DOMAIN
        admin_server = $DOMAIN
    }

[domain_realm]
    .$DOMAIN = $REALM
    $DOMAIN = $REALM
EOF
        return 0
    fi

    # Check and fix default_realm
    local current_realm
    current_realm=$(grep -i "^\s*default_realm\s*=" "$krb5_conf" 2>/dev/null \
        | awk -F= '{print $2}' | tr -d ' \t' | head -1)

    if [ -z "$current_realm" ]; then
        print_info "No default_realm found in $krb5_conf — adding"
        sed -i "/^\[libdefaults\]/a\\    default_realm = $REALM" "$krb5_conf"
    elif [ "$current_realm" != "$REALM" ]; then
        print_warning "Incorrect default_realm '$current_realm' in $krb5_conf — correcting to '$REALM'"
        sed -i "s/^\s*default_realm\s*=.*/    default_realm = $REALM/" "$krb5_conf"
    else
        print_info "default_realm is correct: $REALM"
    fi

    # Ensure rdns = false is set in [libdefaults].
    # Required when the DC's IP has no PTR record — without this, Kerberos
    # tries to canonicalize the DC hostname via reverse DNS, fails, and
    # constructs the wrong SPN, causing SSSD to fail with "Server not found
    # in Kerberos database".
    if ! grep -q "^\s*rdns\s*=" "$krb5_conf"; then
        print_info "Adding 'rdns = false' to [libdefaults] in $krb5_conf"
        sed -i "/^\[libdefaults\]/a\\    rdns = false" "$krb5_conf"
    else
        print_info "'rdns' already set in $krb5_conf"
    fi

    # Ensure [realms] section exists
    if ! grep -q "^\[realms\]" "$krb5_conf"; then
        print_info "Adding [realms] section to $krb5_conf"
        cat >> "$krb5_conf" << EOF

[realms]
    $REALM = {
        kdc = $DOMAIN
        admin_server = $DOMAIN
    }
EOF
    fi

    # Ensure [domain_realm] mapping exists
    if ! grep -q "\.$DOMAIN\s*=" "$krb5_conf"; then
        print_info "Adding [domain_realm] mapping to $krb5_conf"
        cat >> "$krb5_conf" << EOF

[domain_realm]
    .$DOMAIN = $REALM
    $DOMAIN = $REALM
EOF
    fi
}

# ── Configure machine FQDN ────────────────────────────────────────────────────
# When realm join runs, adcli checks hostname -f and registers service principal
# names (SPNs) in the machine keytab for that name. If hostname -f returns only
# a short name (no domain suffix), adcli only registers short-name SPNs.
# SSSD requests tickets for FQDN SPNs, which then don't exist in the keytab,
# causing GSSAPI authentication to fail. Ensure the FQDN is in /etc/hosts
# before joining so adcli registers the correct SPNs.

configure_fqdn() {
    local hostname
    hostname=$(hostname -s)
    local fqdn="${hostname}.${DOMAIN}"

    if hostname -f 2>/dev/null | grep -qi "\.$DOMAIN"; then
        print_info "Machine FQDN already includes domain: $(hostname -f)"
        return 0
    fi

    print_info "Configuring machine FQDN in /etc/hosts ($fqdn)..."

    if grep -q "^127\.0\.1\.1" /etc/hosts; then
        # Replace the first 127.0.1.1 line to include the FQDN
        sed -i "0,/^127\.0\.1\.1.*/s/^127\.0\.1\.1.*/127.0.1.1    ${fqdn}    ${hostname}/" /etc/hosts
    else
        printf '\n127.0.1.1    %s    %s\n' "$fqdn" "$hostname" >> /etc/hosts
    fi

    print_info "FQDN configured: $(hostname -f)"
}

# ── Verify Active Directory discovery ─────────────────────────────────────────

verify_ad_discovery() {
    print_info "Verifying Active Directory discovery for $DOMAIN..."

    if realm discover --verbose "$DOMAIN"; then
        print_info "Active Directory discovery successful"
        return 0
    fi

    print_error "Unable to discover Active Directory realm: $DOMAIN"
    print_error "Check DNS servers and DNS search domains. Current resolver state:"
    resolvectl status 2>/dev/null || cat /etc/resolv.conf
    return 1
}


# ── SSH handoff information ──────────────────────────────────────────────────
# When the machine is ready for a domain admin to complete the join, print the
# practical SSH details so the technician can copy/paste them into a handoff
# message without hunting for hostname, IP, or the local login user.

print_ssh_handoff() {
    local short_host fqdn ssh_user ip_list
    short_host="$(hostname -s 2>/dev/null || hostname)"
    fqdn="$(hostname -f 2>/dev/null || hostname)"
    ssh_user="${SUDO_USER:-}"

    # Prefer the original sudo caller when available; otherwise fall back to logname/whoami.
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" = "root" ]; then
        ssh_user="$(logname 2>/dev/null || whoami)"
    elif [ -z "$ssh_user" ]; then
        ssh_user="$(logname 2>/dev/null || whoami)"
    fi

    # Show only IPv4 addresses that are likely reachable, excluding loopback/docker/link-local.
    ip_list=$(ip -o -4 addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | grep -Ev '^(127\.|169\.254\.|172\.(1[7-9]|2[0-9]|3[0-1])\.)' \
        | paste -sd' ' -)

    # If the filter removed everything, show all global IPv4 addresses as a fallback.
    if [ -z "$ip_list" ]; then
        ip_list=$(ip -o -4 addr show scope global 2>/dev/null \
            | awk '{print $4}' \
            | cut -d/ -f1 \
            | paste -sd' ' -)
    fi

    echo "  SSH handoff information:"
    echo "    Hostname: $short_host"
    echo "    FQDN:     $fqdn"
    echo "    IP(s):    ${ip_list:-Unable to detect; run: hostname -I}"
    echo "    SSH user: $ssh_user"
    echo ""
    if [ -n "$ip_list" ]; then
        local first_ip
        first_ip=$(echo "$ip_list" | awk '{print $1}')
        echo "  Suggested SSH command:"
        echo "    ssh ${ssh_user}@${first_ip}"
    else
        echo "  Suggested SSH command:"
        echo "    ssh ${ssh_user}@${short_host}"
    fi
    echo ""
}

# ── Join the domain ───────────────────────────────────────────────────────────
# Debian's realmd does not support --stdin for password input. On Debian,
# kinit is used to obtain a Kerberos ticket first; realm join picks it up
# automatically. On Ubuntu, --stdin is supported and used directly.

join_domain() {
    if realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        print_info "Machine is already joined to $DOMAIN — skipping join"
        return 0
    fi

    if ! verify_ad_discovery; then
        exit 1
    fi

    echo ""
    print_info "Pre-join setup is complete."
    echo ""
    echo "  This machine is not yet joined to the domain."
    print_ssh_handoff
    install_domain_admin_join_helper
    save_state "WAITING_FOR_ADMIN"
    echo "  A domain admin must SSH into this machine and run exactly one command:"
    echo ""
    echo "    sudo /usr/local/sbin/dr-domain-admin-join"
    echo ""
    echo "  The helper will allocate the final hostname from Active Directory, rename the workstation, join the domain, and validate with adcli testjoin."
    echo ""
    echo "  Once the helper reports 'Join is OK', re-run this script to complete configuration:"
    echo ""
    echo '    wget -qO- http://ontrack.link/joindomain | sudo bash'
    echo ""
    exit 0
}

# ── Configure PAM for home directory creation ─────────────────────────────────

configure_pam_mkhomedir() {
    if [[ "$OS" == "debian" ]]; then
        print_info "Configuring PAM home directory creation (oddjob)..."
        pam-auth-update --enable mkhomedir
    else
        print_info "Configuring PAM home directory creation (libpam-mkhomedir)..."
        local pam_session="/etc/pam.d/common-session"
        local mkhomedir_line="session required pam_mkhomedir.so skel=/etc/skel/ umask=0077"
        if grep -qF "pam_mkhomedir.so" "$pam_session" 2>/dev/null; then
            print_info "pam_mkhomedir already configured in $pam_session"
        else
            echo "$mkhomedir_line" >> "$pam_session"
            print_info "Added pam_mkhomedir to $pam_session"
        fi
    fi

    # Ubuntu 26.04+ sets use_first_pass on the pam_sss.so line in common-auth.
    # This prevents AD authentication because no prior PAM module provides a
    # password for SSSD to reuse. Remove it so pam_sss.so prompts independently.
    local pam_auth="/etc/pam.d/common-auth"
    if grep -q "pam_sss\.so.*use_first_pass" "$pam_auth" 2>/dev/null; then
        sed -i '/pam_sss\.so/ s/[[:space:]]*use_first_pass//' "$pam_auth"
        print_info "Removed use_first_pass from pam_sss.so in $pam_auth"
    else
        print_info "use_first_pass not set on pam_sss.so in $pam_auth — no change needed"
    fi
}

# ── Allow all domain users to log in ─────────────────────────────────────────

configure_realm_permissions() {
    print_info "Configuring realm login permissions..."
    realm permit --all
}

# ── Configure SSSD settings ───────────────────────────────────────────────────
# Apply settings to sssd.conf that realm join does not set automatically.
# Must run after join_domain since realm join writes sssd.conf.
#
# ad_enable_gc = false: Disables the Active Directory Global Catalog (GC).
# SSSD defaults to using the GC (port 3268) for group lookups, discovered via
# DNS SRV records (_gc._tcp.<site>._sites.<forest>). In some environments those
# SRV records are not resolvable, causing all group name resolution to fail with
# an I/O error. Disabling the GC makes SSSD use regular LDAP (port 389), which
# resolves groups within the domain correctly.


set_sssd_domain_option() {
    local key="$1"
    local value="$2"
    local sssd_conf="/etc/sssd/sssd.conf"

    if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$sssd_conf"; then
        sed -i "s/^[[:space:]]*${key}[[:space:]]*=.*/${key} = ${value}/" "$sssd_conf"
        print_info "Set ${key} = ${value} in $sssd_conf"
    else
        sed -i "/^\[domain\//a\\${key} = ${value}" "$sssd_conf"
        print_info "Added ${key} = ${value} to domain section in $sssd_conf"
    fi
}

set_sssd_global_option() {
    local key="$1"
    local value="$2"
    local sssd_conf="/etc/sssd/sssd.conf"

    if grep -q "^[[:space:]]*${key}[[:space:]]*=" "$sssd_conf"; then
        sed -i "s/^[[:space:]]*${key}[[:space:]]*=.*/${key} = ${value}/" "$sssd_conf"
        print_info "Set ${key} = ${value} in $sssd_conf"
    elif grep -q "^\[sssd\]" "$sssd_conf"; then
        sed -i "/^\[sssd\]/a\\${key} = ${value}" "$sssd_conf"
        print_info "Added ${key} = ${value} to [sssd] in $sssd_conf"
    else
        sed -i "1i[sssd]\n${key} = ${value}\n" "$sssd_conf"
        print_info "Created [sssd] section and added ${key} = ${value} in $sssd_conf"
    fi
}

configure_sssd_settings() {
    local sssd_conf="/etc/sssd/sssd.conf"
    print_info "Applying SSSD settings ($sssd_conf)..."

    if [ ! -f "$sssd_conf" ]; then
        print_warning "$sssd_conf not found — skipping SSSD settings (realm join may not have run)"
        return 0
    fi

    if grep -q "^\s*ad_enable_gc\s*=" "$sssd_conf"; then
        print_info "ad_enable_gc already set in $sssd_conf"
    else
        sed -i "/^\[domain\//a\\ad_enable_gc = false" "$sssd_conf"
        print_info "Set ad_enable_gc = false in $sssd_conf"
    fi

    if grep -q "^\s*krb5_renewable_lifetime\s*=" "$sssd_conf"; then
        print_info "krb5_renewable_lifetime already set in $sssd_conf"
    else
        sed -i "/^\[domain\//a\\krb5_renewable_lifetime = 7d" "$sssd_conf"
        print_info "Set krb5_renewable_lifetime = 7d in $sssd_conf"
    fi

    if grep -q "^\s*krb5_renew_interval\s*=" "$sssd_conf"; then
        print_info "krb5_renew_interval already set in $sssd_conf"
    else
        sed -i "/^\[domain\//a\\krb5_renew_interval = 1h" "$sssd_conf"
        print_info "Set krb5_renew_interval = 1h in $sssd_conf"
    fi


    # Improve workstation login usability. realmd commonly configures domain
    # users to require fully-qualified names. For shared KIT workstations,
    # allow technicians to log in with their normal short username
    # (e.g. martin.campetta) instead of dr.kodr.local\martin.campetta.
    #
    # Testing on Ubuntu 26.04 showed that default_domain_suffix caused SSSD
    # startup trouble in this environment, while use_fully_qualified_names=False
    # was sufficient for short-name logins. Also remove config_file_version if
    # realmd/adcli wrote it, because this SSSD version rejects it during config
    # validation.
    sed -i '/^[[:space:]]*default_domain_suffix[[:space:]]*=/d' "$sssd_conf"
    sed -i '/^[[:space:]]*config_file_version[[:space:]]*=/d' "$sssd_conf"
    set_sssd_domain_option "use_fully_qualified_names" "False"

    # realm join sets access_provider = ad by default, which enforces AD GPO-based
    # access control. If no GPO grants access to this system, all logins are denied.
    # Setting simple keeps the realm permit --all list in effect without relying on GPOs.
    set_sssd_domain_option "access_provider" "simple"

    chmod 600 "$sssd_conf"
    chown root:root "$sssd_conf"
}

# ── Enable SSSD ───────────────────────────────────────────────────────────────
# realm join typically starts SSSD, but explicitly enabling and starting it
# ensures it is running and will survive reboots. If SSSD is not running,
# all domain user lookups and logins fail silently.

enable_sssd() {
    print_info "Enabling SSSD..."
    systemctl enable sssd > /dev/null 2>&1
    systemctl restart sssd
    print_info "SSSD is running"
}


# ── Filesystem path helper ───────────────────────────────────────────────────

ensure_directory_path() {
    local path="$1"

    # Avoid calling mkdir on an existing autofs trigger/mountpoint. Some
    # systems report an error when mkdir touches an already-mounted direct map.
    if [ -e "$path" ]; then
        if [ -d "$path" ]; then
            return 0
        fi
        print_error "$path exists but is not a directory"
        return 1
    fi

    mkdir -p "$path"
}


# ── Ontrack workstation user management ──────────────────────────────────────
# Provides a supported way to add/remove/list domain users after the workstation
# has already been provisioned. This avoids hand-editing /etc/sudoers.d and
# gives future releases one managed place to evolve workstation authorization.

install_dr_workstation_manager() {
    print_info "Installing Ontrack workstation user management command..."

    groupadd -f "$DR_WORKSTATION_USERS_GROUP"
    groupadd -f "$DR_WORKSTATION_ADMINS_GROUP"

    local sudoers_file="/etc/sudoers.d/zz-dr_workstation_users"
    cat > "$sudoers_file" << EOF
# Managed by Ontrack Recovery Workstation Provisioner
# Members of $DR_WORKSTATION_ADMINS_GROUP are workstation administrators.
%$DR_WORKSTATION_ADMINS_GROUP ALL=(ALL:ALL) ALL

# Every authenticated DR domain user may mount the standard Tool Server.
# SSSD is configured with use_fully_qualified_names=False, so the AD group is
# exposed as the short group name "domain users". The escaped space is required.
%domain\ users ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools

# Locally managed workstation users may also run the remaining managed helpers.
%$DR_WORKSTATION_USERS_GROUP ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools
%$DR_WORKSTATION_USERS_GROUP ALL=(root) NOPASSWD: /usr/local/sbin/dr-post-mount-provision
%$DR_WORKSTATION_USERS_GROUP ALL=(root) NOPASSWD: /usr/local/sbin/dr-launch-kit
EOF
    chmod 440 "$sudoers_file"
    chown root:root "$sudoers_file"

    if ! visudo -cf "$sudoers_file" >/dev/null 2>&1; then
        print_warning "Workstation user-management sudoers validation failed; removing $sudoers_file"
        rm -f "$sudoers_file"
        return 1
    fi

    cat > /usr/local/sbin/dr-workstation << 'EOF'
#!/bin/bash
set -euo pipefail

DOMAIN="dr.kodr.local"
USERS_GROUP="dr-workstation-users"
ADMINS_GROUP="dr-workstation-admins"

usage() {
    cat <<USAGE
Ontrack Recovery Workstation user management

Usage:
  sudo dr-workstation add-user <domain-user>
  sudo dr-workstation remove-user <domain-user>
  sudo dr-workstation list-users
  sudo dr-workstation status
  sudo dr-workstation verify

Examples:
  sudo dr-workstation add-user jsmith
  sudo dr-workstation add-user jsmith@dr.kodr.local
  sudo dr-workstation remove-user jsmith

add-user grants:
  - normal workstation sudo rights
  - passwordless access to managed workstation helpers:
      /usr/local/bin/mount-kit-tools
      /usr/local/sbin/dr-post-mount-provision
      /usr/local/sbin/dr-launch-kit

Users should log out and back in after being added or removed.
USAGE
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This command must be run with sudo." >&2
        exit 1
    fi
}

normalize_user() {
    local user="${1:-}"
    user="${user#*\\}"
    user="${user%%@*}"
    user="${user// /}"
    if [ -z "$user" ]; then
        echo "Missing username." >&2
        exit 1
    fi
    echo "$user"
}

safe_name_for_user() {
    local user="$1"
    echo "${user//./_}"
}

legacy_sudoers_file_for_user() {
    local user="$1"
    local safe
    safe="$(safe_name_for_user "$user")"
    echo "/etc/sudoers.d/${safe}_domain_sudo"
}

ensure_groups() {
    groupadd -f "$USERS_GROUP"
    groupadd -f "$ADMINS_GROUP"
}

remove_legacy_user_sudoers() {
    local user="$1"
    local legacy
    legacy="$(legacy_sudoers_file_for_user "$user")"
    if [ -f "$legacy" ]; then
        rm -f "$legacy"
        echo "Removed legacy per-user sudoers file: $legacy"
    fi
}

add_user() {
    require_root
    local user
    user="$(normalize_user "${1:-}")"
    ensure_groups

    if ! getent passwd "$user" >/dev/null 2>&1; then
        echo "Warning: '$user' is not currently resolvable through NSS/SSSD." >&2
        echo "The workstation may need working domain connectivity before this user can be added." >&2
        exit 1
    fi

    gpasswd -a "$user" "$USERS_GROUP" >/dev/null
    gpasswd -a "$user" "$ADMINS_GROUP" >/dev/null
    remove_legacy_user_sudoers "$user"

    echo "Added workstation user: $user"
    echo "Granted groups: $USERS_GROUP, $ADMINS_GROUP"
    echo "The user should log out and back in before testing sudo/KIT access."
}

remove_user() {
    require_root
    local user
    user="$(normalize_user "${1:-}")"
    ensure_groups

    gpasswd -d "$user" "$USERS_GROUP" >/dev/null 2>&1 || true
    gpasswd -d "$user" "$ADMINS_GROUP" >/dev/null 2>&1 || true
    remove_legacy_user_sudoers "$user"

    echo "Removed workstation user: $user"
    echo "The user should log out and back in for group membership changes to fully clear."
}

list_group_members() {
    local group="$1"
    getent group "$group" | awk -F: '{print $4}' | tr ',' '\n' | sed '/^$/d' | sort
}

list_users() {
    echo "Workstation users ($USERS_GROUP):"
    list_group_members "$USERS_GROUP" | sed 's/^/  /' || true
    echo ""
    echo "Workstation administrators ($ADMINS_GROUP):"
    list_group_members "$ADMINS_GROUP" | sed 's/^/  /' || true
}

status() {
    echo "Ontrack Recovery Workstation"
    echo "Domain: $DOMAIN"
    echo "User group: $USERS_GROUP"
    echo "Admin group: $ADMINS_GROUP"
    echo ""
    list_users
    echo ""
    echo "Managed sudoers:"
    ls -l /etc/sudoers.d/zz-dr_workstation_users 2>/dev/null || echo "  missing"
}

verify() {
    local failed=0

    echo "Ontrack Recovery Workstation verification"
    echo ""

    if realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        echo "[OK] Realm membership is configured"
    else
        echo "[FAIL] Realm membership is not configured"
        failed=1
    fi

    if command -v sssctl >/dev/null 2>&1 && sssctl domain-status "$DOMAIN" 2>/dev/null | grep -q '^Online status: Online'; then
        echo "[OK] SSSD domain is online"
    else
        echo "[FAIL] SSSD domain is offline or unavailable"
        failed=1
    fi

    if host -t SRV "_kerberos._tcp.$DOMAIN" >/dev/null 2>&1; then
        echo "[OK] Kerberos DNS discovery works"
    else
        echo "[FAIL] Kerberos DNS discovery failed"
        failed=1
    fi

    if adcli testjoin -D "$DOMAIN" >/dev/null 2>&1; then
        echo "[OK] Machine account trust is valid"
    else
        echo "[FAIL] Machine account trust could not be validated"
        failed=1
    fi

    if visudo -cf /etc/sudoers.d/zz-dr_workstation_users >/dev/null 2>&1; then
        echo "[OK] Workstation sudo policy is valid"
    else
        echo "[FAIL] Workstation sudo policy is missing or invalid"
        failed=1
    fi

    return "$failed"
}

case "${1:-}" in
    add-user)
        add_user "${2:-}"
        ;;
    remove-user)
        remove_user "${2:-}"
        ;;
    list-users)
        list_users
        ;;
    status)
        status
        ;;
    verify)
        require_root
        verify
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
EOF
    chmod 755 /usr/local/sbin/dr-workstation
    chown root:root /usr/local/sbin/dr-workstation

    print_info "Installed: /usr/local/sbin/dr-workstation"
    print_info "Manage users with: sudo dr-workstation add-user <username>"
}

# ── Configure autofs for DRIP image share access ─────────────────────────────
# DRIP image fragment files are stored on Windows file servers. The DRIP REST
# API returns file paths with /smb/<server>/<share>/... as the mount prefix
# (e.g. /smb/dr-ep-drip12/Images/2026-06/...). autofs must be configured for
# this /smb prefix so those paths resolve transparently at runtime.
#
# A /net prefix is also configured for general ad-hoc share browsing, but the
# /smb prefix is what IOLib actually uses during imaging.
#
# How it works:
#   1. The executable map /etc/auto.net.cifs is called by autofs with the
#      server hostname when any path under /smb/<server>/ or /net/<server>/
#      is accessed.
#   2. The script creates a per-server wildcard map file under /etc/autofs.d/
#      and returns a nested autofs (-fstype=autofs) mount for that server.
#   3. The nested autofs uses the wildcard map to mount any share on the server
#      on demand using the accessing user's Kerberos ticket (cruid=${UID}).
#   4. No share enumeration or smbclient is required — any share is accessible
#      automatically once the server is first accessed.
#
# The krb5_ccname_template setting in sssd.conf ensures the credential cache
# is discoverable by the CIFS kernel module on systems that do not use the
# kernel keyring (belt-and-suspenders; the kernel keyring is used automatically
# on modern systems regardless).


# ── Post-mount provisioning helper ───────────────────────────────────────────
install_post_mount_provision_helper() {
    print_info "Installing post-mount provisioning helper for KIT installer and workstation branding..."

    # Install/repair the canonical root KIT launch helper now, not only after
    # post-mount provisioning runs. The desktop shortcut and sudoers rule both
    # target this one helper. It is intentionally narrow: it only cd's into the
    # KIT runtime directory and launches KIT.sh.
    local kit_runtime_dir
    local escaped_kit_runtime_dir
    kit_runtime_dir="$(dirname "$KIT_INSTALLER_PATH")"

    # Generate this helper with a quoted heredoc so runtime variables such as
    # $LOG, $KIT_DIR, ${1:-}, and $? are preserved until dr-launch-kit runs.
    cat > /usr/local/sbin/dr-launch-kit << 'EOF'
#!/bin/bash
set -u

LOG="/var/log/dr-launch-kit.log"
KIT_DIR="__KIT_RUNTIME_DIR__"
KIT_SCRIPT="./KIT.sh"

if [ "${1:-}" = "--sudo-self-test" ]; then
    exit 0
fi

{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launch requested by: ${SUDO_USER:-unknown}"
    echo "KIT_DIR=$KIT_DIR"
    echo "KIT_SCRIPT=$KIT_DIR/$KIT_SCRIPT"
} >> "$LOG" 2>/dev/null || true

if [ ! -d "$KIT_DIR" ]; then
    echo "KIT directory not found: $KIT_DIR" | tee -a "$LOG" >&2
    echo "Verify Tool Server is mounted at /mnt/x, then try again." >&2
    exit 1
fi

if [ ! -f "$KIT_DIR/$KIT_SCRIPT" ]; then
    echo "KIT script not found: $KIT_DIR/$KIT_SCRIPT" | tee -a "$LOG" >&2
    echo "Verify Tool Server is mounted at /mnt/x, then try again." >&2
    exit 1
fi

cd "$KIT_DIR" || exit 1

# Intentionally do NOT redirect stdout/stderr. KIT behaves correctly when
# launched like the manual known-good command:
#   cd /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64
#   sudo bash ./KIT.sh
bash "$KIT_SCRIPT"
status=$?

echo "[$(date '+%Y-%m-%d %H:%M:%S')] KIT exited with status: $status" >> "$LOG" 2>/dev/null || true
exit "$status"
EOF
    escaped_kit_runtime_dir="$(printf '%s
' "$kit_runtime_dir" | sed 's/[#&]/\&/g')"
    sed -i "s#__KIT_RUNTIME_DIR__#$escaped_kit_runtime_dir#g" /usr/local/sbin/dr-launch-kit
    chmod 755 /usr/local/sbin/dr-launch-kit
    chown root:root /usr/local/sbin/dr-launch-kit

    cat > /usr/local/sbin/dr-post-mount-provision << EOF
#!/bin/bash
set -euo pipefail

KIT_INSTALLER_PATH="${KIT_INSTALLER_PATH}"
BRAND_WALLPAPER_SOURCE="${BRAND_WALLPAPER_SOURCE}"
BRAND_WALLPAPER_DEST="${BRAND_WALLPAPER_DEST}"
STATE_DIR="${STATE_DIR}"
STATE_FILE="${STATE_FILE}"
OFFICE_CODE="${OFFICE_CODE:-}"
LOG_FILE="/var/log/dr-post-mount-provision.log"

log() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" | tee -a "\$LOG_FILE"
}

state_mark() {
    mkdir -p "\$STATE_DIR"
    touch "\$STATE_DIR/\$1"
}

state_has() {
    [ -f "\$STATE_DIR/\$1" ]
}

install_root_kit_launcher_helper() {
    local kit_dir
    kit_dir="\$(dirname "\$KIT_INSTALLER_PATH")"

    # Quote the nested heredoc so variables like $LOG and $1 are not
    # expanded by dr-post-mount-provision while it is generating the helper.
    cat > /usr/local/sbin/dr-launch-kit << 'EOF2'
#!/bin/bash
set -u

LOG="/var/log/dr-launch-kit.log"
KIT_DIR="__KIT_RUNTIME_DIR__"
KIT_SCRIPT="./KIT.sh"

mkdir -p "\$(dirname "\$LOG")" 2>/dev/null || true
touch "\$LOG" 2>/dev/null || true
chmod 644 "\$LOG" 2>/dev/null || true

{
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Launch requested by: \${SUDO_USER:-unknown}"
    echo "KIT_DIR=\$KIT_DIR"
    echo "KIT_SCRIPT=\$KIT_DIR/KIT.sh"
} >> "\$LOG" 2>/dev/null || true

if [ "\${1:-}" = "--sudo-self-test" ]; then
    exit 0
fi

if [ ! -d "\$KIT_DIR" ]; then
    echo "KIT directory not found: \$KIT_DIR" | tee -a "\$LOG" >&2
    echo "Verify Tool Server is mounted at /mnt/x, then try again." >&2
    exit 1
fi

if [ ! -f "\$KIT_DIR/KIT.sh" ]; then
    echo "KIT script not found: \$KIT_DIR/KIT.sh" | tee -a "\$LOG" >&2
    echo "Verify Tool Server is mounted at /mnt/x, then try again." >&2
    exit 1
fi

cd "\$KIT_DIR" || exit 1

# Intentionally do NOT redirect stdout/stderr. KIT behaves correctly when
# launched like the manual known-good command:
#   cd /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64
#   sudo bash ./KIT.sh
bash "\$KIT_SCRIPT"
status=\$?

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] KIT exited with status: \$status" >> "\$LOG" 2>/dev/null || true
exit "\$status"
EOF2
    escaped_kit_dir="\$(printf '%s\n' "\$kit_dir" | sed 's/[#&]/\\&/g')"
    sed -i "s#__KIT_RUNTIME_DIR__#\$escaped_kit_dir#g" /usr/local/sbin/dr-launch-kit

    chmod 755 /usr/local/sbin/dr-launch-kit
    chown root:root /usr/local/sbin/dr-launch-kit
}

if [ "\${1:-}" = "--sudo-self-test" ]; then
    exit 0
fi

if [ "\$(id -u)" -ne 0 ]; then
    exec sudo -n /usr/local/sbin/dr-post-mount-provision "\$@"
fi

mkdir -p "\$STATE_DIR"
touch "\$LOG_FILE"
chmod 644 "\$LOG_FILE" 2>/dev/null || true

# The desktop/autostart path reaches this helper through sudo -n, which does
# not preserve the technician-phase shell variables. Rehydrate the saved
# installer state here so KIT automation still knows the selected office code.
if [ -z "\${OFFICE_CODE:-}" ] && [ -f "\$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "\$STATE_FILE" || true
    OFFICE_CODE="\${OFFICE_CODE:-}"
fi

if [ -n "\${OFFICE_CODE:-}" ]; then
    log "Using office code for post-mount provisioning: \$OFFICE_CODE"
else
    log "No saved office code found in \$STATE_FILE."
fi

if ! mountpoint -q /mnt/x; then
    log "DR Tools share is not mounted at /mnt/x; skipping post-mount provisioning."
    exit 0
fi

install_root_kit_launcher_helper

install_kit() {
    local kit_dir
    local kit_script
    local rc

    if state_has "KIT_INSTALL_COMPLETE"; then
        log "KIT installer already marked complete; skipping."
        return 0
    fi

    if [ -z "\${OFFICE_CODE:-}" ]; then
        log "No office code is available for KIT installer automation."
        log "Cannot run KIT installer because it requires an office code such as EP1."
        exit 1
    fi

    if [ ! -f "\$KIT_INSTALLER_PATH" ]; then
        log "KIT installer not found: \$KIT_INSTALLER_PATH"
        log "Skipping KIT install; rerun after the installer is available on /mnt/x."
        return 0
    fi

    kit_dir="\$(dirname "\$KIT_INSTALLER_PATH")"
    kit_script="\$(basename "\$KIT_INSTALLER_PATH")"

    log "Starting KIT installer."
    log "Office code: \$OFFICE_CODE"
    log "Installer: \$KIT_INSTALLER_PATH"
    log "Working directory: \$kit_dir"

    if (
        cd "\$kit_dir"
        printf '%s\n' "\$OFFICE_CODE" | bash "./\$kit_script"
    ) >> "\$LOG_FILE" 2>&1; then
        state_mark "KIT_INSTALL_COMPLETE"
        log "KIT installer completed successfully."
    else
        rc=\$?
        log "KIT installer failed with exit code \$rc."
        exit "\$rc"
    fi
}

install_kit_desktop_shortcut_for_user() {
    local user="\$1"
    local home="\$2"
    local uid="\$3"
    local kit_dir
    local kit_launcher
    local wrapper
    local desktop_file
    local desktop_copy

    [ -d "\$home" ] || return 0
    kit_dir="\$(dirname "\$KIT_INSTALLER_PATH")"
    kit_launcher="\$kit_dir/KIT.sh"

    if [ ! -f "\$kit_launcher" ]; then
        log "KIT launcher not found for \$user at \$kit_launcher; shortcut not installed."
        return 0
    fi

    mkdir -p "\$home/Desktop" "\$home/.local/share/applications" "\$home/.local/bin"

    # The vendor KIT installer may create a desktop file that points back at
    # KIT-installer-modified.sh. Replace/repair it with a deterministic launcher
    # that always starts the real runtime entrypoint: KIT.sh.
    wrapper="\$home/.local/bin/dr-launch-kit"
    cat > "\$wrapper" << 'EOF2'
#!/bin/bash
set +e

echo "Launching KIT..."
sudo -n /usr/local/sbin/dr-launch-kit "\$@"
rc=\$?

if [ -z "\${rc:-}" ]; then
    rc=1
fi

if [ "\$rc" -ne 0 ]; then
    echo
    echo "KIT launch failed with exit code \$rc."
    echo "See /var/log/dr-launch-kit.log for details."
    echo
    read -r -p "Press Enter to close..." _
fi

exit "\$rc"
EOF2
    chmod 755 "\$wrapper"

    desktop_file="\$home/.local/share/applications/dr-kit.desktop"
    desktop_copy="\$home/Desktop/KIT.desktop"

    cat > "\$desktop_file" << EOF2
[Desktop Entry]
Version=1.0
Name=KIT
Comment=Launch KIT imaging tools
Exec=\$wrapper
Icon=drive-harddisk
Terminal=true
Type=Application
Categories=Utility;System;
StartupNotify=true
EOF2

    chmod 755 "\$desktop_file"
    cp -f "\$desktop_file" "\$desktop_copy"
    chmod 755 "\$desktop_copy"

    chown -R "\$uid:\$uid" "\$home/Desktop" "\$home/.local" 2>/dev/null || chown -R "\$user:\$user" "\$home/Desktop" "\$home/.local" 2>/dev/null || true

    # GNOME/Nautilus marks downloaded or newly-created desktop files as
    # untrusted until the user enables launching. Best effort: pre-trust the
    # desktop entry when gio/gvfs metadata is available in the login session.
    # This may be skipped on non-GNOME desktops without breaking the launcher.
    if command -v gio >/dev/null 2>&1; then
        sudo -u "\$user" gio set "\$desktop_copy" metadata::trusted true >/dev/null 2>&1 || true
        sudo -u "\$user" gio info "\$desktop_copy" >/dev/null 2>&1 || true
    fi

    if grep -q 'KIT-installer-modified.sh' "\$desktop_copy" 2>/dev/null; then
        log "WARNING: repaired KIT shortcut for \$user still references installer unexpectedly."
    else
        log "Installed trusted KIT desktop shortcut for \$user at \$desktop_copy -> \$kit_launcher"
    fi
}

install_kit_desktop_shortcuts() {
    if [ ! -f "\$(dirname "\$KIT_INSTALLER_PATH")/KIT.sh" ]; then
        log "KIT launcher not found at \$(dirname "\$KIT_INSTALLER_PATH")/KIT.sh; desktop shortcut not installed."
        return 0
    fi

    while IFS=: read -r user _ uid gid _ home shell; do
        [ -z "\$home" ] && continue
        [ "\$home" = "/" ] && continue
        [ "\$uid" -lt 1000 ] 2>/dev/null && continue
        install_kit_desktop_shortcut_for_user "\$user" "\$home" "\$uid"
    done < <(getent passwd)

    state_mark "KIT_DESKTOP_SHORTCUTS_CONFIGURED"
}

find_wallpaper_source() {
    if [ -n "\$BRAND_WALLPAPER_SOURCE" ] && [ -f "\$BRAND_WALLPAPER_SOURCE" ]; then
        echo "\$BRAND_WALLPAPER_SOURCE"
        return 0
    fi

    for candidate in \
        /mnt/x/CRtools/Frozen/Branding/Wallpaper/1080p_ontrackwallpaper.jpg \
        /mnt/x/DRTools/Branding/Wallpaper/1080p_ontrackwallpaper.jpg \
        /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/company-wallpaper.png \
        /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/company-wallpaper.jpg \
        /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/ontrack-wallpaper.png \
        /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/ontrack-wallpaper.jpg \
        /mnt/x/DRTools/Wallpapers/company-wallpaper.png \
        /mnt/x/DRTools/Wallpapers/company-wallpaper.jpg \
        /mnt/x/DRTools/Wallpapers/ontrack-wallpaper.png \
        /mnt/x/DRTools/Wallpapers/ontrack-wallpaper.jpg \
        /mnt/x/DRTools/Branding/company-wallpaper.png \
        /mnt/x/DRTools/Branding/company-wallpaper.jpg \
        /mnt/x/DRTools/Branding/ontrack-wallpaper.png \
        /mnt/x/DRTools/Branding/ontrack-wallpaper.jpg; do
        if [ -f "\$candidate" ]; then
            echo "\$candidate"
            return 0
        fi
    done

    return 1
}

configure_wallpaper_for_user() {
    local user="\$1"
    local home="\$2"
    local uid="\$3"
    local wallpaper_uri="file://\$4"

    [ -d "\$home" ] || return 0

    mkdir -p "\$home/.config/autostart" "\$home/.local/bin"

    cat > "\$home/.local/bin/dr-apply-company-wallpaper" << EOF2
#!/bin/bash
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.background picture-uri '${wallpaper_uri}' 2>/dev/null || true
    gsettings set org.gnome.desktop.background picture-uri-dark '${wallpaper_uri}' 2>/dev/null || true
    gsettings set org.gnome.desktop.background picture-options 'zoom' 2>/dev/null || true
fi
EOF2
    chmod +x "\$home/.local/bin/dr-apply-company-wallpaper"

    cat > "\$home/.config/autostart/dr-company-wallpaper.desktop" << EOF2
[Desktop Entry]
Type=Application
Name=Apply Company Wallpaper
Exec=\$home/.local/bin/dr-apply-company-wallpaper
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF2

    chown -R "\$uid:\$uid" "\$home/.config" "\$home/.local" 2>/dev/null || chown -R "\$user:\$user" "\$home/.config" "\$home/.local" 2>/dev/null || true
}

install_wallpaper() {
    local source
    local ext
    local dest

    if ! source="\$(find_wallpaper_source)"; then
        log "No company wallpaper source found on /mnt/x; branding wallpaper not changed."
        log "Set BRAND_WALLPAPER_SOURCE or place wallpaper at /mnt/x/CRtools/Frozen/Branding/Wallpaper/1080p_ontrackwallpaper.jpg."
        return 0
    fi

    ext="\${source##*.}"
    dest="\${BRAND_WALLPAPER_DEST}.\${ext}"
    install -D -m 0644 "\$source" "\$dest"
    log "Installed company wallpaper from \$source to \$dest"

    # System defaults for GNOME/Unity-style desktops. Existing users may need an
    # active user-session gsettings write, handled by the per-user autostart below.
    mkdir -p /etc/dconf/db/local.d
    cat > /etc/dconf/db/local.d/20-dr-company-wallpaper << EOF2
[org/gnome/desktop/background]
picture-uri='file://\$dest'
picture-uri-dark='file://\$dest'
picture-options='zoom'
EOF2
    dconf update >/dev/null 2>&1 || true

    while IFS=: read -r user _ uid gid _ home shell; do
        [ -z "\$home" ] && continue
        [ "\$home" = "/" ] && continue
        [ "\$uid" -lt 1000 ] 2>/dev/null && continue
        configure_wallpaper_for_user "\$user" "\$home" "\$uid" "\$dest"
    done < <(getent passwd)

    state_mark "COMPANY_WALLPAPER_CONFIGURED"
}

install_kit
install_kit_desktop_shortcuts
install_wallpaper
exit 0
EOF

    chmod 755 /usr/local/sbin/dr-post-mount-provision
    chown root:root /usr/local/sbin/dr-post-mount-provision

    # User-session desktop provisioning. GNOME's Allow Launching trust bit is
    # GVFS metadata stored in the logged-in user's session, so root cannot
    # reliably stamp it for another user. This helper is intentionally
    # non-privileged and is run by the desktop mount/autostart path as the
    # logged-in user. It creates/repairs launchers and marks them trusted.
    cat > /usr/local/bin/dr-user-desktop-provision << EOF
#!/bin/bash
set -euo pipefail

WORKSPACE_VERSION="1.1"
KIT_INSTALLER_PATH="${KIT_INSTALLER_PATH}"
LOG_FILE="\${HOME:-/tmp}/.dr-user-session-init.log"
ONTRACK_LOG_DIR="\${HOME:-/tmp}/.local/share/ontrack/logs"

log_user() {
    mkdir -p "\$(dirname "\$LOG_FILE")" "\$ONTRACK_LOG_DIR" 2>/dev/null || true
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*" >> "\$LOG_FILE" 2>/dev/null || true
}

trust_desktop_file() {
    local file="\$1"
    [ -f "\$file" ] || return 0
    chmod 755 "\$file" 2>/dev/null || true
    if command -v gio >/dev/null 2>&1; then
        gio set "\$file" metadata::trusted true >/dev/null 2>&1 || true
    fi
}

write_folder_launcher() {
    local file="\$1" name="\$2" target="\$3" comment="\$4" icon="\${5:-folder}"
    cat > "\$file" << EOF2
[Desktop Entry]
Version=1.0
Name=\$name
Comment=\$comment
Exec=xdg-open "\$target"
Icon=\$icon
Terminal=false
Type=Application
Categories=Utility;
StartupNotify=true
EOF2
    trust_desktop_file "\$file"
}

write_command_launcher() {
    local file="\$1" name="\$2" command="\$3" comment="\$4" icon="\${5:-utilities-terminal}" terminal="\${6:-true}"
    cat > "\$file" << EOF2
[Desktop Entry]
Version=1.0
Name=\$name
Comment=\$comment
Exec=\$command
Icon=\$icon
Terminal=\$terminal
Type=Application
Categories=Utility;System;
StartupNotify=true
EOF2
    trust_desktop_file "\$file"
}

apply_company_wallpaper_now() {
    local wallpaper="" candidate expected actual
    for candidate in /usr/share/backgrounds/dr-company-wallpaper.jpg /usr/share/backgrounds/dr-company-wallpaper.jpeg /usr/share/backgrounds/dr-company-wallpaper.png; do
        [ -f "\$candidate" ] && wallpaper="\$candidate" && break
    done
    [ -n "\$wallpaper" ] || return 0
    expected="file://\$wallpaper"
    if command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.background picture-uri "\$expected" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-uri-dark "\$expected" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-options 'zoom' 2>/dev/null || true
        actual="\$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null | tr -d "'")"
        [ "\$actual" = "\$expected" ] && log_user "Wallpaper verified: \$wallpaper" || log_user "Wallpaper apply attempted; readback: \$actual"
    fi
}

repair_bookmarks() {
    local bookmark_file line notes_uri
    notes_uri="file://\$(printf '%s' "\$user_home/Recovery Notes" | sed 's/ /%20/g')"
    for bookmark_file in "\$user_home/.config/gtk-3.0/bookmarks" "\$user_home/.config/gtk-4.0/bookmarks"; do
        mkdir -p "\$(dirname "\$bookmark_file")"; touch "\$bookmark_file"
        # Remove earlier workspace labels so Nautilus sidebar stays aligned
        # with established engineering vocabulary.
        grep -v -F "file:///mnt/x/DRTools Logical Recovery Tools" "\$bookmark_file" > "\${bookmark_file}.tmp" 2>/dev/null || true
        mv "\${bookmark_file}.tmp" "\$bookmark_file" 2>/dev/null || true
        grep -v -F "file:///mnt/x/CRTools Physical Recovery Tools" "\$bookmark_file" > "\${bookmark_file}.tmp" 2>/dev/null || true
        mv "\${bookmark_file}.tmp" "\$bookmark_file" 2>/dev/null || true
        for line in \
            "file:///mnt/x Tool Server" \
            "file:///mnt/x/DRTools DRTools" \
            "file:///mnt/x/CRTools CRTools" \
            "file:///mnt/x/Firmware Firmware" \
            "file:///mnt/x/Audit Audit Resources" \
            "\$notes_uri Recovery Notes"; do
            grep -Fxq "\$line" "\$bookmark_file" 2>/dev/null || echo "\$line" >> "\$bookmark_file"
        done
    done
}

repair_aliases() {
    local bashrc="\$user_home/.bashrc"
    touch "\$bashrc"
    grep -q '# BEGIN Ontrack Recovery Workstation aliases' "\$bashrc" 2>/dev/null && return 0
    cat >> "\$bashrc" << 'EOF2'

# BEGIN Ontrack Recovery Workstation aliases
alias toolserver='cd /mnt/x'
alias drtools='cd /mnt/x/DRTools'
alias crtools='cd /mnt/x/CRTools'
alias firmware='cd /mnt/x/Firmware'
alias audit='cd /mnt/x/Audit'
alias recoverynotes='cd "$HOME/Recovery Notes"'
alias drlogs='cd "$HOME/.local/share/ontrack/logs"'
alias kit='sudo -n /usr/local/sbin/dr-launch-kit'
# END Ontrack Recovery Workstation aliases
EOF2
}

repair_dock_favorites() {
    command -v gsettings >/dev/null 2>&1 || return 0
    gsettings set org.gnome.shell favorite-apps "['org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop', 'firefox.desktop', 'dr-kit.desktop', 'org.gnome.Settings.desktop']" >/dev/null 2>&1 || true
}

show_workspace_ready_once() {
    local marker="\$user_home/.local/share/ontrack/workspace-welcome-v\$WORKSPACE_VERSION"
    [ -f "\$marker" ] && return 0
    mkdir -p "\$(dirname "\$marker")"
    command -v notify-send >/dev/null 2>&1 && notify-send "Ontrack Recovery Workstation Ready" "Tool Server connected. Workspace verified." >/dev/null 2>&1 || true
    touch "\$marker" 2>/dev/null || true
}

user_name="\$(id -un)"
user_home="\${HOME:-}"
if [ -z "\$user_home" ] || [ ! -d "\$user_home" ]; then
    user_home="\$(getent passwd "\$user_name" | awk -F: '{print \$6}')"
fi
[ -n "\$user_home" ] && [ -d "\$user_home" ] || exit 0
[ "\$(id -u)" -eq 0 ] && exit 0

desktop_dir="\$user_home/Desktop"
applications_dir="\$user_home/.local/share/applications"
bin_dir="\$user_home/.local/bin"
resources_dir="\$desktop_dir/Ontrack Resources"
notes_dir="\$user_home/Recovery Notes"
mkdir -p "\$desktop_dir" "\$applications_dir" "\$bin_dir" "\$resources_dir" "\$notes_dir" "\$ONTRACK_LOG_DIR"

# Keep the top-level desktop intentionally sparse. Manual mount lives inside Ontrack Resources.
rm -f "\$desktop_dir/Mount DR Tools.desktop" 2>/dev/null || true
rm -f "\$desktop_dir/Home.desktop" "\$desktop_dir/home.desktop" "\$desktop_dir/Computer.desktop" "\$desktop_dir/Trash.desktop" 2>/dev/null || true

# Hide GNOME desktop special icons where the extension/schema supports it.
if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.shell.extensions.ding show-home false >/dev/null 2>&1 || true
    gsettings set org.gnome.shell.extensions.ding show-trash false >/dev/null 2>&1 || true
    gsettings set org.gnome.desktop.background show-desktop-icons false >/dev/null 2>&1 || true
fi

wrapper="\$bin_dir/dr-launch-kit"
cat > "\$wrapper" << 'EOF2'
#!/bin/bash
set +e

echo "Launching KIT..."
sudo -n /usr/local/sbin/dr-launch-kit "\$@"
rc=\$?

if [ -z "\${rc:-}" ]; then
    rc=1
fi

if [ "\$rc" -ne 0 ]; then
    echo
    echo "KIT launch failed with exit code \$rc."
    echo "See /var/log/dr-launch-kit.log for details."
    echo
    read -r -p "Press Enter to close..." _
fi

exit "\$rc"
EOF2
chmod 755 "\$wrapper"

kit_app="\$applications_dir/dr-kit.desktop"
kit_desktop="\$desktop_dir/KIT.desktop"
cat > "\$kit_app" << EOF2
[Desktop Entry]
Version=1.0
Name=KIT
Comment=Launch KIT imaging tools
Exec=\$wrapper
Icon=drive-harddisk
Terminal=true
Type=Application
Categories=Utility;System;
StartupNotify=true
EOF2
chmod 755 "\$kit_app"; cp -f "\$kit_app" "\$kit_desktop"; trust_desktop_file "\$kit_desktop"; trust_desktop_file "\$kit_app"

# Nautilus treats .desktop files inside folders as text files on many GNOME
# builds. For navigation resources, use real folders/symlinks so double-clicking
# behaves like Windows Explorer. Command launchers remain on the Desktop or are
# exposed as terminal aliases/README guidance instead of as .desktop files in
# this folder.
for stale in     "\$resources_dir/Tool Server.desktop"     "\$resources_dir/Logical Recovery Tools.desktop"     "\$resources_dir/Physical Recovery Tools.desktop"     "\$resources_dir/DRTools.desktop"     "\$resources_dir/CRTools.desktop"     "\$resources_dir/Firmware.desktop"     "\$resources_dir/Audit Resources.desktop"     "\$resources_dir/Recovery Notes.desktop"     "\$resources_dir/Engineering Logs.desktop"     "\$resources_dir/Engineering Logs"     "\$resources_dir/Mount Tool Server.desktop"     "\$resources_dir/Repair Workspace.desktop"     "\$resources_dir/Workstation Diagnostics.desktop"; do
    rm -f "\$stale" 2>/dev/null || true
done

link_resource() {
    local name="\$1" target="\$2"
    local link="\$resources_dir/\$name"
    rm -rf "\$link" 2>/dev/null || true
    ln -s "\$target" "\$link" 2>/dev/null || true
}

link_resource "Tool Server" "/mnt/x"
rm -rf "$resources_dir/Logical Recovery Tools" 2>/dev/null || true
link_resource "DRTools" "/mnt/x/DRTools"
rm -rf "$resources_dir/Physical Recovery Tools" 2>/dev/null || true
link_resource "CRTools" "/mnt/x/CRTools"
link_resource "Firmware" "/mnt/x/Firmware"
link_resource "Audit Resources" "/mnt/x/Audit"
link_resource "Recovery Notes" "\$notes_dir"
cat > "\$resources_dir/README - Start Here.txt" << EOF2
Ontrack Recovery Workstation
============================

KIT launches the primary imaging/recovery application.

Tool Server opens the shared Ontrack tool server. Internally it is mounted at /mnt/x, but you can think of it like a Windows network drive.

DRTools contains lab tools for imaging, filesystem parsing, logical recovery, metadata analysis, and data reconstruction workflows.

CRTools contains clean-room tools for storage-device preparation, system/service-area work, firmware-related work, and device operations needed before imaging.

Firmware opens the shared firmware repository.
Audit Resources opens shared audit resources.
Recovery Notes is your local notes folder.

Logs are kept quietly under ~/.local/share/ontrack/logs and are intended for diagnostics, not daily workflow.

Repair Workspace recreates launchers, bookmarks, wallpaper, and shortcuts if anything is accidentally changed.
Run it from Terminal with:
  dr-user-desktop-provision --repair

If the Tool Server is not connected, run:
  mount-kit-tools

For workstation diagnostics, run:
  hostnamectl
  realm list
  findmnt /mnt/x
EOF2

repair_bookmarks
repair_aliases
repair_dock_favorites
apply_company_wallpaper_now
show_workspace_ready_once
log_user "Ontrack workspace v\$WORKSPACE_VERSION repaired successfully."
exit 0
EOF
    chmod 755 /usr/local/bin/dr-user-desktop-provision
    chown root:root /usr/local/bin/dr-user-desktop-provision

    # Permit the selected domain user to run only the post-mount provisioning
    # helper without a password. It must sort late for the same reason as the
    # mount helper sudoers file.
    local provision_user="${DOMAIN_SUDO_USER:-}"
    rm -f /etc/sudoers.d/dr_post_mount_provision /etc/sudoers.d/99-dr_post_mount_provision
    if [ -n "$provision_user" ] && [ "$provision_user" != "root" ]; then
        local provision_sudoers_file="/etc/sudoers.d/zz-dr_post_mount_provision"
        cat > "$provision_sudoers_file" << EOF
# Managed by DR Domain Join
$provision_user ALL=(root) NOPASSWD: /usr/local/sbin/dr-post-mount-provision
EOF
        chmod 440 "$provision_sudoers_file"
        chown root:root "$provision_sudoers_file"
        if visudo -cf "$provision_sudoers_file" >/dev/null 2>&1; then
            print_info "Configured passwordless post-mount provisioning permission for $provision_user"
            if getent passwd "$provision_user" >/dev/null 2>&1; then
                if su - "$provision_user" -c 'sudo -n /usr/local/sbin/dr-post-mount-provision --sudo-self-test >/dev/null 2>&1'; then
                    print_info "Validated post-mount provisioning sudo permission for $provision_user"
                else
                    print_warning "Could not validate passwordless post-mount provisioning permission for $provision_user"
                fi
            fi
        else
            print_warning "Post-mount provisioning sudoers validation failed; removing $provision_sudoers_file"
            rm -f "$provision_sudoers_file"
        fi
    else
        print_warning "No domain user available for passwordless post-mount provisioning rule"
    fi

    # Permit the selected domain user to launch KIT through a narrow root-owned
    # helper without typing an admin password. The desktop shortcut calls only
    # /usr/local/sbin/dr-launch-kit; it does not grant general sudo/bash access.
    local kit_user="${DOMAIN_SUDO_USER:-}"
    rm -f /etc/sudoers.d/dr_launch_kit /etc/sudoers.d/99-dr_launch_kit
    if [ -n "$kit_user" ] && [ "$kit_user" != "root" ]; then
        local kit_sudoers_file="/etc/sudoers.d/zz-dr_launch_kit"
        cat > "$kit_sudoers_file" << EOF
# Managed by DR Domain Join
$kit_user ALL=(root) NOPASSWD: /usr/local/sbin/dr-launch-kit
EOF
        chmod 440 "$kit_sudoers_file"
        chown root:root "$kit_sudoers_file"
        if visudo -cf "$kit_sudoers_file" >/dev/null 2>&1; then
            print_info "Configured passwordless KIT launch permission for $kit_user"
        else
            print_warning "KIT launcher sudoers validation failed; removing $kit_sudoers_file"
            rm -f "$kit_sudoers_file"
        fi
    else
        print_warning "No domain user available for passwordless KIT launcher rule"
    fi
}


configure_autofs_cifs() {
    print_info "Configuring CIFS access for DRIP and KIT tools..."

    # DRIP image paths still use dynamic autofs maps:
    #   /smb/<server>/<share>/...
    #   /net/<server>/<share>/...
    #
    # The fixed KIT tools path is handled by /usr/local/bin/mount-kit-tools
    # instead of autofs because direct/indirect autofs maps for /mnt/x proved
    # unreliable on tested Ubuntu builds, while an explicit Kerberos CIFS mount
    # was reliable.
    mkdir -p /smb
    mkdir -p /net
    mkdir -p /mnt
    mkdir -p /mnt/x

    # Remove old /mnt/x autofs configuration from earlier script versions.
    rm -f /etc/auto.master.d/mnt.autofs /etc/auto.mnt.direct /etc/auto.mnt

    cat > /etc/auto.master.d/smb.autofs << 'EOF'
/smb    /etc/auto.net.cifs    --timeout=300 --ghost
EOF
    cat > /etc/auto.master.d/net.autofs << 'EOF'
/net    /etc/auto.net.cifs    --timeout=300 --ghost
EOF

    # Executable map: called by autofs with the server hostname as $1.
    # Creates a per-server wildcard share map and returns a nested autofs mount.
    # cruid=${UID} tells the CIFS kernel module to use the accessing user's
    # Kerberos ticket — no root credentials or share enumeration required.
    cat > /etc/auto.net.cifs << 'EOF'
#!/bin/bash
key="$1"
[ -z "$key" ] && exit 1

mkdir -p /etc/autofs.d
mapfile="/etc/autofs.d/$key"
if [ ! -f "$mapfile" ]; then
    printf '*\t-fstype=cifs,sec=krb5,cruid=${UID},vers=3.0\t://%s/&\n' "$key" > "$mapfile"
fi

printf -- '-fstype=autofs\tfile:%s\n' "$mapfile"
EOF

    chmod +x /etc/auto.net.cifs

    # Fixed KIT tools mount helper. This preserves the expected path:
    #   /mnt/x -> //TOOLS_SERVER/Tools
    # but avoids depending on autofs for the fixed mount point.
    cat > /usr/local/bin/mount-kit-tools << EOF
#!/bin/bash
set -e

TOOLS_SERVER="${TOOLS_SERVER}"
MOUNT_POINT="/mnt/x"
SHARE="//\${TOOLS_SERVER}/Tools"

# Used by the installer and desktop wrapper to prove sudo can execute this
# helper without prompting. It must run before any mount side effects.
if [ "\${1:-}" = "--sudo-self-test" ]; then
    exit 0
fi

# If a domain user runs this directly, re-exec through the tightly scoped
# passwordless sudoers rule installed by the domain-join script. This avoids
# requiring the user to type sudo while still keeping root limited to this one
# helper.
if [ "\$(id -u)" -ne 0 ]; then
    if ! sudo -n /usr/local/bin/mount-kit-tools --sudo-self-test >/dev/null 2>&1; then
        CURRENT_USER="\$(id -un)"
        echo "This domain account does not have permission to mount the Tool Server." >&2
        echo "" >&2
        echo "Run the following commands:" >&2
        echo "  su - drone" >&2
        echo "  sudo dr-workstation add-user \$CURRENT_USER" >&2
        echo "  exit" >&2
        echo "" >&2
        echo "Then log out of the desktop and log back in." >&2
        exit 1
    fi
    exec sudo -n /usr/local/bin/mount-kit-tools
fi

# Determine the logged-in domain user whose Kerberos ticket should be used.
# sudo sets SUDO_UID; pkexec sets PKEXEC_UID. Fall back to the current UID for
# direct execution.
if [ -n "\${SUDO_UID:-}" ]; then
    CRUID="\$SUDO_UID"
elif [ -n "\${PKEXEC_UID:-}" ]; then
    CRUID="\$PKEXEC_UID"
else
    CRUID="\$(id -u)"
fi

mkdir -p "\$MOUNT_POINT"

if mountpoint -q "\$MOUNT_POINT"; then
    exit 0
fi

if ! command -v klist >/dev/null 2>&1; then
    echo "klist not found. Kerberos tools are not installed." >&2
    exit 1
fi

if ! KRB5CCNAME="FILE:/tmp/krb5cc_\$CRUID" klist -s 2>/dev/null && ! klist -s 2>/dev/null; then
    echo "No valid Kerberos ticket found for UID \$CRUID. Log in as a domain user or run kinit first." >&2
    exit 1
fi

mount -t cifs "\$SHARE" "\$MOUNT_POINT" -o sec=krb5,cruid=\$CRUID,vers=3.0
EOF
    chmod +x /usr/local/bin/mount-kit-tools

    # User-facing wrapper. The post-join script installs a tightly scoped
    # sudoers rule that allows only /usr/local/bin/mount-kit-tools to run
    # passwordlessly. This avoids broad NOPASSWD access while letting domain
    # users mount /mnt/x without opening a terminal or typing sudo.
    cat > /usr/local/bin/mount-kit-tools-desktop << 'EOF'
#!/bin/bash

RUNNER="/usr/local/bin/mount-kit-tools-desktop-runner"

if command -v x-terminal-emulator >/dev/null 2>&1; then
    exec x-terminal-emulator -e "$RUNNER" "$@"
fi

if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- "$RUNNER" "$@"
fi

if command -v mate-terminal >/dev/null 2>&1; then
    exec mate-terminal -e "$RUNNER" "$@"
fi

if command -v xfce4-terminal >/dev/null 2>&1; then
    exec xfce4-terminal -e "$RUNNER" "$@"
fi

exec "$RUNNER" "$@"
EOF
    chmod +x /usr/local/bin/mount-kit-tools-desktop

    cat > /usr/local/bin/mount-kit-tools-autostart << 'EOF'
#!/bin/bash
# Quiet login-time Tool Server/workspace verifier. Successful runs produce no UI.
# If anything fails, show the captured diagnostics in a terminal and leave it open.
set -u

RUNNER="/usr/local/bin/mount-kit-tools-desktop-runner"
LOG_DIR="${XDG_RUNTIME_DIR:-/tmp}"
LOG="$LOG_DIR/dr-mount-kit-tools-autostart.log"

"$RUNNER" --autostart-quiet >"$LOG" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
    exit 0
fi

show_failure() {
    echo "Ontrack Recovery Workstation startup encountered a problem."
    echo ""
    cat "$LOG" 2>/dev/null || true
    echo ""
    echo "Exit code: $status"
    echo ""
    read -r -p "Press Enter to close..." _
}

if command -v x-terminal-emulator >/dev/null 2>&1; then
    exec x-terminal-emulator -e bash -lc "cat '$LOG'; echo; echo 'Exit code: $status'; echo; read -r -p 'Press Enter to close...' _"
fi

if command -v gnome-terminal >/dev/null 2>&1; then
    exec gnome-terminal -- bash -lc "cat '$LOG'; echo; echo 'Exit code: $status'; echo; read -r -p 'Press Enter to close...' _"
fi

show_failure
exit "$status"
EOF
    chmod +x /usr/local/bin/mount-kit-tools-autostart

    cat > /usr/local/bin/mount-kit-tools-desktop-runner << 'EOF'
#!/bin/bash

QUIET_SUCCESS=0
case "${1:-}" in
    --autostart|--autostart-quiet|--quiet-success) QUIET_SUCCESS=1 ;;
esac

echo "Mount DR Tools"
echo "=============="
echo ""

if mountpoint -q /mnt/x; then
    echo "/mnt/x is already mounted."
    status=0
else
    /usr/local/bin/mount-kit-tools
    status=$?
fi

echo ""
if [ "$status" -eq 0 ]; then
    echo "DR Tools mounted successfully at /mnt/x"
    echo ""
    ls -la /mnt/x 2>/dev/null || true
    echo ""
    if [ -x /usr/local/bin/dr-user-desktop-provision ]; then
        echo "Repairing and trusting desktop launchers for this user..."
        /usr/local/bin/dr-user-desktop-provision || true
        echo "Desktop launcher repair completed."
        echo ""
    fi
    if [ -x /usr/local/sbin/dr-post-mount-provision ]; then
        echo "Running post-mount provisioning: KIT installer and company branding..."
        if sudo -n /usr/local/sbin/dr-post-mount-provision; then
            echo "Post-mount provisioning completed."
            if [ -x /usr/local/bin/dr-user-desktop-provision ]; then
                echo "Refreshing desktop launchers after post-mount provisioning..."
                /usr/local/bin/dr-user-desktop-provision || true
            fi
        else
            pm_status=$?
            echo "Post-mount provisioning failed with exit code $pm_status."
            echo "See /var/log/dr-post-mount-provision.log for details."
            status=$pm_status
        fi
    fi
else
    echo "Mount failed with exit code $status"
    echo ""
    echo "Diagnostics:"
    echo "  Current user: $(id -un)"
    echo "  UID: $(id -u)"
    echo ""
    echo "  sudo execution check:"
    sudo -n /usr/local/bin/mount-kit-tools --sudo-self-test 2>&1 || true
    echo ""
    echo "  sudo permission listing:"
    sudo -n -l /usr/local/bin/mount-kit-tools 2>&1 || true
    echo ""
    echo "  Kerberos ticket:"
    klist 2>&1 || true
    echo ""
    echo "Try from terminal:"
    echo "  mount-kit-tools"
    echo ""
    if ! sudo -n /usr/local/bin/mount-kit-tools --sudo-self-test >/dev/null 2>&1; then
        current_user="$(id -un)"
        echo "If this account is not yet authorized, run:"
        echo "  su - drone"
        echo "  sudo dr-workstation add-user $current_user"
        echo "  exit"
        echo "Then log out and back in."
    fi
fi

if [ "$status" -eq 0 ] && [ "$QUIET_SUCCESS" -eq 1 ]; then
    exit 0
fi

echo ""
read -r -p "Press Enter to close..."
exit "$status"
EOF
    chmod +x /usr/local/bin/mount-kit-tools-desktop-runner

    # Allow permitted domain users to run only the mount helper without a password.
    # This does NOT grant broad passwordless sudo. It only permits:
    #   /usr/local/bin/mount-kit-tools
    #
    # The script prompts once for the optional sudo/domain user in post-join.
    # Use that same short-name identity because SSSD is configured for short names.
    mount_user="${DOMAIN_SUDO_USER:-}"
    # Remove historical filenames from earlier installer versions before writing
    # the final late-loading rule. This keeps reruns deterministic.
    rm -f /etc/sudoers.d/dr_mount_kit_tools /etc/sudoers.d/99-dr_mount_kit_tools
    if [ -n "$mount_user" ] && [ "$mount_user" != "root" ]; then
        # Must sort late in /etc/sudoers.d. If this user also has a broader
        # password-required sudo rule, sudo's later matching entry wins.
        # Prefixing with zz makes this file sort after per-user/domain sudoers files
        # such as martin_campetta_domain_sudo. In sudoers, later matching entries
        # can override earlier tags, so this must load last to preserve NOPASSWD.
        mount_sudoers_file="/etc/sudoers.d/zz-dr_mount_kit_tools"
        cat > "$mount_sudoers_file" << EOF
# Managed by DR Domain Join
$mount_user ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools
EOF
        chmod 440 "$mount_sudoers_file"
        chown root:root "$mount_sudoers_file"
        if visudo -cf "$mount_sudoers_file" >/dev/null 2>&1; then
            print_info "Configured passwordless mount permission for $mount_user using final sudoers rule"
            if getent passwd "$mount_user" >/dev/null 2>&1; then
                if su - "$mount_user" -c 'sudo -n /usr/local/bin/mount-kit-tools --sudo-self-test >/dev/null 2>&1'; then
                    print_info "Validated mount helper sudo permission for $mount_user"
                else
                    print_warning "Could not validate passwordless mount helper permission for $mount_user"
                    print_warning "Desktop shortcut may fail until sudoers/SSSD identity is corrected"
                fi
            else
                print_warning "Domain user $mount_user is not resolvable yet; skipping mount helper permission validation"
            fi
        else
            print_warning "Mount helper sudoers validation failed; removing $mount_sudoers_file"
            rm -f "$mount_sudoers_file"
        fi
    else
        print_warning "No domain user available for passwordless mount helper rule"
    fi

    install_post_mount_provision_helper

    cat > /usr/local/bin/umount-kit-tools << 'EOF'
#!/bin/bash
set -e
if mountpoint -q /mnt/x; then
    umount /mnt/x
fi
EOF
    chmod +x /usr/local/bin/umount-kit-tools

    # Graphical launcher for all users.
    mkdir -p /usr/share/applications /etc/xdg/autostart /usr/share/polkit-1/actions

    cat > /usr/share/applications/mount-kit-tools.desktop << 'EOF'
[Desktop Entry]
Name=Mount DR Tools
Comment=Mount the DR Tools share at /mnt/x
Exec=/usr/local/bin/mount-kit-tools-desktop
Icon=drive-network
Terminal=false
Type=Application
Categories=Utility;System;
EOF
    chmod 644 /usr/share/applications/mount-kit-tools.desktop

    # Unity 7 on Ubuntu 16.04 does not always surface application launchers
    # clearly. Install a real desktop icon for newly-created domain homes via
    # /etc/skel, and also copy it into existing user Desktop folders.
    mkdir -p /etc/skel/Desktop
    cp /usr/share/applications/mount-kit-tools.desktop "/etc/skel/Desktop/Mount DR Tools.desktop"
    chmod 755 "/etc/skel/Desktop/Mount DR Tools.desktop"
    chown root:root "/etc/skel/Desktop/Mount DR Tools.desktop"

    # Add the desktop icon to existing human/domain user homes when present.
    # This is safe to rerun and skips system homes that do not have Desktop dirs.
    while IFS=: read -r user _ uid gid _ home _; do
        [ -z "$home" ] && continue
        [ "$home" = "/" ] && continue
        [ "$uid" -lt 1000 ] 2>/dev/null && continue

        desktop_dir="$home/Desktop"
        if [ -d "$home" ]; then
            mkdir -p "$desktop_dir"
            cp /usr/share/applications/mount-kit-tools.desktop "$desktop_dir/Mount DR Tools.desktop"
            chmod 755 "$desktop_dir/Mount DR Tools.desktop"
            chown "$uid:$gid" "$desktop_dir" "$desktop_dir/Mount DR Tools.desktop" 2>/dev/null || true
        fi
    done < <(getent passwd)

    # XDG autostart entry: runs once per graphical login and prompts via pkexec
    # if elevation is required. mount-kit-tools is idempotent, so repeated runs
    # are safe once /mnt/x is already mounted.
    cat > /etc/xdg/autostart/mount-kit-tools.desktop << 'EOF'
[Desktop Entry]
Name=Mount DR Tools
Comment=Mount the DR Tools share at /mnt/x
Exec=/usr/local/bin/mount-kit-tools-autostart
Icon=drive-network
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
    chmod 644 /etc/xdg/autostart/mount-kit-tools.desktop

    # PolicyKit policy so the graphical prompt clearly identifies this action.
    # Users must still authenticate; this does not grant passwordless root.
    cat > /usr/share/polkit-1/actions/com.ontrack.mount-kit-tools.policy << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>Ontrack</vendor>
  <vendor_url>http://ontrack.link</vendor_url>
  <action id="com.ontrack.mount-kit-tools">
    <description>Mount DR Tools share</description>
    <message>Authentication is required to mount the DR Tools share.</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/mount-kit-tools</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
EOF
    chmod 644 /usr/share/polkit-1/actions/com.ontrack.mount-kit-tools.policy

    # Ensure the credential cache is at a predictable path for systems that
    # do not populate the kernel keyring (no-op on modern SSSD/kernel combos).
    local sssd_conf="/etc/sssd/sssd.conf"
    if [ -f "$sssd_conf" ] && ! grep -q "krb5_ccname_template" "$sssd_conf"; then
        local domain_header
        domain_header=$(grep -m1 "^\[domain/" "$sssd_conf" | sed 's/[[\]]/\\&/g')
        if [ -n "$domain_header" ]; then
            sed -i "\|^${domain_header}$|a\\krb5_ccname_template = FILE:/tmp/krb5cc_%U" "$sssd_conf"
            systemctl restart sssd > /dev/null 2>&1 || true
        fi
    fi

    # Ensure 'files' is first in the automount nsswitch lookup order.
    # realm join often sets "automount: sss", which causes autofs to query LDAP
    # for the master map and ignore /etc/auto.master.d/ entirely.
    local nsswitch="/etc/nsswitch.conf"
    local automount_line
    automount_line=$(grep '^automount:' "$nsswitch" 2>/dev/null || true)
    if [ -z "$automount_line" ]; then
        echo "automount: files" >> "$nsswitch"
        print_info "Added 'automount: files' to $nsswitch"
    elif ! echo "$automount_line" | grep -qE '^automount:\s*files'; then
        sed -i 's/^automount:.*/automount: files sss/' "$nsswitch"
        print_info "Reordered automount lookup in $nsswitch — files first"
    else
        print_info "automount lookup order already correct in $nsswitch"
    fi

    systemctl daemon-reload
    systemctl enable autofs > /dev/null 2>&1
    systemctl restart autofs

    print_info "DRIP autofs configured — /smb/<server>/<share>/ and /net/<server>/<share>/"
    print_info "KIT tools mount helper configured — run: mount-kit-tools"
    print_info "KIT tools path after helper runs: /mnt/x (${TOOLS_SERVER}/Tools)"

    # If this post-join run is being executed from a logged-in domain user via
    # sudo, immediately mount the KIT tools share so KIT installation can proceed.
    # If this run is still under a local admin account without a domain Kerberos
    # ticket, do not fail the whole script; leave the helper/desktop shortcut in place.
    if [ -x /usr/local/bin/mount-kit-tools ]; then
        print_info "Attempting to mount KIT tools share at /mnt/x..."
        if /usr/local/bin/mount-kit-tools; then
            print_info "KIT tools share mounted at /mnt/x"
            if [ -x /usr/local/sbin/dr-post-mount-provision ]; then
                print_info "Running post-mount provisioning: KIT installer and company branding..."
                if /usr/local/sbin/dr-post-mount-provision; then
                    print_info "Post-mount provisioning completed"
                else
                    print_warning "Post-mount provisioning failed; see /var/log/dr-post-mount-provision.log"
                fi
            fi
        else
            print_warning "KIT tools share was not mounted automatically"
            print_warning "Log in as a domain user and run: mount-kit-tools"
        fi
    fi



}
# ── Configure DNS search domains ──────────────────────────────────────────────

configure_dns_search_domains() {
    print_info "Configuring DNS search domains..."

    local connection
    connection="$(get_active_connection)"

    if [ -z "$connection" ]; then
        print_warning "No active NetworkManager connection found — skipping DNS search domain configuration"
        return 0
    fi

    local current
    current=$(nmcli -g ipv4.dns-search connection show "$connection" 2>/dev/null || true)

    local missing_domain=false
    local domain
    for domain in $(echo "$DNS_SEARCH" | tr ',' ' '); do
        if ! echo "$current" | grep -qw "$domain"; then
            missing_domain=true
            break
        fi
    done

    if [ "$missing_domain" = false ]; then
        print_info "DNS search domains already configured on '$connection'"
        return 0
    fi

    print_info "Applying DNS search domains to connection '$connection'..."
    nmcli connection modify "$connection" ipv4.dns-search "$DNS_SEARCH"
    nmcli connection up "$connection" > /dev/null
    print_info "DNS search domains applied"

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        systemctl restart systemd-resolved
        print_info "systemd-resolved restarted"
    fi
}

# ── Configure sudoers for a domain user ───────────────────────────────────────
# usermod cannot be used for domain users because it reads /etc/passwd directly
# and domain users are not listed there (they are resolved via NSS/SSSD).
# A sudoers drop-in file is used instead.
#
# IMPORTANT: The filename in /etc/sudoers.d/ must not contain a dot (.) character.
# Sudo silently ignores any drop-in file whose name contains a dot. Since domain
# usernames contain dots (e.g. lyle.bergman), the filename uses underscores instead.

configure_sudoers() {
    if [ -z "$DOMAIN_SUDO_USER" ]; then
        print_info "No workstation user specified — skipping workstation user authorization"
        return 0
    fi

    if [ ! -x /usr/local/sbin/dr-workstation ]; then
        install_dr_workstation_manager || return 1
    fi

    print_info "Authorizing workstation user with dr-workstation: $DOMAIN_SUDO_USER"
    if /usr/local/sbin/dr-workstation add-user "$DOMAIN_SUDO_USER"; then
        print_info "Workstation access configured for $DOMAIN_SUDO_USER"
    else
        print_warning "Could not add $DOMAIN_SUDO_USER through dr-workstation"
        print_warning "After domain login works, run: sudo dr-workstation add-user $DOMAIN_SUDO_USER"
    fi
}

# ── Configure Samba (smb.conf) ────────────────────────────────────────────────

configure_samba() {
    local smb_conf="/etc/samba/smb.conf"
    print_info "Configuring $smb_conf..."

    if grep -q "^[[:space:]]*workgroup = $WORKGROUP" "$smb_conf" 2>/dev/null && \
       grep -q "^[[:space:]]*realm = $REALM" "$smb_conf" 2>/dev/null; then
        print_info "smb.conf is already configured — skipping"
        return 0
    fi

    # Set workgroup
    if grep -q "^[[:space:]]*workgroup" "$smb_conf"; then
        sed -i "s/^[[:space:]]*workgroup.*/   workgroup = $WORKGROUP/" "$smb_conf"
    else
        sed -i "/^\[global\]/a\\   workgroup = $WORKGROUP" "$smb_conf"
    fi

    # Set realm (add after workgroup if not present)
    if grep -q "^[[:space:]]*realm" "$smb_conf"; then
        sed -i "s/^[[:space:]]*realm.*/   realm = $REALM/" "$smb_conf"
    else
        sed -i "/^[[:space:]]*workgroup/a\\   realm = $REALM" "$smb_conf"
    fi

    # Set wins server (add after realm if not present)
    if grep -q "^[[:space:]]*wins server" "$smb_conf"; then
        sed -i "s/^[[:space:]]*wins server.*/   wins server = $WINS_SERVER/" "$smb_conf"
    else
        sed -i "/^[[:space:]]*realm/a\\   wins server = $WINS_SERVER" "$smb_conf"
    fi

    print_info "smb.conf updated"
}

# ── Configure NetBIOS name resolution via winbind ─────────────────────────────

configure_wins_resolution() {
    local nsswitch="/etc/nsswitch.conf"
    print_info "Configuring NetBIOS name resolution..."

    if grep -qE "^hosts:.*wins" "$nsswitch" 2>/dev/null; then
        print_info "wins already present in $nsswitch"
        return 0
    fi

    if sed -i '/^hosts:/s/dns/wins dns/' "$nsswitch"; then
        print_info "Added wins to hosts resolution in $nsswitch"
    else
        print_warning "Failed to update $nsswitch — NetBIOS name resolution may not work"
    fi
}

# ── Enable and start winbind ──────────────────────────────────────────────────

enable_winbind() {
    print_info "Enabling winbind service..."
    systemctl enable winbind > /dev/null 2>&1
    systemctl restart winbind
    print_info "winbind is running"
}


# ── Configure graphical login prompt ──────────────────────────────────────────
# Hide the local user list in GDM so shared lab/KIT workstations show a direct
# username/password prompt. This keeps the local break-glass account available
# but avoids advertising it as the default login path.

configure_gdm_login_prompt() {
    local gdm_conf="/etc/gdm3/custom.conf"

    # Only configure this on systems that appear to use GDM/GDM3.
    if [ ! -d "/etc/gdm3" ] && [ ! -d "/usr/share/gdm" ]; then
        print_info "GDM not detected — skipping graphical login prompt configuration"
        return 0
    fi

    print_info "Configuring GDM to show username/password prompt instead of local user list..."

    # Legacy/fallback GDM setting. This is harmless on newer Ubuntu releases,
    # but by itself is not sufficient on some GNOME/GDM versions.
    mkdir -p /etc/gdm3
    if [ ! -f "$gdm_conf" ]; then
        cat > "$gdm_conf" << 'EOF'
[daemon]

[greeter]
DisableUserList=true
EOF
    elif grep -q "^\[greeter\]" "$gdm_conf"; then
        if grep -q "^[[:space:]]*DisableUserList[[:space:]]*=" "$gdm_conf"; then
            sed -i "s/^[[:space:]]*DisableUserList[[:space:]]*=.*/DisableUserList=true/" "$gdm_conf"
        else
            sed -i "/^\[greeter\]/a\\DisableUserList=true" "$gdm_conf"
        fi
    else
        cat >> "$gdm_conf" << 'EOF'

[greeter]
DisableUserList=true
EOF
    fi

    # Current GNOME/GDM method: create the GDM dconf profile and set
    # org.gnome.login-screen disable-user-list=true. Testing on Ubuntu showed
    # this is required for the greeter to stop showing the last/local user.
    mkdir -p /etc/dconf/profile
    cat > /etc/dconf/profile/gdm << 'EOF'
user-db:user
system-db:gdm
file-db:/usr/share/gdm/greeter-dconf-defaults
EOF

    mkdir -p /etc/dconf/db/gdm.d
    cat > /etc/dconf/db/gdm.d/00-login-screen << 'EOF'
[org/gnome/login-screen]
disable-user-list=true
EOF

    if command -v dconf >/dev/null 2>&1; then
        dconf update
        print_info "GDM dconf profile updated; user list will be hidden after GDM restart or reboot"
    else
        print_warning "dconf command not found; GDM dconf files were written but not compiled"
        print_warning "Run 'sudo dconf update' after dconf is installed, then reboot or restart gdm3"
    fi

    print_info "Local accounts remain available by typing the username manually"
}
# ── Check display manager ─────────────────────────────────────────────────────
# Do NOT restart the display manager automatically. Restarting GDM or LightDM
# while the script is running inside a desktop session kills that session,
# which terminates the terminal and aborts the script mid-execution — leaving
# the machine in a partially configured state. Instead, note whether a display
# manager is running so we can prompt the user to log out manually at the end.

check_display_manager() {
    if systemctl is-active --quiet gdm3 2>/dev/null || \
       systemctl is-active --quiet gdm 2>/dev/null || \
       systemctl is-active --quiet lightdm 2>/dev/null; then
        DISPLAY_MANAGER_RUNNING=true
    else
        DISPLAY_MANAGER_RUNNING=false
    fi
}

# ── Verify ────────────────────────────────────────────────────────────────────

verify_join() {
    print_info "Verifying domain join..."

    if ! realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        print_error "Domain join verification failed — machine does not appear to be joined"
        return 1
    fi
    print_info "Domain join verified: $DOMAIN"

    if ! systemctl is-active --quiet sssd 2>/dev/null; then
        print_error "SSSD is not running — domain logins will fail"
        print_error "Check: journalctl -u sssd -n 50"
        return 1
    fi
    print_info "SSSD is running"

    print_info "Testing short name resolution..."
    if nslookup "$(echo "$DOMAIN" | cut -d. -f1)-tools" > /dev/null 2>&1; then
        print_info "Short name resolution is working"
    else
        print_warning "Short name resolution test inconclusive — test manually with: nslookup <servername>"
    fi

    return 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

prompt_office_code() {
    echo ""
    echo "  Enter the office code for this machine."
    echo "  This is used to derive the tools server name."
    echo "  Example: EP1 → dr-ep1-tools, PL1 → dr-pl1-tools"
    echo ""

    while [ -z "$OFFICE_CODE" ]; do
        read -r -p "  Office code: " OFFICE_CODE
        OFFICE_CODE="$(echo "$OFFICE_CODE" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"

        if [ -z "$OFFICE_CODE" ]; then
            print_warning "Office code cannot be blank"
        fi
    done
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dns-test)
                DNS_TEST_ONLY=true
                ;;
            --full-reconfigure)
                FULL_RECONFIGURE=true
                ;;
            -h|--help)
                echo 'Usage: wget -qO- http://ontrack.link/joindomain | sudo bash'
                echo 'Args:  wget -qO- http://ontrack.link/joindomain | sudo bash -s -- [OFFICE_CODE] [--dns-test]'
                echo "  If no office code has been saved, you will be prompted for it."
                echo "  --dns-test          Apply DNS/search settings and test realm discovery only."
                echo "  --full-reconfigure  Engineering override for a completed workstation."
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                echo 'Usage: wget -qO- http://ontrack.link/joindomain | sudo bash'
                exit 1
                ;;
            *)
                if [ -z "$OFFICE_CODE" ]; then
                    OFFICE_CODE="$1"
                else
                    print_error "Unexpected argument: $1"
                    echo 'Usage: wget -qO- http://ontrack.link/joindomain | sudo bash'
                    exit 1
                fi
                ;;
        esac
        shift
    done

    # If the office was not provided on the command line, reuse the value saved
    # during the first run. This prevents the post-join rerun from asking again.
    if [ -z "$OFFICE_CODE" ] && [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
        OFFICE_CODE="${OFFICE_CODE:-}"
        if [ -n "$OFFICE_CODE" ]; then
            print_info "Using saved office code: $OFFICE_CODE"
        fi
    fi

    # If no saved value exists, prompt interactively.
    if [ -z "$OFFICE_CODE" ]; then
        echo ""
        echo "  Enter the office code for this workstation."
        echo "  Example: EP1 or PL1"
        echo ""
        while [ -z "$OFFICE_CODE" ]; do
            read -r -p "  Office code: " OFFICE_CODE
            OFFICE_CODE="$(echo "$OFFICE_CODE" | tr '[:lower:]' '[:upper:]' | xargs)"
        done
    fi

    # Normalize and persist the selected office code for future reruns without
    # clobbering the installer state machine.
    OFFICE_CODE="$(echo "$OFFICE_CODE" | tr '[:lower:]' '[:upper:]' | xargs)"
    if [ ! -f "$STATE_FILE" ]; then
        save_state "OFFICE_CODE_SELECTED"
    else
        save_state "${STAGE:-OFFICE_CODE_SELECTED}"
    fi

    case "$OFFICE_CODE" in
        PL|PL1)
            TOOLS_SERVER="dr-pl1-tools"
            ;;
        *)
            TOOLS_SERVER="dr-$(echo "$OFFICE_CODE" | tr '[:upper:]' '[:lower:]')-tools"
            ;;
    esac
    print_info "Office: $OFFICE_CODE — tools server: $TOOLS_SERVER"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo "=========================================="
  echo "  DR Domain Join"
  echo "  Version ${SCRIPT_VERSION}"
  echo "=========================================="
    echo ""

    check_privileges
    load_state || true
    completed_workstation_rerun_guard "$@"
    parse_args "$@"
    print_resume_state
    ensure_local_pam_survives_sssd_failure
    disable_sssd_if_not_joined
    print_machine_status
    validate_or_fix_hostname || exit 1

if [ -f "$STATE_FILE" ] && grep -q 'STAGE="REBOOT_REQUIRED_AFTER_HOSTNAME"' "$STATE_FILE" 2>/dev/null; then
    current_hn="$(hostnamectl --static 2>/dev/null || hostname)"
    if [ -n "${DOMAIN_TARGET_HOSTNAME:-}" ] && [ "$current_hn" = "$DOMAIN_TARGET_HOSTNAME" ]; then
        print_info "Hostname reboot requirement satisfied for $current_hn"
        save_state "PREJOIN_AFTER_HOSTNAME_REBOOT"
    fi
fi


    # --- Checks and upfront prompts (interactive) ---
    detect_os
    load_config

    # --- Summary ---
    if realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
    validate_existing_join || exit 1
        echo "  This machine is already joined to $DOMAIN."
        echo "  This run will complete all remaining post-join configuration."
        echo "  You will be prompted once during the run to optionally grant"
        echo "  sudo access to a domain user on this machine."
    else
        echo "  Joining this machine to $DOMAIN is a two-step process"
        echo "  that requires a domain admin. Before proceeding, make sure"
        echo "  a domain admin is available to assist — they will need to"
        echo "  SSH into this machine to complete Step 2."
        echo ""
        echo "  Step 1 — Run this script now (no domain admin required):"
        echo "    Installs packages, preserves DHCP/VPN DNS unless overridden,"
        echo "    applies the corporate DNS search list before discovery,"
        echo "    and sets up time synchronization. No further input is"
        echo "    needed — the script will exit with SSH instructions"
        echo "    for the domain admin when ready."
        echo ""
        echo "  Step 2 — Domain admin action (SSH required):"
        echo "    The domain admin SSHes in and runs a single command"
        echo "    to join this machine to $DOMAIN."
        echo ""
        echo "  Step 3 — Re-run this script (no domain admin required):"
        echo "    Detects the completed join, prompts once for an optional"
        echo "    sudo user, then applies all remaining configuration."
    fi
    echo ""
    read -r -p "  Continue? [y/N]: " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY]) ;;
        *)
            print_info "Cancelled."
            exit 0
            ;;
    esac
    echo ""

    # --- Automated steps (no further input required) ---
    # Time/DNS must be healthy on every run — including post-join reruns —
    # before apt, Kerberos, SSSD, or domain configuration is touched.
    # Do not run apt before sync_time(); apt can fail if the clock is wrong.
    install_time_sync_prerequisites
    configure_dns_servers
    configure_dns_search_domains
    bootstrap_time_before_apt || true

    print_info "Pre-flight package manager check: verifying apt/dpkg are not locked before installation..."
    wait_for_apt_locks || exit 1

    if [ "$DNS_TEST_ONLY" = true ]; then
        verify_ad_discovery
        print_info "DNS/domain discovery test completed. No domain join attempted."
        exit 0
    fi

    install_domain_packages
    configure_chrony
    sync_time
    configure_no_reboot_policy
    verify_krb5_conf
    configure_fqdn
    join_domain
    prompt_sudo_user
    configure_pam_mkhomedir
    configure_realm_permissions
    configure_sssd_settings
    enable_sssd
    configure_gdm_login_prompt
    install_dr_workstation_manager
    configure_autofs_cifs
    configure_sudoers
    configure_samba
    configure_wins_resolution
    enable_winbind
    check_display_manager

    if verify_join; then
        echo ""
        save_state "POSTJOIN_COMPLETE"
        rm -f /etc/motd 2>/dev/null || true
        print_info "Domain join completed successfully!"
        echo ""
        echo "  Log in as a domain user with:"
        echo "    username@$DOMAIN"
        echo ""
        echo "  KIT tools can be mounted at /mnt/x using the desktop shortcut:"
        echo "    Mount DR Tools"
        echo "  After domain login, /mnt/x should mount automatically. If needed, use the Mount DR Tools desktop icon."
        echo ""
        if [ -n "$DOMAIN_SUDO_USER" ]; then
            echo "  Sudo access has been granted to: ${DOMAIN_SUDO_USER}"
            echo ""
        fi
        if [ "$DISPLAY_MANAGER_RUNNING" = "true" ]; then
            echo -e "${YELLOW}  !! ACTION REQUIRED: Log out and back in for all changes to take effect.${NC}"
            echo ""
        fi
    else
        echo ""
        print_error "Domain join completed with errors — review output above"
        exit 1
    fi
}

main "$@"
