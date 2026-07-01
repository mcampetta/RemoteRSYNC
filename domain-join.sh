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
#   2. Run the script with sudo, passing your office code:
#      sudo bash -c "$(wget -qO- http://ontrack.link/joindomain)" EP1
#
#   The office code is used to derive the tools file server hostname
#   (e.g. EP1 → dr-ep1-tools, UK1 → dr-uk1-tools, DE1 → dr-de1-tools).
#
# Two-run process:
#   Run 1: You will be prompted for a domain user to receive sudo access.
#          The script installs packages, configures DNS and time sync, then
#          exits with instructions for a domain admin to complete the join via SSH.
#
#   Run 2: After the domain admin has joined the machine, re-run this script.
#          It will detect the existing join and complete all post-join
#          configuration unattended. Safe to re-run on an already-joined machine.
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
#   sudo bash -c "$(wget -qO- http://ontrack.link/joindomain)" EP1 --dns-test
#   Applies DNS/search settings and runs realm discovery without joining.
#
# Supported Systems:
#   - Debian 13 or newer
#   - Ubuntu 22.04 or newer
#

SCRIPT_VERSION="1.4.0"
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
KIT_PROCESS_PATTERN="${KIT_PROCESS_PATTERN:-KIT}"
OFFICE_CODE=""
TOOLS_SERVER=""
STATE_FILE="/etc/domain-join.conf"

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
        print_info 'Please run: sudo bash -c "$(wget -qO- http://ontrack.link/joindomain)"'
        exit 1
    fi
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
    local interval=10
    local max_wait=300
    local lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )

    get_lock_holder_pids() {
        local lock
        local all_pids=""

        for lock in "${lock_files[@]}"; do
            [ -e "$lock" ] || continue

            if command -v fuser >/dev/null 2>&1; then
                local pids
                pids=$(fuser "$lock" 2>/dev/null | xargs 2>/dev/null || true)
                if [ -n "$pids" ]; then
                    all_pids="$all_pids $pids"
                fi
            fi
        done

        # Fallback when fuser identifies no lock owner but apt/dpkg appears active.
        if [ -z "$(echo "$all_pids" | xargs 2>/dev/null)" ]; then
            ps -eo pid=,comm=,args= | awk '/apt|apt-get|dpkg|unattended-upgrade|packagekit/ && !/awk/ {print $1}' | xargs 2>/dev/null || true
        else
            echo "$all_pids" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null || true
        fi
    }

    get_lock_holders() {
        local pids
        pids="$(get_lock_holder_pids)"

        if [ -z "$pids" ]; then
            return 0
        fi

        local pid
        for pid in $pids; do
            local cmd args elapsed
            cmd=$(ps -p "$pid" -o comm= 2>/dev/null || true)
            args=$(ps -p "$pid" -o args= 2>/dev/null || true)
            elapsed=$(ps -p "$pid" -o etimes= 2>/dev/null | xargs 2>/dev/null || true)

            [ -n "$cmd$args" ] || continue

            echo "    PID $pid (${cmd:-unknown}, ${elapsed:-?}s): ${args:-unknown}"
        done
    }

    apt_locks_held() {
        [ -n "$(get_lock_holder_pids)" ]
    }

    force_clear_apt_locks() {
        local pids
        pids="$(get_lock_holder_pids)"

        if [ -z "$pids" ]; then
            print_info "No active apt/dpkg lock holders found."
            return 0
        fi

        print_warning "Force-clearing apt/dpkg locks can interrupt Ubuntu updates."
        print_warning "Only continue if the listed process is clearly stuck or blocking deployment."
        echo ""
        print_warning "Current lock holder(s):"
        get_lock_holders
        echo ""
        read -r -p "  Stop these package-manager process(es) and repair dpkg? [y/N]: " answer

        case "$answer" in
            y|Y|yes|YES)
                ;;
            *)
                print_error "Package manager is still locked; aborting by user choice."
                return 1
                ;;
        esac

        local pid
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                print_warning "Requesting process $pid to stop..."
                kill "$pid" 2>/dev/null || true
            fi
        done

        sleep 5

        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                print_warning "Process $pid did not stop; sending SIGKILL..."
                kill -9 "$pid" 2>/dev/null || true
            fi
        done

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

    if apt_locks_held; then
        print_info "Ubuntu package manager is currently busy; waiting for apt/dpkg locks..."
        print_info "Current lock holder(s):"
        get_lock_holders
    fi

    while apt_locks_held; do
        if [ "$waited" -ge "$max_wait" ]; then
            print_warning "Package manager lock has persisted for ${max_wait} seconds."
            force_clear_apt_locks || return 1
            break
        fi

        sleep "$interval"
        waited=$((waited + interval))

        print_info "Still waiting for apt/dpkg locks... (${waited}s elapsed)"
        print_info "Current lock holder(s):"
        get_lock_holders
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

prompt_for_ad_hostname() {
    local prefix
    prefix="$(office_hostname_prefix)"

    echo "  Hostname prefix: $prefix"
    echo ""
    echo "  Enter the workstation number for this machine."
    echo "  Example: 7 becomes ${prefix}-07"
    echo ""

    local number
    local proposed
    local confirm

    while true; do
        read -r -p "  Workstation number: " number
        proposed="$(suggest_hostname "$prefix" "$number")"

        if ! is_valid_ad_hostname "$proposed"; then
            print_warning "Generated hostname '$proposed' is not AD-safe."
            print_warning "Use a shorter office code/prefix or a smaller workstation number."
            continue
        fi

        echo ""
        echo "------------------------------------------"
        echo "  Proposed hostname: $proposed"
        echo "------------------------------------------"
        read -r -p "  Use this hostname? [Y/n]: " confirm
        confirm="${confirm:-Y}"

        case "$confirm" in
            y|Y|yes|YES)
                DOMAIN_TARGET_HOSTNAME="$proposed"
                return 0
                ;;
            *)
                echo ""
                print_info "Let's choose another workstation number."
                ;;
        esac
    done
}

validate_or_fix_hostname() {
    local hn
    hn="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"

    if is_valid_ad_hostname "$hn"; then
        print_info "Hostname is AD-safe: $hn"
        return 0
    fi

    echo ""
    print_warning "Current hostname may break Active Directory/Kerberos joins: $hn"
    print_warning "Hostnames should be 15 characters or fewer and contain only letters, numbers, and hyphens."
    print_warning "Long hostnames can be truncated in AD, causing machine-account/keytab failures."
    echo ""

    local suggested
    suggested="$(suggest_hostname "$(office_hostname_prefix)" "01")"

    echo "  Suggested format: $(office_hostname_prefix)-NN"
    echo "  Example hostname: $suggested"
    echo ""

    read -r -p "  Rename this machine now using the office naming convention? [Y/n]: " answer
    answer="${answer:-Y}"

    case "$answer" in
        y|Y|yes|YES)
            prompt_for_ad_hostname

            if [ -z "$DOMAIN_TARGET_HOSTNAME" ]; then
                print_error "Internal error: hostname prompt did not set DOMAIN_TARGET_HOSTNAME."
                return 1
            fi

            print_info "Setting hostname to $DOMAIN_TARGET_HOSTNAME"
            hostnamectl set-hostname "$DOMAIN_TARGET_HOSTNAME"
            update_hosts_for_hostname "$DOMAIN_TARGET_HOSTNAME"
            ensure_local_pam_survives_sssd_failure
            disable_sssd_if_not_joined

            HOSTNAME_CHANGED=1
            save_state "REBOOT_REQUIRED_AFTER_HOSTNAME"

            print_warning "Hostname changed. A reboot is required before the domain admin performs the join."
            print_warning "Please reboot, then rerun this script."
            exit 20
            ;;
        *)
            print_error "Cannot safely continue with hostname '$hn'."
            print_error "Please set a 15-character-or-shorter hostname, reboot, and rerun this script."
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

    print_error "Machine appears joined, but AD machine-account validation failed."
    print_error "This commonly occurs after VM snapshot rollback, hostname truncation, or deleted AD computer objects."
    print_error "Do not continue with post-join configuration until this is fixed."
    print_error "Recommended cleanup:"
    print_error "  sudo realm leave $DOMAIN"
    print_error "  sudo rm -f /etc/krb5.keytab"
    print_error "  sudo rm -rf /var/lib/sss/db/* /var/lib/sss/mc/*"
    print_error "Then ensure the hostname is AD-safe and rejoin the domain."
    ensure_local_pam_survives_sssd_failure
    return 1
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
    echo "  Optionally grant sudo access to a domain user on this machine."
    echo "  Enter the short account name only (e.g. jsmith — not jsmith@$DOMAIN)."
    echo "  Leave blank to skip — sudo access can be added manually later."
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

    wait_for_apt_locks
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
    echo "  A domain admin must SSH into this machine and run:"
    echo ""
    echo "    sudo realm join $DOMAIN -U <admin_username>"
    echo ""
    echo "  Note: realmd uses -U for the admin username option."
    echo ""
    echo "  Once joined, re-run this script to complete configuration:"
    echo ""
    echo '    sudo bash -c "$(wget -qO- http://ontrack.link/joindomain)"'
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

# If a domain user runs this directly, re-exec through the tightly scoped
# passwordless sudoers rule installed by the domain-join script. This avoids
# requiring the user to type sudo while still keeping root limited to this one
# helper.
if [ "\$(id -u)" -ne 0 ]; then
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
set -e

if mountpoint -q /mnt/x; then
    exit 0
fi

exec /usr/local/bin/mount-kit-tools
EOF
    chmod +x /usr/local/bin/mount-kit-tools-desktop

    # Allow permitted domain users to run only the mount helper without a password.
    # This does NOT grant broad passwordless sudo. It only permits:
    #   /usr/local/bin/mount-kit-tools
    #
    # The script prompts once for the optional sudo/domain user in post-join.
    # Use that same short-name identity because SSSD is configured for short names.
    mount_user="${DOMAIN_SUDO_USER:-}"
    if [ -n "$mount_user" ] && [ "$mount_user" != "root" ]; then
        mount_sudoers_file="/etc/sudoers.d/dr_mount_kit_tools"
        cat > "$mount_sudoers_file" << EOF
# Managed by DR Domain Join
$mount_user ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools
EOF
        chmod 440 "$mount_sudoers_file"
        chown root:root "$mount_sudoers_file"
        if visudo -cf "$mount_sudoers_file" >/dev/null 2>&1; then
            print_info "Configured passwordless mount permission for $mount_user"
        else
            print_warning "Mount helper sudoers validation failed; removing $mount_sudoers_file"
            rm -f "$mount_sudoers_file"
        fi
    else
        print_warning "No domain user available for passwordless mount helper rule"
    fi

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
Exec=/usr/local/bin/mount-kit-tools-desktop
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
        print_info "No sudo user specified — skipping sudoers configuration"
        return 0
    fi

    # SSSD is configured for short-name logins (use_fully_qualified_names = False),
    # and realm list reports login-formats: %U. Sudo must therefore match the
    # resolved local identity (e.g. martin.campetta), not user@domain.
    local sudo_identity="$DOMAIN_SUDO_USER"
    # Replace dots with underscores in the filename — sudo ignores files with dots in the name
    local safe_name="${DOMAIN_SUDO_USER//./_}"
    local sudoers_file="/etc/sudoers.d/${safe_name}_domain_sudo"
    local desired_entry="${sudo_identity} ALL=(ALL:ALL) ALL"

    if [ -f "$sudoers_file" ] && grep -qxF "$desired_entry" "$sudoers_file"; then
        print_info "Sudoers entry already correct for $sudo_identity — skipping"
        return 0
    fi

    echo "$desired_entry" > "$sudoers_file"
    chmod 440 "$sudoers_file"
    chown root:root "$sudoers_file"

    if visudo -c -f "$sudoers_file" > /dev/null 2>&1; then
        print_info "Sudoers entry configured for $sudo_identity"
    else
        print_warning "Sudoers file failed syntax check — removing $sudoers_file"
        rm -f "$sudoers_file"
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
    echo "  Example: EP1 → dr-ep1-tools"
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
                ;;-h|--help)
                echo 'Usage: sudo bash -c \"$(wget -qO- http://ontrack.link/joindomain)\"'
                echo "  If no office code has been saved, you will be prompted for it."
                echo "  --dns-test   Apply DNS/search settings and test realm discovery only."
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                echo 'Usage: sudo bash -c \"$(wget -qO- http://ontrack.link/joindomain)\"'
                exit 1
                ;;
            *)
                if [ -z "$OFFICE_CODE" ]; then
                    OFFICE_CODE="$1"
                else
                    print_error "Unexpected argument: $1"
                    echo 'Usage: sudo bash -c \"$(wget -qO- http://ontrack.link/joindomain)\"'
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
        echo "  Example: EP1"
        echo ""
        while [ -z "$OFFICE_CODE" ]; do
            read -r -p "  Office code: " OFFICE_CODE
            OFFICE_CODE="$(echo "$OFFICE_CODE" | tr '[:lower:]' '[:upper:]' | xargs)"
        done
    fi

    # Normalize and persist the selected office code for future reruns.
    OFFICE_CODE="$(echo "$OFFICE_CODE" | tr '[:lower:]' '[:upper:]' | xargs)"
    umask 022
    cat > "$STATE_FILE" << EOF
# Saved by domain-join.sh
OFFICE_CODE="$OFFICE_CODE"
EOF
    chmod 644 "$STATE_FILE"
    chown root:root "$STATE_FILE"

    TOOLS_SERVER="dr-$(echo "$OFFICE_CODE" | tr '[:upper:]' '[:lower:]')-tools"
    print_info "Office: $OFFICE_CODE — tools server: $TOOLS_SERVER"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo "=========================================="
  echo "  DR Domain Join"
  echo "  Version ${SCRIPT_VERSION}"
  echo "=========================================="
    echo ""

    load_state || true
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
    check_privileges
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
    configure_autofs_cifs
    configure_sudoers
    configure_samba
    configure_wins_resolution
    enable_winbind
    check_display_manager

    if verify_join; then
        echo ""
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
