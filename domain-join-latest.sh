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
#   Debian/Ubuntu preserve DHCP/VPN DNS and apply the required corporate search
#   list. On Arch, a resolver that already passes AD SRV discovery is preserved;
#   otherwise the selected office's configured fallback servers are validated
#   before NetworkManager is changed.
#
# Optional override:
#   If DHCP does not provide usable AD DNS, create domain-join.conf next to this
#   script and set DNS_SERVERS="10.x.x.x 10.x.x.x". Arch may also use
#   office-specific DR_DNS_SERVERS_<OFFICE> and DR_TIME_SERVERS_<OFFICE>
#   mappings; only the selected office's validated fallback is applied.
#
# Test mode:
#   wget -qO- http://ontrack.link/joindomain | sudo bash -s -- --dns-test
#   Applies DNS/search settings and runs realm discovery without joining.
#
# Supported Systems:
#   - Debian 13 or newer
#   - Ubuntu 22.04 or newer
#

SCRIPT_VERSION="1.3.0-cachyos-samba-systemd-candidate"
APT_BACKGROUND_GUARD_ACTIVE=0
APT_BACKGROUND_STOPPED_UNITS=""
STATE_DIR="${DR_JOIN_STATE_DIR:-/var/lib/dr-domain-join}"
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
PLATFORM_REPORT_ONLY=false
PREFLIGHT_ONLY=false
DRY_RUN_ONLY=false
PLATFORM_FAMILY=""
PLATFORM_SUPPORTED=false
PLATFORM_PACKAGE_MANAGER=""
PLATFORM_VERSION=""
PLATFORM_DESKTOP=""
PLATFORM_DISPLAY_MANAGER=""
DISPLAY_MANAGER_RUNNING=false
PLATFORM_ADMIN_GROUP=""
PLATFORM_REPORT_BLOCKERS=0
PREFLIGHT_BLOCKERS=0
OS_RELEASE_FILE="${DR_JOIN_OS_RELEASE_FILE:-/etc/os-release}"
KIT_PROCESS_PATTERN="${KIT_PROCESS_PATTERN:-KIT}"
KIT_INSTALLER_PATH="${KIT_INSTALLER_PATH:-/mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/KIT-installer-modified.sh}"
BRAND_WALLPAPER_SOURCE="${BRAND_WALLPAPER_SOURCE:-/mnt/x/CRtools/Frozen/Branding/Wallpaper/1080p_ontrackwallpaper.jpg}"
BRAND_WALLPAPER_DEST="/usr/share/backgrounds/dr-company-wallpaper"
OFFICE_CODE=""
TOOLS_SERVER=""
CONFIG_FILE="/etc/domain-join.conf"
DR_WORKSTATION_USERS_GROUP="dr-workstation-users"
DR_WORKSTATION_ADMINS_GROUP="dr-workstation-admins"
DR_LOCAL_ADMIN_USER="${DR_LOCAL_ADMIN_USER:-drone}"
DR_DNS_SERVERS_EP1="${DR_DNS_SERVERS_EP1:-10.59.4.201 10.59.4.202}"
DR_TIME_SERVERS_EP1="${DR_TIME_SERVERS_EP1:-10.59.4.201 10.59.4.202}"
DR_DNS_SERVERS="${DR_DNS_SERVERS:-}"
DR_TIME_SERVERS="${DR_TIME_SERVERS:-}"
DR_TIMESYNCD_DROPIN="${DR_TIMESYNCD_DROPIN:-/etc/systemd/timesyncd.conf.d/90-dr-domain.conf}"
# The production workflow depends on KIT/IOLib DRIP paths. Arch provides only
# configured /smb/server/share roots through systemd automount units; arbitrary
# dynamic /smb or /net paths remain unsupported. A candidate may opt into
# KIT-only validation with DRIP_REQUIRED=false, but completion remains blocked
# when configured DRIP roots are required and unvalidated.
DRIP_REQUIRED="${DRIP_REQUIRED:-true}"
DR_DRIP_SEARCH_ROOTS="${DR_DRIP_SEARCH_ROOTS:-dr-ep-drip04/Images}"
DR_DRIP_MANIFEST="${DR_DRIP_MANIFEST:-/var/lib/dr-domain-join/drip-units.manifest}"
DR_DRIP_UNIT_DIR="${DR_DRIP_UNIT_DIR:-/etc/systemd/system}"
DR_DRIP_HELPER_PATH="${DR_DRIP_HELPER_PATH:-/usr/local/sbin/dr-drip-search}"
# A systemd .mount unit is generated before a user accesses /mnt/x, so it
# needs the UID of the domain user's Kerberos cache at generation time.  The
# normal path derives this from DOMAIN_SUDO_USER; an explicit UID is useful for
# a staged candidate run and is safe to store because it is not a credential.
DR_TOOLS_MOUNT_CRUID="${DR_TOOLS_MOUNT_CRUID:-}"
DR_CIFS_MODULES_ROOT="${DR_CIFS_MODULES_ROOT:-/usr/lib/modules}"
DR_CIFS_PROC_FILESYSTEMS="${DR_CIFS_PROC_FILESYSTEMS:-/proc/filesystems}"
DR_LOCAL_KEYTAB="${DR_LOCAL_KEYTAB:-/etc/krb5.keytab}"
DR_SAMBA_SECRETS_TDB="${DR_SAMBA_SECRETS_TDB:-/var/lib/samba/private/secrets.tdb}"
ARCH_SSSD_DEFAULT_SHELL="${ARCH_SSSD_DEFAULT_SHELL:-/bin/bash}"
DR_SUPPORTED_SHELLS_FILE="${DR_SUPPORTED_SHELLS_FILE:-/etc/shells}"
JOIN_LIFECYCLE="${JOIN_LIFECYCLE:-NEW_JOIN}"

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
        print_info "Configuration loaded; explicit DNS override enabled: $DNS_SERVERS"
    else
        print_info "No explicit DNS override configured; preserving working DNS or using the selected office fallback"
    fi
}

# ── Privilege check ───────────────────────────────────────────────────────────

check_privileges() {
    if [ "$EUID" -ne 0 ]; then
        local arg
        for arg in "$@"; do
            case "$arg" in
                --platform-report|--preflight|--dry-run)
                    print_warning "Read-only mode selected; root is not required"
                    return 0
                    ;;
            esac
        done
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
    [ -f "$STATE_FILE" ] && grep -q '^STAGE="POSTJOIN_COMPLETE"$' "$STATE_FILE" 2>/dev/null || return 1
    ! state_identity_contradiction
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
        echo "    su - $DR_LOCAL_ADMIN_USER"
        echo ""
        echo "  Enter the local $DR_LOCAL_ADMIN_USER account password, then run:"
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

    # Read-only inspection modes must remain read-only even on a completed
    # workstation. They are allowed to report the managed-workstation state,
    # but must not refresh the management command or sudo policy.
    if [ "$PLATFORM_REPORT_ONLY" = true ] || [ "$PREFLIGHT_ONLY" = true ] || [ "$DRY_RUN_ONLY" = true ]; then
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

# ── Platform adapter layer ──────────────────────────────────────────────────
#
# Keep distro-specific package, service, PAM, and desktop behavior here. The
# shared provisioning workflow below should depend on logical capabilities
# rather than individual distribution names. Fedora is recognized so it can
# receive a clear unsupported result later, but has no implementation here.

PLATFORM_CAPABILITIES=(
    realmd sssd sssd-tools adcli kerberos samba smbclient cifs autofs time-sync
    networkmanager dns ldap sudo pam home-directory ssh-server winbind desktop-helper
)

platform_capability_class() {
    case "$1" in
        sssd|kerberos|pam|home-directory|sudo|time-sync) echo "core AD login" ;;
        samba|smbclient) echo "Arch join backend" ;;
        sssd-tools) echo "diagnostics only" ;;
        cifs) echo "Tool Server mounting" ;;
        realmd|adcli|autofs|ldap|dns|networkmanager|time-sync|ssh-server|winbind) echo "diagnostics/platform support" ;;
        desktop-helper) echo "optional desktop integration" ;;
        *) echo "shared capability" ;;
    esac
}

platform_capability_required() {
    local capability="$1"
    case "$PLATFORM_FAMILY:$capability" in
        arch:realmd|arch:adcli|arch:autofs|arch:winbind|arch:ldap|arch:sssd-tools|arch:desktop-helper)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# DRIP is a path contract, not merely a CIFS capability. Debian retains its
# dynamic autofs implementation. Arch implements only explicitly configured
# /smb/server/share roots; arbitrary dynamic roots remain unsupported.
platform_drip_supported() {
    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        return 0
    fi
    [ "$PLATFORM_FAMILY" = "arch" ] || return 1
    platform_validate_drip_search_roots >/dev/null 2>&1
}

platform_drip_path_supported() {
    local path="${1:-}"
    case "$path" in
        /smb/*)
            local relative entry
            [ "$PLATFORM_FAMILY" = "debian" ] && return 0
            relative="${path#/smb/}"
            platform_validate_drip_search_roots >/dev/null 2>&1 || return 1
            while IFS= read -r entry; do
                case "$relative" in
                    "$entry"|"$entry"/*) return 0 ;;
                esac
            done < <(platform_drip_search_entries)
            return 1
            ;;
        /net/*) [ "$PLATFORM_FAMILY" = "debian" ] ;;
        *) return 1 ;;
    esac
}

platform_drip_requirement_satisfied() {
    [ "$DRIP_REQUIRED" != true ] || platform_drip_supported
}

platform_drip_search_entries() {
    local roots="${DR_DRIP_SEARCH_ROOTS:-}"
    [ -n "$roots" ] || return 0
    case "$roots" in
        *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    # Configuration is whitespace-delimited. Validation rejects whitespace
    # inside an individual server/share entry, so this cannot split a valid
    # component ambiguously.
    read -r -a _drip_entries <<< "$roots"
    printf '%s\n' "${_drip_entries[@]}"
}

validate_drip_search_root_entry() {
    local entry="${1:-}"
    local server share extra
    case "$entry" in
        ''|*[$'\t\r\n ']*|*\\*|*..*|*[\'\"\$\`\;\|\&\<\>\(\)\{\}\[\]]*) return 1 ;;
    esac
    IFS=/ read -r server share extra <<< "$entry"
    [ -n "$server" ] && [ -n "$share" ] && [ -z "${extra:-}" ] || return 1
    printf '%s\n' "$server" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$' || return 1
    printf '%s\n' "$share" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || return 1
    return 0
}

platform_validate_drip_search_roots() {
    local entry count=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        validate_drip_search_root_entry "$entry" || return 1
        count=$((count + 1))
    done < <(platform_drip_search_entries)
    [ "$count" -gt 0 ]
}

platform_validate_drip_requirement() {
    if platform_drip_supported; then
        if [ "$PLATFORM_FAMILY" = "debian" ]; then
            preflight_pass "DRIP dynamic paths are provided by the Debian autofs adapter"
        else
            preflight_pass "Configured Arch DRIP roots are syntactically valid; live DRIP validation remains required"
        fi
        return 0
    fi

    if [ "$DRIP_REQUIRED" = true ]; then
        preflight_blocked "Arch DRIP configuration is invalid or empty; configured-root /smb support cannot be enabled"
        return 1
    fi

    preflight_warning "Arch configured-root DRIP is invalid or empty; no /smb roots will be generated (DRIP_REQUIRED=false)"
    return 0
}

platform_detect_desktop() {
    local desktop="${XDG_CURRENT_DESKTOP:-}"

    if [ -z "$desktop" ] && command -v loginctl >/dev/null 2>&1; then
        desktop="$(loginctl show-session "${XDG_SESSION_ID:-}" -p Desktop --value 2>/dev/null || true)"
    fi
    if [ -z "$desktop" ] && [ -d /usr/share/plasma ]; then
        desktop="KDE"
    elif [ -z "$desktop" ] && [ -d /usr/share/gnome-shell ]; then
        desktop="GNOME"
    fi

    case "${desktop,,}" in
        *kde*|*plasma*) PLATFORM_DESKTOP="KDE Plasma" ;;
        *gnome*) PLATFORM_DESKTOP="GNOME" ;;
        *xfce*) PLATFORM_DESKTOP="XFCE" ;;
        *mate*) PLATFORM_DESKTOP="MATE" ;;
        "") PLATFORM_DESKTOP="Unknown" ;;
        *) PLATFORM_DESKTOP="$desktop" ;;
    esac
}

platform_detect_display_manager() {
    local manager_id
    manager_id="$(systemctl show display-manager.service -p Id --value 2>/dev/null || true)"
    case "$manager_id" in
        *.service) PLATFORM_DISPLAY_MANAGER="$manager_id" ;;
        *) PLATFORM_DISPLAY_MANAGER="Unknown" ;;
    esac
}

platform_validate_version() {
    case "$PLATFORM_FAMILY" in
        arch)
            # Arch-family releases are rolling. CachyOS may expose BUILD_ID
            # rather than a numeric VERSION_ID, so no numeric minimum applies.
            return 0
            ;;
        debian)
            case "$OS" in
                ubuntu)
                    [ -n "${VER:-}" ] || return 1
                    [ "$(printf '%s\n' "$VER" "22.04" | sort -V | head -1)" = "22.04" ]
                    ;;
                debian)
                    [ -n "${VER:-}" ] || return 1
                    [ "$(printf '%s\n' "$VER" "13" | sort -V | head -1)" = "13" ]
                    ;;
                *) return 1 ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

detect_platform() {
    if [ ! -f "$OS_RELEASE_FILE" ]; then
        print_error "Cannot detect platform. $OS_RELEASE_FILE not found."
        return 1
    fi

    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"
    OS="${ID:-unknown}"
    VER="${VERSION_ID:-${BUILD_ID:-rolling}}"
    PLATFORM_VERSION="$VER"
    PLATFORM_FAMILY=""

    case "$OS" in
        ubuntu|debian) PLATFORM_FAMILY="debian" ;;
        arch|cachyos) PLATFORM_FAMILY="arch" ;;
        fedora) PLATFORM_FAMILY="fedora" ;;
    esac

    if [ -z "$PLATFORM_FAMILY" ]; then
        for family in $ID_LIKE; do
            case "$family" in
                debian) PLATFORM_FAMILY="debian"; break ;;
                arch) PLATFORM_FAMILY="arch"; break ;;
                fedora|rhel) PLATFORM_FAMILY="fedora"; break ;;
            esac
        done
    fi

    PLATFORM_SUPPORTED=false
    case "$PLATFORM_FAMILY" in
        debian|arch) PLATFORM_SUPPORTED=true ;;
        fedora) PLATFORM_SUPPORTED=false ;;
        *) PLATFORM_FAMILY="unknown" ;;
    esac

    case "$PLATFORM_FAMILY" in
        debian) PLATFORM_PACKAGE_MANAGER="apt" ;;
        arch) PLATFORM_PACKAGE_MANAGER="pacman" ;;
        *) PLATFORM_PACKAGE_MANAGER="unknown" ;;
    esac

    platform_detect_desktop
    platform_detect_display_manager
    if ! platform_validate_version; then
        PLATFORM_SUPPORTED=false
    fi
}

detect_os() {
    detect_platform || return 1

    if [ "$PLATFORM_SUPPORTED" != true ]; then
        print_error "Unsupported platform: ID=${OS:-unknown} ID_LIKE=${ID_LIKE:-unknown} VERSION=${VER:-unknown}"
        if [ "$PLATFORM_FAMILY" = "fedora" ]; then
            print_error "Fedora-family support is reserved for a future adapter implementation."
        else
            print_error "Supported families in this candidate are Debian/Ubuntu and Arch/CachyOS."
        fi
        return 1
    fi

    print_info "Detected platform: $OS $VER (family=$PLATFORM_FAMILY, desktop=$PLATFORM_DESKTOP, display-manager=$PLATFORM_DISPLAY_MANAGER)"
}

platform_package_name() {
    local capability="$1"

    case "$PLATFORM_FAMILY:$capability" in
        debian:realmd) echo "realmd" ;;
        debian:sssd) echo "sssd" ;;
        debian:sssd-tools) echo "sssd-tools" ;;
        debian:adcli) echo "adcli" ;;
        debian:kerberos) echo "krb5-user" ;;
        debian:samba) echo "samba-common-bin" ;;
        debian:smbclient) echo "smbclient" ;;
        debian:cifs) echo "cifs-utils" ;;
        debian:autofs) echo "autofs" ;;
        debian:time-sync) echo "chrony" ;;
        debian:networkmanager) echo "network-manager" ;;
        debian:dns) echo "dnsutils" ;;
        debian:ldap) echo "ldap-utils" ;;
        debian:sudo) echo "sudo" ;;
        debian:pam) echo "libpam-modules" ;;
        debian:home-directory)
            if [ "$OS" = "debian" ]; then echo "oddjob-mkhomedir"; else echo "libpam-mkhomedir"; fi
            ;;
        debian:ssh-server) echo "openssh-server" ;;
        debian:desktop-helper) echo "xdg-utils" ;;
        debian:winbind) echo "winbind" ;;
        debian:packagekit) echo "packagekit" ;;
        debian:update-policy) echo "unattended-upgrades" ;;
        arch:realmd) ;;
        arch:sssd) echo "sssd" ;;
        # Arch packages sssctl with sssd when present; verify the command
        # after installation because no separate sssd-tools package exists.
        arch:sssd-tools) echo "sssd" ;;
        arch:adcli) ;;
        arch:kerberos) echo "krb5" ;;
        arch:samba) echo "samba" ;;
        arch:smbclient) echo "smbclient" ;;
        arch:cifs) echo "cifs-utils" ;;
        arch:autofs) ;;
        arch:time-sync) echo "chrony" ;;
        arch:networkmanager) echo "networkmanager" ;;
        arch:dns) echo "bind" ;;
        arch:ldap) echo "openldap" ;;
        arch:sudo) echo "sudo" ;;
        arch:pam) echo "pam" ;;
        arch:home-directory) echo "pam" ;;
        arch:ssh-server) echo "openssh" ;;
        arch:desktop-helper) echo "xdg-utils" ;;
        # The Arch backend uses Samba's net utility and SSSD. Winbind is not
        # started or enabled, so it is intentionally not a dependency.
        arch:winbind) ;;
        *) ;;
    esac
}

platform_is_package_installed() {
    local package="$1"
    [ -n "$package" ] || return 1

    case "$PLATFORM_FAMILY" in
        debian)
            dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -q '^install ok installed$'
            ;;
        arch)
            pacman -Qq "$package" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

platform_is_package_available() {
    local package="$1"
    [ -n "$package" ] || return 1

    case "$PLATFORM_FAMILY" in
        debian) apt-cache show "$package" >/dev/null 2>&1 ;;
        arch) pacman -Si "$package" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

platform_prepare_package_manager() {
    case "$PLATFORM_FAMILY" in
        debian)
            wait_for_apt_locks
            ;;
        arch)
            local newest_db now age
            newest_db="$(stat -c '%Y' /var/lib/pacman/sync/*.db 2>/dev/null | sort -nr | head -1 || true)"
            now="$(date +%s)"
            if [ -n "$newest_db" ]; then
                age=$((now - newest_db))
                if [ "$age" -gt 604800 ]; then
                    print_warning "pacman sync databases are ${age}s old; no automatic pacman -Syu or database refresh will be performed"
                fi
            else
                print_error "No pacman sync database is available"
                return 1
            fi
            ;;
        *)
            print_error "No package-manager adapter exists for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
}

platform_install_package() {
    local capability="$1"
    local package
    package="$(platform_package_name "$capability")"

    if [ -z "$package" ]; then
        print_error "No package mapping exists for capability '$capability' on $PLATFORM_FAMILY"
        return 1
    fi
    if platform_is_package_installed "$package"; then
        print_info "$capability: $package is already installed"
        return 0
    fi
    if ! platform_is_package_available "$package"; then
        print_error "Required package '$package' for capability '$capability' is unavailable in configured repositories"
        return 1
    fi

    case "$PLATFORM_FAMILY" in
        debian) install_package "$package" ;;
        arch)
            platform_prepare_package_manager || return 1
            print_info "Installing $package with pacman --needed (no full-system upgrade)"
            pacman -S --needed --noconfirm "$package"
            ;;
        *) return 1 ;;
    esac
}

platform_install_packages() {
    local capability
    platform_prepare_package_manager || return 1
    for capability in "$@"; do
        if [ "$capability" = "time-sync" ] && platform_time_provider_satisfies; then
            print_info "time-sync: existing supported provider $(platform_time_provider active) is already available"
            continue
        fi
        platform_install_package "$capability" || return 1
    done
}

platform_service_name() {
    case "$PLATFORM_FAMILY:$1" in
        arch:time-sync) echo "chronyd" ;;
        debian:time-sync) echo "chrony" ;;
        arch:ssh-server) echo "sshd" ;;
        debian:ssh-server) echo "ssh" ;;
        *) echo "$1" ;;
    esac
}

platform_enable_service() {
    local capability="$1"
    local service
    service="$(platform_service_name "$capability")"
    systemctl enable --now "$service"
}

platform_admin_group() {
    case "$PLATFORM_FAMILY" in
        arch)
            PLATFORM_ADMIN_GROUP="wheel"
            ;;
        debian)
            if getent group sudo >/dev/null 2>&1; then
                PLATFORM_ADMIN_GROUP="sudo"
            else
                PLATFORM_ADMIN_GROUP="adm"
            fi
            ;;
        *) PLATFORM_ADMIN_GROUP="" ;;
    esac
    printf '%s\n' "$PLATFORM_ADMIN_GROUP"
}

platform_desktop_integration() {
    case "$PLATFORM_DESKTOP" in
        "GNOME") echo "GNOME best-effort dconf/gsettings integration" ;;
        "KDE Plasma") echo "KDE Plasma: preserve user preferences; desktop files only" ;;
        *) echo "Unsupported desktop: core provisioning continues; customization skipped" ;;
    esac
}

platform_validate_auth_stack() {
    local failed=0
    case "$PLATFORM_FAMILY" in
        arch)
            for file in /etc/pam.d/system-auth /etc/pam.d/system-login; do
                [ -f "$file" ] || failed=1
            done
            [ -f /usr/lib/security/pam_mkhomedir.so ] || failed=1
            ;;
        debian)
            [ -f /etc/pam.d/common-auth ] || failed=1
            [ -f /etc/pam.d/common-account ] || failed=1
            [ -f /etc/pam.d/common-session ] || failed=1
            ;;
        *) failed=1 ;;
    esac
    return "$failed"
}

platform_validate_cifs_kernel() {
    [ "$PLATFORM_FAMILY" = arch ] || return 0
    local running_kernel="$(uname -r)"
    local module_tree="$DR_CIFS_MODULES_ROOT/$running_kernel"
    if [ ! -d "$module_tree" ]; then
        preflight_blocked "Running kernel $running_kernel has no matching module tree."
        preflight_blocked "Installed kernel packages have changed since boot. Reboot into the installed kernel before continuing."
        return 1
    fi
    if grep -Eq '(^|[[:space:]])cifs([[:space:]]|$)' "$DR_CIFS_PROC_FILESYSTEMS" 2>/dev/null; then
        preflight_pass "CIFS is built into the running kernel $running_kernel"
        return 0
    fi
    if command -v modinfo >/dev/null 2>&1 && modinfo -k "$running_kernel" cifs >/dev/null 2>&1; then
        preflight_pass "CIFS module is available for the running kernel $running_kernel"
        return 0
    fi
    preflight_blocked "CIFS is neither built into nor loadable for the running kernel $running_kernel"
    return 1
}

platform_cifs_kernel_is_ready() {
    [ "$PLATFORM_FAMILY" = arch ] || return 0
    local running_kernel="$(uname -r)"
    [ -d "$DR_CIFS_MODULES_ROOT/$running_kernel" ] || return 1
    grep -Eq '(^|[[:space:]])cifs([[:space:]]|$)' "$DR_CIFS_PROC_FILESYSTEMS" 2>/dev/null && return 0
    command -v modinfo >/dev/null 2>&1 && modinfo -k "$running_kernel" cifs >/dev/null 2>&1
}

backup_config_file() {
    local file="$1"
    local backup
    [ -e "$file" ] || return 0
    backup="${file}.domain-join.bak.$(date +%Y%m%d%H%M%S)"
    cp -a -- "$file" "$backup"
    chmod --reference="$file" "$backup" 2>/dev/null || true
    print_info "Backed up $file to $backup"
}

platform_capability_status() {
    local capability="$1"
    local package
    if [ "$capability" = "time-sync" ] && platform_time_provider_satisfies; then
        printf 'PASS|%s|existing selected provider is active or enabled (%s)' "$capability" "$(platform_time_provider selected)"
        return 0
    fi
    package="$(platform_package_name "$capability")"
    if [ -z "$package" ]; then
        if platform_capability_required "$capability"; then
            printf 'BLOCKED|%s|no configured-repository mapping' "$capability"
        else
            printf 'WARNING|%s|unavailable but no longer required on %s' "$capability" "$PLATFORM_FAMILY"
        fi
    elif platform_is_package_installed "$package"; then
        printf 'PASS|%s|%s installed' "$capability" "$package"
    elif platform_is_package_available "$package"; then
        if platform_capability_required "$capability"; then
            printf 'WARNING|%s|%s available but not installed' "$capability" "$package"
        else
            printf 'WARNING|%s|%s available but not installed (optional/diagnostic)' "$capability" "$package"
        fi
    else
        if platform_capability_required "$capability"; then
            printf 'BLOCKED|%s|%s unavailable in configured repositories' "$capability" "$package"
        else
            printf 'WARNING|%s|%s unavailable but no longer required' "$capability" "$package"
        fi
    fi
}

platform_report() {
    local capability status name detail package_db display_package
    PLATFORM_REPORT_BLOCKERS=0
    platform_admin_group >/dev/null

    package_db="unknown"
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        package_db="$(stat -c '%y' /var/lib/pacman/sync/*.db 2>/dev/null | sort -r | head -1 || echo unavailable)"
    elif [ "$PLATFORM_FAMILY" = "debian" ]; then
        package_db="apt metadata directory: /var/lib/apt/lists"
    fi

    echo "Platform report"
    echo "  Distro:              ${OS:-unknown}"
    echo "  Platform family:     ${PLATFORM_FAMILY:-unknown}"
    echo "  Version:             ${PLATFORM_VERSION:-unknown}"
    echo "  Supported:           ${PLATFORM_SUPPORTED}"
    echo "  Desktop:             ${PLATFORM_DESKTOP:-Unknown}"
    echo "  Display manager:     ${PLATFORM_DISPLAY_MANAGER:-Unknown}"
    echo "  Package manager:     ${PLATFORM_PACKAGE_MANAGER:-unknown}"
    echo "  Package-manager DB:  $package_db"
    echo "  Administrator group: ${PLATFORM_ADMIN_GROUP:-unavailable}"
    echo "  Resolver:            $(if systemctl is-active --quiet systemd-resolved 2>/dev/null; then echo systemd-resolved; else echo /etc/resolv.conf; fi)"
    echo "  Time provider:       $(platform_time_provider active)"
    echo "  Time enabled:        $(platform_time_provider enabled)"
    echo "  Desktop adapter:     $(platform_desktop_integration)"
    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        echo "  DRIP support:        supported via dynamic Debian autofs (/smb and /net)"
    elif platform_drip_supported; then
        echo "  DRIP support:        configured-root Arch systemd automounts (/smb only)"
        echo "  DRIP search roots:   ${DR_DRIP_SEARCH_ROOTS:-none}"
        echo "  DRIP scope:          arbitrary dynamic /smb and /net paths are unsupported"
    else
        echo "  DRIP support:        BLOCKED (configured Arch roots are invalid or unavailable)"
    fi
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        echo "  /mnt/x ownership:    selected domain-user UID; explicit dr-tools-rebind required when users change"
    fi
    echo "  DRIP required:       $DRIP_REQUIRED"
    echo ""
    echo "Capability/package mapping"
    for capability in "${PLATFORM_CAPABILITIES[@]}"; do
        IFS='|' read -r status name detail <<< "$(platform_capability_status "$capability")"
        display_package="$(platform_package_name "$name")"
        if [ "$name" = time-sync ] && [ "$(platform_time_provider selected)" != none ]; then
            display_package="$(platform_time_provider selected)"
        fi
        printf '  %-8s %-18s %-28s %s (%s)\n' "$status" "$name" "$(platform_capability_class "$name")" "$detail" "$display_package"
        [ "$status" = "BLOCKED" ] && PLATFORM_REPORT_BLOCKERS=$((PLATFORM_REPORT_BLOCKERS + 1))
    done
    echo ""
    if [ "$PLATFORM_SUPPORTED" = true ] && [ "$PLATFORM_REPORT_BLOCKERS" -eq 0 ]; then
        echo "PASS Supported platform and configured-repository capability map"
    elif [ "$PLATFORM_SUPPORTED" = true ]; then
        echo "BLOCKED Supported platform has unavailable or unmapped capabilities"
    else
        echo "BLOCKED Platform is unsupported or not implemented"
    fi
}

platform_time_provider() {
    local mode="${1:-active}"
    local service

    if [ "$mode" = "selected" ]; then
        service="$(platform_time_provider active)"
        if [ "$service" != none ]; then
            echo "$service"
            return 0
        fi
        service="$(platform_time_provider enabled)"
        [ "$service" != none ] && echo "$service" || echo none
        return 0
    elif [ "$mode" = "enabled" ]; then
        for service in chronyd chrony systemd-timesyncd; do
            if systemctl is-enabled --quiet "$service" 2>/dev/null; then
                echo "$service"
                return 0
            fi
        done
    else
        for service in chronyd chrony systemd-timesyncd; do
            if systemctl is-active --quiet "$service" 2>/dev/null; then
                echo "$service"
                return 0
            fi
        done
    fi

    echo "none"
}

platform_time_provider_satisfies() {
    [ "$(platform_time_provider selected)" != none ]
}

platform_time_sources() {
    platform_office_server_list TIME
}

render_arch_timesyncd_dropin() {
    [ "$PLATFORM_FAMILY" = arch ] || return 1
    local sources
    sources="$(platform_time_sources)"
    platform_validate_server_list "$sources" || return 1
    cat << EOF
# Managed by DR Domain Join; vendor files under /usr/lib are not modified.
[Time]
NTP=
NTP=$sources
FallbackNTP=
EOF
}

platform_timesyncd_source_matches() {
    local status sources source
    sources="$(platform_time_sources)"
    platform_validate_server_list "$sources" || return 1
    status="$(timedatectl timesync-status 2>/dev/null || true)"
    [ -n "$status" ] || return 1
    for source in $sources; do
        if printf '%s\n' "$status" | grep -Fq -- "$source"; then
            return 0
        fi
    done
    return 1
}

platform_timesyncd_dropin_matches() {
    [ -f "$DR_TIMESYNCD_DROPIN" ] || return 1
    diff -q <(render_arch_timesyncd_dropin) "$DR_TIMESYNCD_DROPIN" >/dev/null 2>&1
}

platform_timesyncd_is_ready() {
    [ "$(platform_time_provider selected)" = systemd-timesyncd ] || return 1
    [ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)" = yes ] || return 1
    platform_timesyncd_source_matches
}

platform_wait_for_timesyncd() {
    local retries="${DR_TIME_SYNC_RETRIES:-6}"
    local delay="${DR_TIME_SYNC_RETRY_DELAY:-5}"
    local count=0
    while [ "$count" -lt "$retries" ]; do
        if platform_timesyncd_is_ready; then
            return 0
        fi
        count=$((count + 1))
        [ "$count" -lt "$retries" ] && sleep "$delay"
    done
    return 1
}

platform_configure_timesyncd() {
    [ "$PLATFORM_FAMILY" = arch ] || return 0
    if [ "${1:-}" != force ] && [ "$(platform_time_provider selected)" != systemd-timesyncd ]; then
        return 0
    fi
    local target="$DR_TIMESYNCD_DROPIN"
    local directory staged rollback_copy old_exists=0
    directory="$(dirname "$target")"
    mkdir -p "$directory" || return 1
    staged="$(mktemp "$directory/.90-dr-domain.conf.XXXXXX")" || return 1
    rollback_copy="$(mktemp "$directory/.90-dr-domain.rollback.XXXXXX")" || {
        rm -f -- "$staged"
        return 1
    }
    rm -f -- "$rollback_copy"

    if [ -e "$target" ] || [ -L "$target" ]; then
        old_exists=1
        cp -a -- "$target" "$rollback_copy" || {
            rm -f -- "$staged" "$rollback_copy"
            return 1
        }
    fi
    render_arch_timesyncd_dropin > "$staged" || {
        rm -f -- "$staged" "$rollback_copy"
        return 1
    }
    chmod 644 "$staged"
    chown root:root "$staged" 2>/dev/null || true

    if cmp -s "$staged" "$target" 2>/dev/null; then
        rm -f -- "$staged" "$rollback_copy"
        if command -v systemd-analyze >/dev/null 2>&1; then
            systemd-analyze cat-config systemd/timesyncd.conf >/dev/null 2>&1 || return 1
        fi
        return 0
    fi

    backup_config_file "$target"
    mv -f -- "$staged" "$target" || {
        rm -f -- "$staged" "$rollback_copy"
        return 1
    }
    if command -v systemd-analyze >/dev/null 2>&1 && ! systemd-analyze cat-config systemd/timesyncd.conf >/dev/null 2>&1; then
        if [ "$old_exists" -eq 1 ]; then
            rm -f -- "$target"
            cp -a -- "$rollback_copy" "$target"
        else
            rm -f -- "$target"
        fi
        rm -f -- "$rollback_copy"
        return 1
    fi

    if ! systemctl restart systemd-timesyncd >/dev/null 2>&1 || ! platform_wait_for_timesyncd; then
        if [ "$old_exists" -eq 1 ]; then
            rm -f -- "$target"
            cp -a -- "$rollback_copy" "$target"
        else
            rm -f -- "$target"
        fi
        systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
        rm -f -- "$rollback_copy"
        return 1
    fi
    rm -f -- "$rollback_copy"
    return 0
}

platform_time_is_synchronized() {
    local ntp_synced
    ntp_synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
    [ "$ntp_synced" = yes ] && return 0
    chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'
}

platform_time_diagnostics() {
    local active enabled synced timesync_status chrony_tracking chrony_sources
    active="$(platform_time_provider active)"
    enabled="$(platform_time_provider enabled)"
    synced="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo unknown)"
    timesync_status="$(timedatectl timesync-status 2>/dev/null || true)"
    chrony_tracking="$(chronyc tracking 2>/dev/null || true)"
    chrony_sources="$(chronyc sources -v 2>/dev/null || true)"

    echo "Time synchronization diagnostics"
    echo "  Active provider:    $active"
    echo "  Enabled provider:   $enabled"
    echo "  Synchronized:       $synced"
    if [ -n "$timesync_status" ]; then
        echo "  systemd-timesyncd:"
        echo "$timesync_status" | sed 's/^/    /'
    fi
    if [ -n "$chrony_tracking" ]; then
        echo "  chrony tracking:"
        echo "$chrony_tracking" | sed 's/^/    /'
    fi
    if [ -n "$chrony_sources" ]; then
        echo "  chrony sources:"
        echo "$chrony_sources" | sed 's/^/    /'
    fi

    if [ "$(platform_time_provider selected)" = systemd-timesyncd ] && ! platform_timesyncd_source_matches; then
        echo "  Source availability: synchronized state is not tied to a configured corporate source"
        echo "  Kerberos impact:     BLOCKED — time source policy is not satisfied"
        echo "  Proposed correction: install $DR_TIMESYNCD_DROPIN with NTP reset, configured office sources, and FallbackNTP reset"
    elif platform_time_is_synchronized; then
        echo "  Source availability: synchronized source reported"
        echo "  Kerberos impact:     PASS"
        echo "  Proposed correction: none"
    else
        echo "  Source availability: no synchronized source is currently reported"
        echo "  Kerberos impact:     BLOCKED — clock skew can invalidate Kerberos"
        echo "  Proposed correction: operator-approved repair of the active provider"
        echo "                       after checking UDP/123 reachability and approved AD NTP sources"
        echo "                       (no provider switch or NTP change is performed automatically)"
    fi
}

platform_time_preflight_ready() {
    local selected_provider
    selected_provider="$(platform_time_provider selected)"
    [ "$selected_provider" != none ] || return 1
    if [ "$selected_provider" = systemd-timesyncd ]; then
        platform_validate_server_list "$(platform_time_sources)" || return 1
        [ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)" = yes ]
    else
        platform_time_is_synchronized
    fi
}

platform_break_glass_is_local() {
    awk -F: -v user="$DR_LOCAL_ADMIN_USER" '$1 == user { found=1 } END { exit(found ? 0 : 1) }' /etc/passwd 2>/dev/null
}

platform_validate_break_glass() {
    local admin_group="$1"
    local groups

    echo "Break-glass account: $DR_LOCAL_ADMIN_USER"
    if platform_break_glass_is_local; then
        echo "Source: local"
    else
        echo "Source: missing or not local"
        preflight_blocked "Break-glass account $DR_LOCAL_ADMIN_USER is not a local /etc/passwd account"
        return 1
    fi
    echo "Administrator group: ${admin_group:-unavailable}"
    echo "Password status: operator verification required"

    groups="$(id -nG "$DR_LOCAL_ADMIN_USER" 2>/dev/null || true)"
    if [ -n "$admin_group" ] && printf '%s\n' "$groups" | tr ' ' '\n' | grep -Fxq "$admin_group"; then
        preflight_pass "Break-glass account $DR_LOCAL_ADMIN_USER is in native administrator group $admin_group"
    else
        preflight_blocked "Break-glass account $DR_LOCAL_ADMIN_USER is not in native administrator group ${admin_group:-<unknown>}"
        return 1
    fi
    preflight_warning "Verify $DR_LOCAL_ADMIN_USER has a working local password and offline root access; no password test was performed"
    return 0
}

preflight_pass() { printf 'PASS %s\n' "$*"; }
preflight_warning() { printf 'WARNING %s\n' "$*"; }
preflight_blocked() { PREFLIGHT_BLOCKERS=$((PREFLIGHT_BLOCKERS + 1)); printf 'BLOCKED %s\n' "$*"; }

platform_preflight() {
    local current_host dns_output dns_source
    PREFLIGHT_BLOCKERS=0
    platform_report

    if state_requires_recovery; then
        preflight_blocked "Persisted join state contradicts the current hostname and active machine credentials are absent; recovery is required before provisioning"
    fi

    [ "$PLATFORM_SUPPORTED" = true ] || preflight_blocked "platform is not supported by this candidate"
    [ "$PLATFORM_REPORT_BLOCKERS" -eq 0 ] || preflight_blocked "$PLATFORM_REPORT_BLOCKERS required package capabilities are unavailable or unmapped"
    platform_validate_cifs_kernel || true
    platform_validate_drip_requirement || true

    if nmcli general status >/dev/null 2>&1; then
        preflight_pass "NetworkManager is queryable"
    else
        preflight_blocked "NetworkManager is unavailable or not queryable"
    fi

    dns_output="$(resolvectl status 2>/dev/null || true)"
    if echo "$dns_output" | grep -qE 'DNS Servers:|Current DNS Server:' || grep -qE '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null; then
        preflight_pass "A resolver and DNS server are configured"
    else
        preflight_blocked "No DNS server is visible in resolver state"
    fi

    if [ "$PLATFORM_FAMILY" = "arch" ] && command -v nmcli >/dev/null 2>&1; then
        local active_connection dns_search
        active_connection="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: '$2 != "" {print $1; exit}')"
        dns_search="$(nmcli -g ipv4.dns-search connection show "$active_connection" 2>/dev/null || true)"
        if platform_ad_dns_discovery_current && printf '%s\n' "$dns_search" | tr ',' '\n' | awk '{$1=$1; print}' | grep -Fxq "$DOMAIN"; then
            preflight_pass "Active NetworkManager connection preserves working AD DNS and search configuration"
        elif printf '%s\n' "$dns_search" | tr ',' '\n' | awk '{$1=$1; print}' | grep -Fxq "$DOMAIN"; then
            preflight_warning "Active NetworkManager connection advertises $DOMAIN but current resolver AD discovery is failing"
        else
            preflight_warning "Active NetworkManager connection does not yet advertise $DOMAIN; normal provisioning would propose the search-domain change"
        fi
    fi

    if [ "${DR_JOIN_TEST_MODE:-false}" = true ]; then
        preflight_warning "Fixture test mode: external DNS and realm probes skipped"
    elif [ "$PLATFORM_FAMILY" = arch ] && dns_source="$(platform_dns_discovery_source)"; then
        if [ "$dns_source" = current ]; then
            preflight_pass "AD DNS SRV discovery works using the current resolver"
        else
            preflight_pass "AD DNS SRV discovery works via the configured office fallback resolver(s)"
        fi
    elif platform_dns_srv_records "_kerberos._tcp.$DOMAIN" | grep -q .; then
        preflight_pass "Kerberos SRV discovery works for $DOMAIN"
    else
        if [ "$PLATFORM_FAMILY" = arch ]; then
            preflight_blocked "AD DNS SRV discovery failed using the current resolver and configured office fallback resolver(s)"
        else
            preflight_blocked "Kerberos SRV discovery failed for $DOMAIN"
        fi
    fi

    platform_time_diagnostics
    if platform_time_preflight_ready; then
        if [ "$(platform_time_provider selected)" = systemd-timesyncd ]; then
            if platform_timesyncd_source_matches; then
                preflight_pass "System clock is synchronized via systemd-timesyncd to a configured corporate source"
            else
                preflight_pass "System clock is synchronized via systemd-timesyncd"
                preflight_warning "Current timesyncd source is not one of the configured corporate sources; the modifying path will install/verify the office override"
            fi
        else
            preflight_pass "System clock is synchronized via $(platform_time_provider selected)"
        fi
    else
        if [ "$(platform_time_provider selected)" = systemd-timesyncd ]; then
            preflight_blocked "systemd-timesyncd is not synchronized to a configured corporate source"
        else
            preflight_blocked "System clock is not synchronized; no time repair will be attempted"
        fi
    fi

    current_host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
    if is_valid_ad_hostname "$current_host"; then
        preflight_pass "Current hostname is AD-safe: $current_host"
    else
        preflight_warning "Current hostname is not AD-safe and will require an explicit hostname-policy decision: ${current_host:-unknown}"
    fi

    if [ "${DR_JOIN_TEST_MODE:-false}" = true ]; then
        preflight_warning "Fixture test mode: domain discovery skipped"
    elif platform_domain_discover; then
        preflight_pass "Arch Samba or Debian realm discovery works for $DOMAIN"
    else
        preflight_blocked "Domain discovery failed for $DOMAIN"
    fi

    local required_commands=(kinit smbclient mount.cifs visudo host)
    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        required_commands+=(realm adcli automount)
    else
        required_commands+=(net testparm ldapsearch systemd-escape systemd-analyze findmnt)
    fi
    for command_name in "${required_commands[@]}"; do
        if command -v "$command_name" >/dev/null 2>&1; then
            preflight_pass "Required command available: $command_name"
        else
            preflight_blocked "Required command unavailable: $command_name"
        fi
    done

    local diagnostic_commands=(ldapsearch sssctl)
    [ "$PLATFORM_FAMILY" = arch ] && diagnostic_commands=(sssctl)
    for command_name in "${diagnostic_commands[@]}"; do
        if command -v "$command_name" >/dev/null 2>&1; then
            preflight_pass "Diagnostic/post-install command available: $command_name"
        elif [ "$PLATFORM_FAMILY" = "arch" ] && { [ "$command_name" = ldapsearch ] || [ "$command_name" = sssctl ]; }; then
            preflight_warning "$command_name is pending an available package and is not required for the Arch join command"
        else
            preflight_blocked "Required diagnostic command unavailable: $command_name"
        fi
    done

    if platform_validate_auth_stack; then
        preflight_pass "Native PAM/authentication stack is present"
    else
        preflight_blocked "Native PAM/authentication stack is incomplete"
    fi

    if [ -r "$STATE_FILE" ]; then
        preflight_pass "Persistent state file exists and is readable: $STATE_FILE"
    elif [ -f "$STATE_FILE" ]; then
        preflight_warning "Persistent state file exists but is not readable by this user: $STATE_FILE"
    else
        preflight_warning "No persistent state file exists yet: $STATE_FILE"
    fi

    if platform_domain_is_joined; then
        preflight_pass "Existing domain membership is present and machine-account probing completed"
    else
        preflight_pass "No existing domain membership detected; first-stage join path applies"
    fi
    platform_admin_group >/dev/null
    platform_validate_break_glass "$PLATFORM_ADMIN_GROUP" || true

    if [ "$(df -Pk / | awk 'NR==2 {print $4}')" -ge 5242880 ] 2>/dev/null; then
        preflight_pass "At least 5 GiB is available on /"
    else
        preflight_warning "Less than 5 GiB is available on /"
    fi
    if [ -f /var/run/reboot-required ] || command -v needs-restarting >/dev/null 2>&1 && needs-restarting -r >/dev/null 2>&1; then
        preflight_warning "The host may require a reboot; no reboot will be initiated"
    else
        preflight_pass "No reboot-required marker is visible"
    fi

    if [ -d "$STATE_DIR" ]; then
        preflight_pass "State/backup parent directory exists: $STATE_DIR"
    else
        preflight_warning "State/backup parent directory does not exist yet: $STATE_DIR"
    fi
    if [ -d "$STATE_DIR/backups" ]; then
        preflight_pass "Expected backup location exists: $STATE_DIR/backups"
    else
        preflight_warning "Expected backup location does not exist yet: $STATE_DIR/backups"
    fi

    if [ "$PREFLIGHT_BLOCKERS" -eq 0 ]; then
        echo "PASS Preflight completed with no blockers"
        return 0
    fi
    echo "BLOCKED Preflight found $PREFLIGHT_BLOCKERS blocker(s); no persistent changes were made"
    return 1
}

platform_dry_run() {
    platform_preflight || true
    echo ""
    echo "Ordered dry-run plan (no persistent changes made)"
    echo "  WOULD CHANGE packages: logical capabilities mapped above, using $PLATFORM_PACKAGE_MANAGER --needed"
    echo "  WOULD CHANGE hostname and /etc/hosts after explicit operator confirmation"
    if [ "$PLATFORM_FAMILY" = arch ] && platform_ad_dns_configuration_usable; then
        echo "  WOULD PRESERVE already-valid AD DNS configuration"
    else
        if [ "$PLATFORM_FAMILY" = arch ]; then
            echo "  WOULD CHANGE NetworkManager DNS/search settings using current or office-specific fallback policy"
        else
            echo "  WOULD CHANGE NetworkManager search domains; DNS servers remain DHCP/VPN unless explicit override is configured"
        fi
    fi
    echo "  WOULD CHANGE /etc/krb5.conf, /etc/sssd/sssd.conf, native PAM files, /etc/sudoers.d/*, /etc/samba/smb.conf, /etc/nsswitch.conf"
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        echo "  WOULD CHANGE configured /smb roots: ${DR_DRIP_SEARCH_ROOTS:-none}"
        echo "  DRIP support: configured-root /smb only; arbitrary /smb and /net paths remain unsupported"
        echo "  WOULD START configured DRIP automounts only for the KIT launch; no global enablement"
        echo "  WOULD CHANGE /etc/systemd/system/mnt-x.mount and /etc/systemd/system/mnt-x.automount"
        echo "  WOULD CHANGE configured DRIP .mount/.automount units and $DR_DRIP_MANIFEST"
        echo "  WOULD USE CIFS ownership: sec=krb5,cruid=<logged-in-domain-user-uid>,vers=3.0"
        echo "  WOULD INSTALL /usr/local/sbin/dr-tools-rebind for explicit selected-user remounts; shared multi-user /mnt/x is not claimed"
        echo "  WOULD CHANGE /etc/systemd/system/dr-domain-machine-password-renew.{service,timer} and /usr/local/sbin/dr-domain-machine-password-renew"
        echo "  WOULD CHANGE /usr/local/bin/*, /usr/local/sbin/*, desktop integration files"
        if [ "$(platform_time_provider selected)" = systemd-timesyncd ]; then
            if platform_timesyncd_dropin_matches && platform_timesyncd_is_ready; then
                echo "  WOULD PRESERVE already-valid corporate systemd-timesyncd configuration"
            else
                echo "  WOULD INSTALL/VERIFY Arch corporate timesyncd override: $DR_TIMESYNCD_DROPIN"
            fi
        elif platform_time_provider_satisfies; then
            echo "  WOULD VALIDATE existing time provider: $(platform_time_provider selected); no provider switch"
        else
            echo "  WOULD ENABLE/RESTART time provider: $(platform_service_name time-sync)"
        fi
        echo "  WOULD ENABLE/RESTART services: sssd, $(platform_service_name ssh-server), mnt-x.automount, dr-domain-machine-password-renew.timer"
        echo "  WOULD JOIN with Samba: kinit (interactive), site-aware DC pinning, net ads join -S PINNED_DC --use-kerberos=required, net ads testjoin, net ads keytab create"
    else
        echo "  WOULD CHANGE /etc/auto.master.d/*, /etc/auto.net.cifs, /usr/local/bin/*, /usr/local/sbin/*, desktop integration files"
        echo "  WOULD ENABLE/RESTART services: $(platform_service_name time-sync), sssd, winbind, autofs, $(platform_service_name ssh-server)"
        echo "  WOULD JOIN realm: $DOMAIN only at the human credential checkpoint"
    fi
    echo "  WOULD NOT reboot, log out, restart a display manager, disable security controls, or run pacman -Syu"
    if [ "$PREFLIGHT_BLOCKERS" -gt 0 ] || [ "$PLATFORM_REPORT_BLOCKERS" -gt 0 ]; then
        echo "BLOCKED Dry-run plan is not executable until preflight blockers are resolved"
        return 1
    fi
    echo "PASS Dry-run plan is internally complete; no persistent changes were made"
    return 0
}

# ── OS detection ──────────────────────────────────────────────────────────────

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
DR_TOOLS_MOUNT_CRUID="${DR_TOOLS_MOUNT_CRUID:-}"
JOIN_LIFECYCLE="${JOIN_LIFECYCLE:-NEW_JOIN}"
DR_DRIP_SEARCH_ROOTS="${DR_DRIP_SEARCH_ROOTS:-}"
HOSTNAME_CHANGED="${HOSTNAME_CHANGED:-0}"
EOF
    chmod 600 "$STATE_FILE"
}

load_state() {
    [ -f "$STATE_FILE" ] || return 1
    [ -r "$STATE_FILE" ] || return 1
    # shellcheck disable=SC1090
    . "$STATE_FILE"

    [ -n "${OFFICE_CODE:-}" ] && OFFICE_CODE="$OFFICE_CODE"
    [ -n "${DOMAIN_SUDO_USER:-}" ] && DOMAIN_SUDO_USER="$DOMAIN_SUDO_USER"
    [ -n "${DR_TOOLS_MOUNT_CRUID:-}" ] && DR_TOOLS_MOUNT_CRUID="$DR_TOOLS_MOUNT_CRUID"
    [ -n "${JOIN_LIFECYCLE:-}" ] && JOIN_LIFECYCLE="$JOIN_LIFECYCLE"
    [ -n "${DR_DRIP_SEARCH_ROOTS:-}" ] && DR_DRIP_SEARCH_ROOTS="$DR_DRIP_SEARCH_ROOTS"
    [ -n "${TARGET_HOSTNAME:-}" ] && DOMAIN_TARGET_HOSTNAME="$TARGET_HOSTNAME"
    return 0
}

state_identity_contradiction() {
    local current_host persisted_host
    case "${STAGE:-}" in
        DOMAIN_JOIN_COMPLETE|POSTJOIN_COMPLETE) ;;
        *) return 1 ;;
    esac
    persisted_host="${DOMAIN_TARGET_HOSTNAME:-${TARGET_HOSTNAME:-}}"
    current_host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
    [ -n "$persisted_host" ] && [ -n "$current_host" ] || return 1
    [ "${persisted_host,,}" != "${current_host,,}" ] || return 1
    # A completed state without the active local machine secret and keytab is
    # not trusted when the local hostname contradicts the persisted identity.
    [ ! -s "$DR_SAMBA_SECRETS_TDB" ] || return 1
    [ ! -s "$DR_LOCAL_KEYTAB" ]
}

state_requires_recovery() {
    [ "$PLATFORM_FAMILY" = arch ] || return 1
    state_identity_contradiction
}

recover_stale_state() {
    local current_host persisted_host
    state_requires_recovery || return 1
    current_host="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true)"
    persisted_host="${DOMAIN_TARGET_HOSTNAME:-${TARGET_HOSTNAME:-unknown}}"
    print_error "Persisted provisioning state is stale or contaminated."
    print_error "Persisted target hostname: $persisted_host"
    print_error "Current hostname:          $current_host"
    print_error "Active Samba machine secret: absent"
    print_error "Active local keytab:          absent"
    print_warning "The old AD computer object will not be deleted, reset, disabled, moved, or reused."
    print_info "The current candidate $current_host must be checked by the privileged AD helper before joining."

    DOMAIN_TARGET_HOSTNAME="$current_host"
    TARGET_HOSTNAME="$current_host"
    DOMAIN_SUDO_USER=""
    DR_TOOLS_MOUNT_CRUID=""
    JOIN_LIFECYCLE="RECOVERY_REQUIRED"
    save_state "WAITING_FOR_ADMIN"
    print_info "Recovery state saved as WAITING_FOR_ADMIN for a fresh authoritative admin join."
    print_info "Run: sudo /usr/local/sbin/dr-domain-admin-join"
}

clear_state() {
    rm -f "$STATE_FILE"
}

LIVE_VALIDATION_STATES=(
    DOMAIN_JOIN_COMPLETE
    IDENTITY_VALIDATED
    TOOLS_MOUNT_VALIDATED
    KIT_CREDENTIAL_LIFECYCLE_VALIDATED
    DRIP_SEARCH_VALIDATED
    DRIP_ACTIVATION_VALIDATED
    DRIP_BOUNDED_READ_VALIDATED
    DRIP_CLEANUP_VALIDATED
)

live_validation_marker_dir() {
    printf '%s\n' "$STATE_DIR/live-validation"
}

platform_live_validation_complete() {
    local required_state
    for required_state in DOMAIN_JOIN_COMPLETE IDENTITY_VALIDATED TOOLS_MOUNT_VALIDATED KIT_CREDENTIAL_LIFECYCLE_VALIDATED; do
        [ -f "$(live_validation_marker_dir)/$required_state" ] || return 1
    done
    if [ "$DRIP_REQUIRED" = true ]; then
        for required_state in DRIP_SEARCH_VALIDATED DRIP_ACTIVATION_VALIDATED DRIP_BOUNDED_READ_VALIDATED DRIP_CLEANUP_VALIDATED; do
            [ -f "$(live_validation_marker_dir)/$required_state" ] || return 1
        done
    fi
}

render_live_validation_helper() {
    cat << EOF
#!/bin/bash
set -euo pipefail

STATE_DIR="$STATE_DIR"
STATE_FILE="$STATE_FILE"
DRIP_REQUIRED="$DRIP_REQUIRED"
MARKER_DIR="\$STATE_DIR/live-validation"
VALID_STATES="DOMAIN_JOIN_COMPLETE IDENTITY_VALIDATED TOOLS_MOUNT_VALIDATED KIT_CREDENTIAL_LIFECYCLE_VALIDATED DRIP_SEARCH_VALIDATED DRIP_ACTIVATION_VALIDATED DRIP_BOUNDED_READ_VALIDATED DRIP_CLEANUP_VALIDATED"

require_root() {
    [ "\$(id -u)" -eq 0 ] || { echo "Run this validation helper as root." >&2; exit 1; }
}

valid_state() {
    case " \$VALID_STATES " in *" \$1 "*) return 0 ;; *) return 1 ;; esac
}

complete() {
    local state
    for state in DOMAIN_JOIN_COMPLETE IDENTITY_VALIDATED TOOLS_MOUNT_VALIDATED KIT_CREDENTIAL_LIFECYCLE_VALIDATED; do
        [ -f "\$MARKER_DIR/\$state" ] || return 1
    done
    if [ "\$DRIP_REQUIRED" = true ]; then
        for state in DRIP_SEARCH_VALIDATED DRIP_ACTIVATION_VALIDATED DRIP_BOUNDED_READ_VALIDATED DRIP_CLEANUP_VALIDATED; do
            [ -f "\$MARKER_DIR/\$state" ] || return 1
        done
    fi
}

promote_state_if_complete() {
    local tmp
    complete || return 0
    [ -f "\$STATE_FILE" ] || return 0
    tmp="\$STATE_FILE.tmp.\$\$"
    awk '
        /^STAGE=/ { print "STAGE=\\"POSTJOIN_COMPLETE\\""; next }
        { print }
    ' "\$STATE_FILE" > "\$tmp"
    chmod 600 "\$tmp"
    chown root:root "\$tmp" 2>/dev/null || true
    mv -f -- "\$tmp" "\$STATE_FILE"
    echo "POSTJOIN_COMPLETE recorded after all required live validation states were recorded."
}

require_root
case "\${1:---status}" in
    --status)
        for state in \$VALID_STATES; do
            if [ -f "\$MARKER_DIR/\$state" ]; then echo "PASS \$state"; else echo "PENDING \$state"; fi
        done
        if complete; then echo "PASS completion-gate"; else echo "PENDING completion-gate"; fi
        ;;
    --record)
        valid_state "\${2:-}" || { echo "Unknown validation state." >&2; exit 2; }
        mkdir -p "\$MARKER_DIR"
        printf 'recorded_at=%s\\noperator=%s\\n' "\$(date -Is)" "\${SUDO_USER:-root}" > "\$MARKER_DIR/\$2"
        chmod 600 "\$MARKER_DIR/\$2"
        chown root:root "\$MARKER_DIR/\$2" 2>/dev/null || true
        echo "Recorded \$2. This command records operator evidence; it does not perform the live test."
        promote_state_if_complete
        ;;
    *) echo "Usage: dr-domain-join-live-validate {--status|--record STATE}" >&2; exit 2 ;;
esac
EOF
}

install_live_validation_helper() {
    local helper="/usr/local/sbin/dr-domain-join-live-validate"
    backup_config_file "$helper"
    render_live_validation_helper > "$helper"
    chmod 755 "$helper"
    chown root:root "$helper"
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
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        # Arch uses pambase's system-auth/system-login includes rather than
        # Debian's common-* files. The native adapter adds pam_sss with
        # user_unknown=ignore and keeps pam_unix in the stack so local users
        # remain usable when the domain is offline.
        print_info "Arch PAM resilience is provided by the native system-auth adapter"
        return 0
    fi

    local acct="/etc/pam.d/common-account"

    [ -f "$acct" ] || return 0
    backup_config_file "$acct"

    if grep -q 'pam_sss.so' "$acct"; then
        sed -i -E 's/^account[[:space:]]+\[[^]]*\][[:space:]]+pam_sss\.so.*/account [success=ok new_authtok_reqd=done ignore=ignore user_unknown=ignore default=ignore] pam_sss.so/' "$acct"
        sed -i -E 's/^account[[:space:]]+required[[:space:]]+pam_sss\.so.*/account [success=ok new_authtok_reqd=done ignore=ignore user_unknown=ignore default=ignore] pam_sss.so/' "$acct"
        print_info "Hardened PAM account handling so local graphical login survives SSSD outages"
    fi
}

disable_sssd_if_not_joined() {
    if ! platform_domain_is_joined; then
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
    if platform_domain_is_joined; then
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
    if ! platform_domain_is_joined; then
        return 1
    fi

    print_info "Existing domain membership detected; validating machine account..."

    if platform_domain_testjoin; then
        print_info "Machine account validation succeeded"
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

platform_domain_discover() {
    case "$PLATFORM_FAMILY" in
        debian)
            command -v realm >/dev/null 2>&1 && realm discover --verbose "$DOMAIN" >/dev/null 2>&1
            ;;
        arch)
            local kerberos_records ldap_records
            kerberos_records="$(platform_dns_srv_records "_kerberos._tcp.$DOMAIN")"
            ldap_records="$(platform_dns_srv_records "_ldap._tcp.$DOMAIN")"
            [ -n "$kerberos_records" ] && [ -n "$ldap_records" ] || return 1
            printf '%s\n' "$kerberos_records" "$ldap_records"
            ;;
        *)
            return 1
            ;;
    esac
}

platform_dns_srv_records() {
    local record="$1"
    local nameserver="${2:-}"
    if command -v dig >/dev/null 2>&1; then
        if [ -n "$nameserver" ]; then
            timeout 5s dig +time=2 +tries=1 +short SRV "$record" "@$nameserver" 2>/dev/null \
                | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /\.$/'
        else
            timeout 5s dig +time=2 +tries=1 +short SRV "$record" 2>/dev/null \
                | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /\.$/'
        fi
    elif command -v host >/dev/null 2>&1; then
        if [ -n "$nameserver" ]; then
            timeout 5s host -t SRV "$record" "$nameserver" 2>/dev/null \
                | awk '/has SRV record/ {print}'
        else
            timeout 5s host -t SRV "$record" 2>/dev/null \
                | awk '/has SRV record/ {print}'
        fi
    fi
}

platform_office_server_list() {
    local kind="$1"
    local office="${OFFICE_CODE^^}"
    local variable

    case "$office" in
        ''|*[!A-Z0-9]*) office="" ;;
    esac

    if [ -n "$office" ]; then
        variable="DR_${kind}_SERVERS_${office}"
        if [ -n "${!variable+x}" ]; then
            printf '%s\n' "${!variable}"
            return 0
        fi
    fi

    case "$kind" in
        DNS)
            printf '%s\n' "$DR_DNS_SERVERS"
            ;;
        TIME)
            printf '%s\n' "$DR_TIME_SERVERS"
            ;;
        *)
            return 1
            ;;
    esac
}

platform_validate_server_list() {
    local servers="$1" server
    [ -n "$servers" ] || return 1
    case "$servers" in
        *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
    esac
    for server in $servers; do
        case "$server" in
            ''|*[!A-Za-z0-9._:-]*) return 1 ;;
        esac
    done
}

platform_ad_dns_discovery_current() {
    local kerberos_records ldap_records
    kerberos_records="$(platform_dns_srv_records "_kerberos._tcp.$DOMAIN")"
    ldap_records="$(platform_dns_srv_records "_ldap._tcp.$DOMAIN")"
    [ -n "$kerberos_records" ] && [ -n "$ldap_records" ]
}

platform_ad_dns_discovery_via_servers() {
    local servers="$1" server kerberos_records ldap_records
    platform_validate_server_list "$servers" || return 1
    for server in $servers; do
        kerberos_records="$(platform_dns_srv_records "_kerberos._tcp.$DOMAIN" "$server")"
        ldap_records="$(platform_dns_srv_records "_ldap._tcp.$DOMAIN" "$server")"
        if [ -n "$kerberos_records" ] && [ -n "$ldap_records" ]; then
            printf '%s\n' "$server"
            return 0
        fi
    done
    return 1
}

platform_dns_search_has_ad_domain() {
    local connection current
    connection="$(get_active_connection)"
    [ -n "$connection" ] || return 1
    current="$(nmcli -g ipv4.dns-search connection show "$connection" 2>/dev/null || true)"
    printf '%s\n' "$current" | tr ',' '\n' | awk '{$1=$1; print}' | grep -Fxq "$DOMAIN"
}

platform_ad_dns_configuration_usable() {
    platform_ad_dns_discovery_current && platform_dns_search_has_ad_domain
}

platform_dns_discovery_source() {
    if platform_ad_dns_discovery_current; then
        printf 'current\n'
        return 0
    fi
    local fallback
    fallback="$(platform_office_server_list DNS)"
    if platform_ad_dns_discovery_via_servers "$fallback" >/dev/null; then
        printf 'office-fallback\n'
        return 0
    fi
    return 1
}

platform_domain_testjoin() {
    case "$PLATFORM_FAMILY" in
        debian)
            adcli testjoin -D "$DOMAIN" >/dev/null 2>&1
            ;;
        arch)
            command -v net >/dev/null 2>&1 || return 1
            net ads testjoin >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

platform_domain_is_joined() {
    case "$PLATFORM_FAMILY" in
        debian)
            realm list 2>/dev/null | grep -q "configured: kerberos-member"
            ;;
        arch)
            [ -s /etc/krb5.keytab ] && platform_domain_testjoin
            ;;
        *)
            return 1
            ;;
    esac
}

platform_domain_leave() {
    case "$PLATFORM_FAMILY" in
        debian)
            realm leave "$DOMAIN"
            ;;
        arch)
            print_warning "Arch leave requires an existing Kerberos administrator ticket."
            net ads leave --use-kerberos=required
            ;;
        *)
            print_error "No domain-leave adapter exists for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
}

render_arch_smb_conf() {
    cat << EOF
[global]
    workgroup = $WORKGROUP
    realm = $REALM
    security = ADS
    client ipc signing = required
    client min protocol = SMB2
    idmap config * : backend = tdb
    idmap config * : range = 100000-199999

    # Samba 4.21+ removed net ads keytab add/delete.  The machine password is
    # synchronized by the documented declarative keytab rule, then materialized
    # with: net ads keytab create.
    kerberos method = secrets only
    sync machine password to keytab = /etc/krb5.keytab:spn_prefixes=host:account_name:sync_spns:sync_kvno:machine_password
EOF
}

platform_generate_machine_keytab() {
    case "$PLATFORM_FAMILY" in
        debian)
            print_info "Debian backend delegates keytab creation to realmd/adcli"
            ;;
        arch)
            command -v net >/dev/null 2>&1 || {
                print_error "Samba net utility is unavailable; cannot generate machine keytab"
                return 1
            }
            print_info "Generating /etc/krb5.keytab with Samba 4.21+ keytab synchronization"
            backup_config_file /etc/krb5.keytab
            net ads keytab create
            platform_validate_machine_keytab
            ;;
        *)
            print_error "No machine-keytab adapter exists for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
}

platform_validate_machine_keytab() {
    [ -s /etc/krb5.keytab ] || {
        print_error "/etc/krb5.keytab is missing or empty"
        return 1
    }
    command -v klist >/dev/null 2>&1 || {
        print_error "klist is unavailable; cannot validate /etc/krb5.keytab"
        return 1
    }
    if ! klist -k /etc/krb5.keytab 2>/dev/null | grep -qi "$REALM"; then
        print_error "/etc/krb5.keytab has no $REALM principal"
        return 1
    fi
    print_info "Validated /etc/krb5.keytab for $REALM"
}

platform_domain_join_plan() {
    case "$PLATFORM_FAMILY" in
        debian)
            cat << 'EOF'
realm join -v DOMAIN -U ADMIN_USER
adcli testjoin -D DOMAIN
EOF
            ;;
        arch)
            cat << 'EOF'
kdestroy
kinit ADMIN_USER@REALM                 # human enters password at Kerberos prompt
dr-domain-admin-join                     # authoritative AD allocation and collision gate
net ads join -S PINNED_DC --use-kerberos=required  # same DC as both LDAP checks
net ads testjoin                         # validates local machine membership
net ads keytab create                    # materializes /etc/krb5.keytab from smb.conf
klist -k /etc/krb5.keytab
EOF
            ;;
        *)
            return 1
            ;;
    esac
}

platform_domain_join() {
    local admin_user="${1:-}"

    case "$PLATFORM_FAMILY" in
        debian)
            realm join -v "$DOMAIN" -U "$admin_user"
            ;;
        arch)
            print_error "Arch joins must use /usr/local/sbin/dr-domain-admin-join"
            print_error "That helper performs the independent authoritative AD collision gate immediately before net ads join"
            return 1
            ;;
        *)
            print_error "No domain-join adapter exists for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
}

render_arch_domain_admin_join_helper() {
    cat << EOF
#!/bin/bash
set -euo pipefail

DOMAIN="$DOMAIN"
REALM="$REALM"
OFFICE_CODE="${OFFICE_CODE:-EP1}"
SCRIPT_VERSION="$SCRIPT_VERSION"
STATE_DIR="\${DR_ADMIN_STATE_DIR:-$STATE_DIR}"
STATE_FILE="\${DR_ADMIN_STATE_FILE:-\$STATE_DIR/state}"
SMB_CONF="\${DR_ADMIN_SMB_CONF:-/etc/samba/smb.conf}"
KEYTAB="\${DR_ADMIN_KEYTAB:-/etc/krb5.keytab}"
SECRETS_TDB="\${DR_ADMIN_SECRETS_TDB:-/var/lib/samba/private/secrets.tdb}"
HOSTS_FILE="\${DR_ADMIN_HOSTS_FILE:-/etc/hosts}"
JOIN_LIFECYCLE="NEW_JOIN"

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
JOIN_LIFECYCLE="\$JOIN_LIFECYCLE"
HOSTNAME_CHANGED="0"
STATEEOF
    chmod 600 "\$STATE_FILE"
}

cleanup_local_join_state() {
    print_warn "Explicit rollback requested for the local Arch join state."
    if klist -s 2>/dev/null; then
        net ads leave --use-kerberos=required || print_warn "Samba could not remove the AD computer account; verify it with the domain administrator."
    else
        print_warn "No Kerberos ticket is available; the AD computer object was not changed by rollback."
    fi
    rm -f "\$KEYTAB"
    rm -rf /var/lib/sss/db/* /var/lib/sss/mc/* 2>/dev/null || true
    systemctl disable --now sssd >/dev/null 2>&1 || true
    save_join_state "WAITING_FOR_ADMIN" "\$(hostnamectl --static 2>/dev/null || hostname)"
    print_info "Local keytab, SSSD cache, and SSSD enablement were removed."
}

if [ "\$(id -u)" -ne 0 ]; then
    print_error "Run this helper with sudo: sudo /usr/local/sbin/dr-domain-admin-join"
    exit 1
fi

for required in net kinit klist hostnamectl testparm ldapsearch; do
    if ! command -v "\$required" >/dev/null 2>&1; then
        print_error "Required Arch join command not found: \$required"
        print_error "Have the technician rerun the candidate after the approved dependency checkpoint."
        exit 1
    fi
done

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
    local hostname_value="\$1"
    [ "\${#hostname_value}" -le 15 ] || return 1
    echo "\$hostname_value" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\$'
}

suggest_hostname() {
    local prefix="\$1" number="\$2"
    number="\$(echo "\$number" | tr -cd '0-9')"
    [ -n "\$number" ] || number="01"
    [ "\${#number}" -eq 1 ] && number="0\$number"
    echo "\${prefix}-\${number}"
}

hostname_matches_managed_policy() {
    local hostname_value="\$1" prefix suffix
    prefix="\$(office_hostname_prefix)"
    case "\$hostname_value" in
        "\${prefix}-"[0-9][0-9]) suffix="\${hostname_value#\${prefix}-}" ;;
        *) return 1 ;;
    esac
    [ "\${#suffix}" -eq 2 ] && is_valid_ad_hostname "\$hostname_value"
}

machine_identity_trusted() {
    local current_host
    [ -s "\$KEYTAB" ] && [ -s "\$SECRETS_TDB" ] || return 1
    net ads testjoin >/dev/null 2>&1 || return 1
    current_host="\$(hostnamectl --static 2>/dev/null || hostname)"
    LC_ALL=C klist -k "\$KEYTAB" 2>/dev/null \
        | grep -Eiq "(host|cifs)/\${current_host}([.@]|$)" || return 1
}

domain_to_base_dn() {
    echo "\$DOMAIN" | awk -F. '{
        for (i = 1; i <= NF; i++) {
            if (i > 1) printf ",";
            printf "DC=%s", \$i;
        }
        printf "\\n";
    }'
}

select_pinned_dc() {
    local info_output lookup_output selected_dc lookup_dc
    [ -z "\${PINNED_DC:-}" ] || {
        print_error "The admin-join transaction already has a pinned DC: \$PINNED_DC"
        return 1
    }

    # Samba's resolver applies AD site awareness and chooses the closest
    # usable server. Do not replace this with a global LDAP SRV lookup:
    # global records can contain unreachable worldwide DCs.
    info_output="\$(net ads info 2>&1)" || {
        print_error "Samba could not select a site-aware domain controller."
        echo "\$info_output" | sed 's/^/  /' >&2
        return 1
    }
    selected_dc="\$(echo "\$info_output" | awk -F: 'tolower(\$1) ~ /^[[:space:]]*ldap server name[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", \$2); print \$2; exit}')"
    case "\$selected_dc" in
        *[!A-Za-z0-9.-]*|*[!A-Za-z0-9])
            print_error "Samba returned an invalid LDAP server name: \${selected_dc:-<empty>}"
            return 1
            ;;
    esac
    [ -n "\$selected_dc" ] || {
        print_error "Samba did not return an LDAP server FQDN."
        return 1
    }
    [[ "\$selected_dc" == *.* ]] || {
        print_error "Samba returned a non-FQDN LDAP server name: \$selected_dc"
        return 1
    }

    # Confirm the selected server itself is the closest, writable, LDAP-capable
    # DC. This is a single-server validation transaction; no remote/global DCs
    # are enumerated or required to respond.
    lookup_output="\$(net ads lookup -S "\$selected_dc" 2>&1)" || {
        print_error "Samba could not validate selected DC \$selected_dc."
        echo "\$lookup_output" | sed 's/^/  /' >&2
        return 1
    }
    lookup_dc="\$(echo "\$lookup_output" | awk -F: 'tolower(\$1) ~ /^[[:space:]]*domain controller[[:space:]]*$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", \$2); print \$2; exit}')"
    [ -n "\$lookup_dc" ] && [[ "\${lookup_dc,,}" = "\${selected_dc,,}" ]] || {
        print_error "Samba lookup did not confirm the selected DC identity: \$selected_dc"
        return 1
    }
    echo "\$lookup_output" | grep -Eiq '^[[:space:]]*Is the closest DC:[[:space:]]*yes[[:space:]]*$' || {
        print_error "Selected DC \$selected_dc is not confirmed as the closest DC."
        return 1
    }
    echo "\$lookup_output" | grep -Eiq '^[[:space:]]*Is writable:[[:space:]]*yes[[:space:]]*$' || {
        print_error "Selected DC \$selected_dc is not confirmed writable."
        return 1
    }
    echo "\$lookup_output" | grep -Eiq '^[[:space:]]*Is an LDAP server:[[:space:]]*yes[[:space:]]*$' || {
        print_error "Selected DC \$selected_dc is not confirmed as an LDAP server."
        return 1
    }

    # Preserve Samba's exact FQDN spelling so the LDAP endpoint and the final
    # net ads join -S argument are visibly identical in diagnostics.
    PINNED_DC="\$selected_dc"
    print_info "Pinned site-aware writable LDAP DC for this transaction: \$PINNED_DC"
}

ldap_search_computer_object() {
    local ldap_dc="\$1" base_dn="\$2" sam="\$3"
    timeout 15s \
        ldapsearch -LLL -Q -Y GSSAPI -N \
        -o nettimeout=10 -o timelimit=10 -o referrals=false \
        -H "ldap://\$ldap_dc" -b "\$base_dn" -s sub \
        "(&(objectClass=computer)(sAMAccountName=\$sam))" \
        dn sAMAccountName dNSHostName description whenCreated </dev/null
}

ad_computer_exists() {
    local candidate="\$1" sam base_dn output rc
    [ -n "\${PINNED_DC:-}" ] || return 2
    sam="\$(echo "\$candidate" | tr '[:lower:]' '[:upper:]')\$"
    base_dn="\$(domain_to_base_dn)"
    if output="\$(ldap_search_computer_object "\$PINNED_DC" "\$base_dn" "\$sam" 2>&1)"; then
        rc=0
    else
        rc=\$?
    fi
    if [ "\$rc" -ne 0 ]; then
        if [ "\$rc" -eq 124 ]; then
            print_error "AD query on pinned DC \$PINNED_DC timed out after 15 seconds while checking \$candidate."
        else
            print_error "AD query on pinned DC \$PINNED_DC failed with exit status \$rc while checking \$candidate."
        fi
        print_error "No domain join was attempted."
        echo "\$output" | sed 's/^/  /' >&2
        return 2
    fi
    if echo "\$output" | grep -qi '^dn:'; then
        print_error "Computer account \$candidate already exists in Active Directory."
        print_error "Existing object on pinned DC \$PINNED_DC:"
        echo "\$output" | sed 's/^/  /' >&2
        return 0
    fi
    return 1
}

find_next_available_ad_hostname() {
    local prefix="\$(office_hostname_prefix)" candidate rc n
    for n in \$(seq 1 99); do
        candidate="\$(suggest_hostname "\$prefix" "\$n")"
        is_valid_ad_hostname "\$candidate" || continue
        echo "  checking authoritative AD computer object: \$candidate" >&2
        if ad_computer_exists "\$candidate"; then
            continue
        else
            rc=\$?
        fi
        [ "\$rc" -eq 1 ] || {
            print_error "AD availability query for \$candidate was not authoritative; refusing hostname allocation."
            return 1
        }
        echo "\$candidate"
        return 0
    done
    return 1
}

update_hosts_for_hostname_admin() {
    local new_hostname="\$1" hosts_file="\$HOSTS_FILE" tmp_file
    tmp_file="\$(mktemp)"
    cp "\$hosts_file" "\${hosts_file}.dr-domain-admin-join.bak.\$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    awk -v hn="\$new_hostname" -v fqdn="\${new_hostname}.\$DOMAIN" '
        BEGIN { replaced=0 }
        /^127[.]0[.]1[.]1[[:space:]]+/ {
            if (!replaced) { print "127.0.1.1    " fqdn "    " hn; replaced=1 }
            next
        }
        { print }
        END { if (!replaced) print "127.0.1.1    " fqdn "    " hn }
    ' "\$hosts_file" > "\$tmp_file"
    cat "\$tmp_file" > "\$hosts_file"
    rm -f "\$tmp_file"
}

testparm -s "\$SMB_CONF" >/dev/null
current_host="\$(hostnamectl --static 2>/dev/null || hostname)"
echo "Current hostname: \$current_host"
echo "Domain:           \$DOMAIN"
echo "Office code:      \$OFFICE_CODE"
echo "Join backend:     Samba ADS (SSSD remains the NSS/PAM provider)"
echo ""

if machine_identity_trusted; then
    print_info "Existing Samba machine membership and local host/keytab identity are valid."
    JOIN_LIFECYCLE="MANAGED_RERUN"
    save_join_state "DOMAIN_JOIN_COMPLETE" "\$current_host"
    exit 0
fi

echo "Enter the domain admin username that may create or update the AD computer account."
read -r -p "Domain admin username: " admin_user
[ -n "\$admin_user" ] || { print_error "Domain admin username is required."; exit 1; }
case "\$admin_user" in
    *@*) kerberos_principal="\$admin_user" ;;
    *) kerberos_principal="\${admin_user}@\${REALM}" ;;
esac

echo ""
print_info "Obtaining a Kerberos ticket for \$kerberos_principal."
print_info "Enter the password directly at the kinit prompt; it is not captured by this helper."
kdestroy >/dev/null 2>&1 || true
kinit "\$kerberos_principal"

PINNED_DC=""
if ! select_pinned_dc; then
    print_error "Cannot query AD authoritatively without a suitable site-aware writable LDAP DC."
    exit 1
fi
print_info "All hostname checks and the final Samba join will use pinned DC \$PINNED_DC."

selected_host=""
if is_valid_ad_hostname "\$current_host" && hostname_matches_managed_policy "\$current_host"; then
    if ad_computer_exists "\$current_host"; then
        print_info "Current hostname \$current_host is occupied; allocating the next free AD name."
    else
        current_rc=\$?
        [ "\$current_rc" -eq 1 ] || {
            print_error "Current hostname availability could not be established authoritatively."
            exit 1
        }
        selected_host="\$current_host"
    fi
fi
if [ -z "\$selected_host" ]; then
    selected_host="\$(find_next_available_ad_hostname)" || {
        print_error "Active Directory did not provide an authoritative unused workstation name."
        exit 1
    }
fi

if [ "\$selected_host" != "\$current_host" ]; then
    print_info "Allocating unused AD hostname \$selected_host (current local hostname: \$current_host)."
    hostnamectl set-hostname "\$selected_host"
    update_hosts_for_hostname_admin "\$selected_host"
    current_host="\$selected_host"
fi

# Independent last-moment collision gate. This query is deliberately repeated
# immediately before net ads join to close stale-state and TOCTOU races.
if ad_computer_exists "\$selected_host"; then
    print_error "Computer account \$selected_host already exists in Active Directory."
    print_error "No domain join was attempted. Rerun provisioning to allocate an unused workstation name."
    exit 1
else
    collision_rc=\$?
fi
[ "\$collision_rc" -eq 1 ] || {
    print_error "Unable to prove that \$selected_host is unused in Active Directory."
    print_error "No domain join was attempted."
    exit 1
}

print_info "Joining the AD domain with Samba's Kerberos ticket."
net ads join -S "\$PINNED_DC" --use-kerberos=required
print_info "Validating the local machine membership."
if ! net ads testjoin; then
    print_error "Samba joined, but net ads testjoin failed."
    read -r -p "Explicitly leave the local/domain join now? [y/N]: " cleanup
    case "\${cleanup:-N}" in
        y|Y|yes|YES) cleanup_local_join_state ;;
        *) print_warn "Leaving local join material in place for administrator diagnosis." ;;
    esac
    exit 1
fi

print_info "Generating the system keytab using Samba's 4.21+ synchronization rule."
net ads keytab create
klist -k "\$KEYTAB" | grep -qi "\$REALM"
chmod 600 "\$KEYTAB"
JOIN_LIFECYCLE="NEW_JOIN"
save_join_state "DOMAIN_JOIN_COMPLETE" "\$current_host"
print_info "Join is OK and \$KEYTAB is valid."
echo ""
echo "Rerun the candidate provisioning script locally to configure SSSD, PAM, sudo, and Tool Server mounting."
EOF
}

install_arch_domain_admin_join_helper() {
    local helper="/usr/local/sbin/dr-domain-admin-join"
    local motd="/etc/update-motd.d/99-dr-domain-join"
    local profiled="/etc/profile.d/dr-domain-join.sh"

    mkdir -p /usr/local/sbin /etc/update-motd.d /etc/profile.d
    backup_config_file "$helper"
    backup_config_file "$motd"
    backup_config_file "$profiled"

    render_arch_domain_admin_join_helper > "$helper"
    chmod 755 "$helper"
    chown root:root "$helper"

    cat > "$motd" << 'EOF'
#!/bin/sh
if command -v net >/dev/null 2>&1 && net ads testjoin >/dev/null 2>&1; then
    exit 0
fi
if [ -x /usr/local/sbin/dr-domain-admin-join ]; then
    echo "DR Domain Join Pending: sudo /usr/local/sbin/dr-domain-admin-join"
fi
EOF
    chmod 755 "$motd"
    chown root:root "$motd"

    cat > "$profiled" << 'EOF'
#!/bin/sh
case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
if [ -x /usr/local/sbin/dr-domain-admin-join ] && ! net ads testjoin >/dev/null 2>&1; then
    echo "DR Domain Join Pending: sudo /usr/local/sbin/dr-domain-admin-join"
fi
EOF
    chmod 644 "$profiled"
    chown root:root "$profiled"

    cat > /etc/motd << 'EOF'
DR Domain Join Pending
Run: sudo /usr/local/sbin/dr-domain-admin-join
EOF

    print_info "Installed Arch Samba domain-admin join helper: $helper"
}



install_domain_admin_join_helper() {
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        install_arch_domain_admin_join_helper
        return
    fi
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
    if platform_domain_is_joined; then
        echo "  Realm:    Joined"
        if platform_domain_testjoin; then
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
    # IMPORTANT: Do not run a package manager here. A bad clock can invalidate
    # both apt metadata and pacman signatures before time has been repaired.
    print_info "Checking time/DNS prerequisite tools without using a package manager..."

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

    local selected_provider
    selected_provider="$(platform_time_provider selected)"

    if [ "$PLATFORM_FAMILY" = arch ] && {
        [ "$selected_provider" = systemd-timesyncd ] || {
            [ "$selected_provider" = none ] && ! command -v chronyc >/dev/null 2>&1 && \
                systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd.service'
        }
    }; then
        print_info "Preparing Arch systemd-timesyncd configuration..."
        platform_configure_timesyncd force || return 1
        print_info "Trying systemd-timesyncd..."
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
        timedatectl set-ntp true >/dev/null 2>&1 || true

        local arch_count=0
        while [ "$arch_count" -lt 6 ]; do
            if platform_timesyncd_is_ready; then
                print_info "Clock synchronized via systemd-timesyncd"
                hwclock --systohc >/dev/null 2>&1 || true
                return 0
            fi
            sleep 5
            arch_count=$((arch_count + 1))
        done
        print_error "Arch systemd-timesyncd did not synchronize to a configured corporate source"
        return 1
    fi

    if [ "$PLATFORM_FAMILY" != arch ] && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
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

bootstrap_time_before_packages() {
    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        bootstrap_time_before_apt
        return $?
    fi

    print_info "Bootstrapping system clock before package installation..."
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        timedatectl set-ntp true >/dev/null 2>&1 || true
    elif command -v chronyc >/dev/null 2>&1; then
        platform_enable_service time-sync >/dev/null 2>&1 || true
        chronyc -a makestep >/dev/null 2>&1 || true
    fi

    if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q '^yes$' || \
       chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
        print_info "Clock synchronization is confirmed"
        return 0
    fi

    print_warning "Clock synchronization could not be confirmed before package installation"
    return 1
}

install_domain_packages() {
    print_info "Installing domain packages..."

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        # No pacman -Syu is performed here. The configured sync databases are
        # inspected and only the mapped capabilities are installed with
        # --needed. Arch joins use Samba ADS and systemd automount, so realmd,
        # adcli, and userspace autofs are deliberately not requested.
        platform_install_packages \
            sssd kerberos samba smbclient cifs time-sync dns pam sudo ssh-server || return 1
        return 0
    fi

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
    systemctl enable --now "$(platform_service_name ssh-server)" > /dev/null 2>&1 || true

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
    if [ "$PLATFORM_FAMILY" != "debian" ]; then
        print_info "Skipping Debian unattended-upgrade/no-reboot policy on $PLATFORM_FAMILY"
        return 0
    fi

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
    local connection servers dns_source
    connection="$(get_active_connection)"

    if [ -z "$connection" ]; then
        print_warning "No active NetworkManager connection found — skipping DNS server configuration"
        return 0
    fi

    if [ -z "$DNS_SERVERS" ]; then
        if [ "$PLATFORM_FAMILY" != arch ]; then
            print_info "Keeping DHCP/VPN DNS servers on '$connection'"
            nmcli -g IP4.DNS device show "$(nmcli -g GENERAL.DEVICES connection show "$connection" 2>/dev/null | head -1)" 2>/dev/null || true
            return 0
        fi
        if dns_source="$(platform_dns_discovery_source)" && [ "$dns_source" = current ]; then
            print_info "Preserving already-valid AD DNS configuration on '$connection' (source: $dns_source)"
            return 0
        fi

        servers="$(platform_office_server_list DNS)"
        if [ -z "$servers" ] || ! platform_ad_dns_discovery_via_servers "$servers" >/dev/null; then
            print_error "Current DNS fails AD discovery and no reachable office-specific fallback DNS is configured"
            return 1
        fi
        print_info "Applying reachable office-specific fallback DNS servers to '$connection': $servers"
    else
        servers="$DNS_SERVERS"
    fi

    local first_dns
    first_dns=$(echo "$servers" | awk '{print $1}')
    local current
    current=$(nmcli -g ipv4.dns connection show "$connection" 2>/dev/null || true)
    local ignore_auto_dns
    ignore_auto_dns="$(nmcli -g ipv4.ignore-auto-dns connection show "$connection" 2>/dev/null || true)"
    if echo "$current" | grep -Fq "$first_dns" && [ "$ignore_auto_dns" = yes ]; then
        print_info "DNS servers already configured explicitly on '$connection'"
        return 0
    fi

    backup_config_file /etc/NetworkManager/system-connections
    print_info "Applying DNS servers to connection '$connection': $servers"
    nmcli connection modify "$connection" ipv4.ignore-auto-dns yes ipv4.dns "$servers"
    nmcli connection up "$connection" > /dev/null
    print_info "DNS servers applied"

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

    backup_config_file "$chrony_conf"
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

    systemctl restart "$(platform_service_name time-sync)" > /dev/null 2>&1 || true
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
    local selected_provider
    selected_provider="$(platform_time_provider selected)"
    if [ "$PLATFORM_FAMILY" = arch ] && [ "$selected_provider" = systemd-timesyncd ]; then
        print_info "Using systemd-timesyncd for time synchronization on Arch family"
        platform_configure_timesyncd || return 1
        timedatectl set-ntp true >/dev/null 2>&1 || true
        if platform_wait_for_timesyncd; then
            print_info "Clock is synchronized via systemd-timesyncd"
            return 0
        fi
        print_error "systemd-timesyncd did not confirm synchronization with a configured corporate source"
        return 1
    elif [ "$PLATFORM_FAMILY" = arch ] && [ "$selected_provider" = none ] && ! command -v chronyc >/dev/null 2>&1; then
        print_error "No supported Arch time provider is selected"
        return 1
    fi

    print_info "Enabling time synchronization via chrony..."
    platform_enable_service time-sync > /dev/null 2>&1

    # Ask chrony to take immediate measurements and step the clock if needed.
    chronyc -a burst 4/4 > /dev/null 2>&1 || true
    sleep 2
    chronyc -a makestep > /dev/null 2>&1 || true

    # If the offset is extremely large, chrony may receive valid NTP replies but
    # still not select a source. Force a one-time step from a valid NTP offset.
    if ! chronyc tracking 2>/dev/null | grep -qE '^Leap status[[:space:]]*:[[:space:]]*Normal'; then
        force_step_from_chrony_offset || true
        systemctl restart "$(platform_service_name time-sync)" > /dev/null 2>&1 || true
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

render_krb5_config() {
    cat << EOF
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
}

verify_krb5_conf() {
    local krb5_conf="/etc/krb5.conf"
    print_info "Verifying Kerberos configuration ($krb5_conf)..."

    if [ ! -f "$krb5_conf" ]; then
        print_info "$krb5_conf not found — creating with correct settings"
        render_krb5_config > "$krb5_conf"
        return 0
    fi

    backup_config_file "$krb5_conf"

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
    backup_config_file /etc/hosts

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

    if [ "$PLATFORM_FAMILY" = "debian" ] && realm discover --verbose "$DOMAIN"; then
        print_info "Active Directory discovery successful"
        return 0
    elif [ "$PLATFORM_FAMILY" = "arch" ] && platform_domain_discover; then
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
    if platform_domain_is_joined; then
        print_info "Machine is already joined to $DOMAIN — skipping join"
        return 0
    fi

    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        verify_ad_discovery || exit 1
    elif ! platform_domain_discover; then
        exit 1
    fi

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        # Samba must have its 4.21+ keytab policy in place before the admin
        # helper runs. This writes only smb.conf after the normal preflight
        # checkpoint; the helper remains the credential boundary.
        configure_samba
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
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        echo "  The helper will obtain a Kerberos ticket interactively, pin a site-aware writable LDAP DC, join with net ads join -S PINNED_DC --use-kerberos=required, validate with net ads testjoin, and create /etc/krb5.keytab with net ads keytab create."
    else
        echo "  The helper will allocate the final hostname from Active Directory, rename the workstation, join the domain, and validate with adcli testjoin."
    fi
    echo ""
    echo "  Once the helper reports 'Join is OK', re-run this script to complete configuration:"
    echo ""
    echo '    wget -qO- http://ontrack.link/joindomain | sudo bash'
    echo ""
    exit 0
}

# ── Configure PAM for home directory creation ─────────────────────────────────

render_arch_pam_sss_lines() {
    cat << 'EOF'
auth       [success=2 default=ignore]  pam_sss.so          forward_pass
account    [success=1 default=ignore] pam_sss.so
session    optional                   pam_sss.so
session    required                   pam_mkhomedir.so    skel=/etc/skel/ umask=0077
EOF
}

render_arch_pam_system_auth() {
    local pam_file="${1:-}"
    [ -f "$pam_file" ] && [ ! -L "$pam_file" ] || {
        print_error "Arch PAM adapter requires a regular non-symlink system-auth file: ${pam_file:-<empty>}" >&2
        return 1
    }

    # This deliberately recognizes only the pambase layout validated on
    # CachyOS/Arch. Numeric PAM jumps are relative to subsequent modules, so
    # inserting pam_sss requires adjusting the two native success counts.
    awk '
        function problem(message) {
            print "Unsupported Arch system-auth layout: " message > "/dev/stderr"
            errors = 1
        }
        {
            lines[NR] = $0
            trimmed = $0
            sub(/^[[:space:]]*/, "", trimmed)

            if (trimmed ~ /^-auth[[:space:]].*pam_systemd_home[.]so/) {
                systemd_count++
                systemd_index = NR
                if (trimmed ~ /^-auth[[:space:]]+\[success=2[[:space:]]+default=ignore\][[:space:]]+pam_systemd_home[.]so[[:space:]]*$/) systemd_success = 2
                else if (trimmed ~ /^-auth[[:space:]]+\[success=3[[:space:]]+default=ignore\][[:space:]]+pam_systemd_home[.]so[[:space:]]*$/) systemd_success = 3
                else problem("pam_systemd_home auth control is not a supported success=2/3 default=ignore form")
            }

            if (trimmed ~ /^auth[[:space:]].*pam_sss[.]so/) {
                sss_count++
                sss_index = NR
                if (trimmed ~ /^auth[[:space:]]+\[success=1[[:space:]]+default=ignore\][[:space:]]+pam_sss[.]so[[:space:]]+forward_pass[[:space:]]*$/) sss_success = 1
                else if (trimmed ~ /^auth[[:space:]]+\[success=2[[:space:]]+default=ignore\][[:space:]]+pam_sss[.]so[[:space:]]+forward_pass[[:space:]]*$/) sss_success = 2
                else problem("pam_sss auth control is not a supported success=1/2 default=ignore forward_pass form")
            }

            if (trimmed ~ /^auth[[:space:]].*pam_unix[.]so/) {
                unix_count++
                unix_index = NR
                if (trimmed !~ /^auth[[:space:]]+\[success=1[[:space:]]+default=bad\][[:space:]]+pam_unix[.]so([[:space:]]+.*)?$/) problem("pam_unix auth control is not the native success=1 default=bad form")
            }

            if (trimmed ~ /^auth[[:space:]].*pam_faillock[.]so[[:space:]]+authfail([[:space:]]|$)/) {
                authfail_count++
                authfail_index = NR
                if (trimmed !~ /^auth[[:space:]]+\[default=die\][[:space:]]+pam_faillock[.]so[[:space:]]+authfail[[:space:]]*$/) problem("pam_faillock authfail control is not the native default=die form")
            }

            if (trimmed ~ /^account[[:space:]].*pam_sss[.]so/) account_sss_count++
            if (trimmed ~ /^session[[:space:]].*pam_sss[.]so/) session_sss_count++
            if (trimmed ~ /^account[[:space:]].*pam_unix[.]so/) { account_unix_count++; account_unix_index = NR }
            if (trimmed ~ /^session[[:space:]].*pam_unix[.]so/) { session_unix_count++; session_unix_index = NR }
            if (trimmed ~ /^session[[:space:]].*pam_mkhomedir[.]so/) mkhomedir_count++
        }
        END {
            if (systemd_count != 1) problem("expected exactly one auth pam_systemd_home line")
            if (sss_count > 1) problem("expected zero or one auth pam_sss line")
            if (unix_count != 1) problem("expected exactly one auth pam_unix line")
            if (authfail_count != 1) problem("expected exactly one auth pam_faillock authfail line")

            if (!errors) {
                if (sss_count == 0) {
                    if (systemd_success != 2) problem("success=3 pam_systemd_home requires the managed pam_sss insertion")
                    if (systemd_index + 1 != unix_index) problem("native pam_systemd_home and pam_unix lines are not adjacent")
                } else {
                    if (systemd_index + 1 != sss_index || sss_index + 1 != unix_index) problem("managed pam_sss is not directly between pam_systemd_home and pam_unix")
                }
                if (unix_index + 1 != authfail_index) problem("pam_unix is not immediately followed by pam_faillock authfail")
                if (account_sss_count == 0 && account_unix_count != 1) problem("cannot safely place the missing account pam_sss line")
                if (session_sss_count == 0 && session_unix_count != 1) problem("cannot safely place the missing session pam_sss line")
            }
            if (errors) exit 2

            for (i = 1; i <= NR; i++) {
                if (account_sss_count == 0 && i == account_unix_index) print "account    [success=1 default=ignore] pam_sss.so"
                if (i == systemd_index && systemd_success != 3) {
                    print "-auth      [success=3 default=ignore]  pam_systemd_home.so"
                } else if (sss_count == 1 && i == sss_index && sss_success != 2) {
                    print "auth       [success=2 default=ignore]  pam_sss.so          forward_pass"
                } else if (sss_count == 0 && i == unix_index) {
                    print "auth       [success=2 default=ignore]  pam_sss.so          forward_pass"
                    print lines[i]
                } else {
                    print lines[i]
                }

                if (session_sss_count == 0 && i == session_unix_index) print "session    optional                   pam_sss.so"
            }
            if (mkhomedir_count == 0) print "session    required                   pam_mkhomedir.so    skel=/etc/skel/ umask=0077"
        }
    ' "$pam_file"
}

configure_arch_pam() {
    local pam_file="${1:-/etc/pam.d/system-auth}"
    local pam_dir staged

    if [ ! -f "$pam_file" ] || [ -L "$pam_file" ]; then
        print_error "Arch PAM file is missing, not regular, or a symlink: $pam_file"
        return 1
    fi
    pam_dir="$(dirname "$pam_file")"
    staged="$(mktemp "$pam_dir/.system-auth.dr-domain-join.XXXXXX")" || {
        print_error "Could not create a staged Arch PAM file beside $pam_file"
        return 1
    }
    if ! render_arch_pam_system_auth "$pam_file" > "$staged"; then
        rm -f -- "$staged"
        print_error "Arch PAM layout is not a supported native/managed system-auth structure; $pam_file is unchanged"
        return 1
    fi
    if cmp -s -- "$pam_file" "$staged"; then
        rm -f -- "$staged"
        print_info "Arch PAM system-auth already has the managed SSSD jump layout"
        return 0
    fi
    if ! chmod --reference="$pam_file" "$staged"; then
        rm -f -- "$staged"
        print_error "Could not preserve the mode while staging $pam_file"
        return 1
    fi
    if [ "$(stat -c '%u:%g' "$staged")" != "$(stat -c '%u:%g' "$pam_file")" ] &&
       ! chown --reference="$pam_file" "$staged" 2>/dev/null; then
        rm -f -- "$staged"
        print_error "Could not preserve ownership while staging $pam_file"
        return 1
    fi
    backup_config_file "$pam_file" || {
        rm -f -- "$staged"
        print_error "Could not back up $pam_file; refusing the Arch PAM update"
        return 1
    }
    if ! mv -f -- "$staged" "$pam_file"; then
        rm -f -- "$staged"
        print_error "Could not atomically install the Arch PAM update"
        return 1
    fi
    print_info "Configured native Arch PAM stack in $pam_file"
}

configure_debian_pam_mkhomedir() {
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
            backup_config_file "$pam_session"
            echo "$mkhomedir_line" >> "$pam_session"
            print_info "Added pam_mkhomedir to $pam_session"
        fi
    fi

    # Ubuntu 26.04+ sets use_first_pass on the pam_sss.so line in common-auth.
    # This prevents AD authentication because no prior PAM module provides a
    # password for SSSD to reuse. Remove it so pam_sss.so prompts independently.
    local pam_auth="/etc/pam.d/common-auth"
    if grep -q "pam_sss\.so.*use_first_pass" "$pam_auth" 2>/dev/null; then
        backup_config_file "$pam_auth"
        sed -i '/pam_sss\.so/ s/[[:space:]]*use_first_pass//' "$pam_auth"
        print_info "Removed use_first_pass from pam_sss.so in $pam_auth"
    else
        print_info "use_first_pass not set on pam_sss.so in $pam_auth — no change needed"
    fi
}

platform_configure_pam() {
    case "$PLATFORM_FAMILY" in
        arch) configure_arch_pam ;;
        debian) configure_debian_pam_mkhomedir ;;
        *)
            print_error "No PAM adapter exists for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
}

configure_pam_mkhomedir() {
    platform_validate_auth_stack || {
        print_error "Native PAM/authentication prerequisites are not present"
        return 1
    }
    platform_configure_pam
}

# ── Allow all domain users to log in ─────────────────────────────────────────

configure_realm_permissions() {
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        print_info "Arch backend uses SSSD's access_provider=simple; no realm permit command is required"
        return 0
    fi
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

# Arch does not have the realmd renewal helper used by SSSD's default
# ad_machine_account_password_renewal_opts (realm).  The authoritative Arch
# path is the root-owned Samba helper/timer below, which updates secrets.tdb
# and then explicitly rebuilds /etc/krb5.keytab before re-running testjoin.
platform_machine_account_renewal_policy() {
    case "$PLATFORM_FAMILY" in
        arch)
            cat << 'EOF'
Arch machine-account renewal policy:
  authority: dr-domain-machine-password-renew.service/timer
  schedule: daily with Persistent=true and RandomizedDelaySec=6h
  age gate: no password rotation until 25 days after the last successful rotation
  SSSD renewal: disabled with ad_maximum_machine_account_password_age=0
  ad_update_samba_machine_account_password: false (SSSD realm/adcli helper unavailable)
  authority: this helper alone updates Samba secrets.tdb and /etc/krb5.keytab
  normal sequence: age gate -> preflight -> testjoin -> changetrustpw -P -> bounded keytab create -> klist -k -> testjoin -> SSSD refresh -> timestamp
  repair sequence: preflight -> testjoin -> keytab create from the current Samba secret; no password rotation
  failure state: a root-owned repair marker is written if password rotation succeeds but keytab regeneration fails
EOF
            ;;
        debian)
            echo "Debian machine-account renewal policy: preserve existing realmd/adcli/SSSD behavior"
            ;;
        *)
            echo "No machine-account renewal policy for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
}

render_arch_machine_account_renewal_helper() {
    cat << EOF
#!/bin/bash
set -euo pipefail

DOMAIN="$DOMAIN"
REALM="$REALM"
STATE_DIR="\${DR_RENEWAL_STATE_DIR:-$STATE_DIR}"
LAST_SUCCESS="\$STATE_DIR/machine-password-last-success"
REPAIR_MARKER="\$STATE_DIR/machine-password-keytab-repair-needed"
LOCK_DIR="\${DR_RENEWAL_LOCK_DIR:-/run/dr-domain-machine-password-renew.lock}"
KEYTAB="\${DR_RENEWAL_KEYTAB:-/etc/krb5.keytab}"
MIN_AGE_SECONDS=2160000
RETRY_DELAYS=(2 5 10)
REPAIR_DIAGNOSTIC="\$STATE_DIR/keytab-before-failed-renewal.\$(date +%s)"

cleanup() {
    rmdir "\$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
    echo "Machine-account renewal blocked: \$*" >&2
    exit 1
}

require_root() {
    [ "\$(id -u)" -eq 0 ] || fail "run as root"
}

preflight() {
    local synchronized dc
    synchronized="\$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    [ "\$synchronized" = yes ] || fail "system clock is not synchronized"
    command -v host >/dev/null 2>&1 || fail "host is required for AD SRV discovery"
    host -t SRV "_kerberos._tcp.\$DOMAIN" >/dev/null 2>&1 || fail "AD Kerberos SRV discovery failed"
    dc="\$(host -t SRV "_kerberos._tcp.\$DOMAIN" 2>/dev/null | awk 'NF >= 8 {sub(/\.$/, "", \$NF); print \$NF; exit}')"
    [ -n "\$dc" ] || fail "no domain controller was returned by SRV discovery"
    getent hosts "\$dc" >/dev/null 2>&1 || fail "domain controller does not resolve"
    timeout 5 bash -c ":</dev/tcp/\$dc/88" >/dev/null 2>&1 || fail "domain controller port 88 is unreachable"
    command -v net >/dev/null 2>&1 || fail "Samba net is unavailable"
    command -v testparm >/dev/null 2>&1 || fail "testparm is unavailable"
    testparm -s /etc/samba/smb.conf >/dev/null 2>&1 || fail "smb.conf is invalid"
    [ -r "\$KEYTAB" ] || fail "keytab is not readable"
    [ -d "\$(dirname -- "\$KEYTAB")" ] && [ -w "\$(dirname -- "\$KEYTAB")" ] || fail "keytab parent is not writable"
    [ "\$(df -Pk "\$(dirname -- "\$KEYTAB")" | awk 'NR == 2 {print \$4}')" -ge 1024 ] || fail "insufficient free space for keytab diagnostics"
    if command -v sssctl >/dev/null 2>&1; then
        sssctl config-check >/dev/null 2>&1 || fail "SSSD configuration check failed"
    fi
}

validate_keytab() {
    local host_name
    command -v klist >/dev/null 2>&1 || { echo "klist is unavailable" >&2; return 1; }
    klist -k "\$KEYTAB" >/dev/null 2>&1 || { echo "keytab cannot be read" >&2; return 1; }
    LC_ALL=C klist -k "\$KEYTAB" | grep -qi "\$REALM" || { echo "keytab has no \$REALM principal" >&2; return 1; }
    host_name="\$(hostname -s 2>/dev/null || hostname)"
    LC_ALL=C klist -k "\$KEYTAB" | grep -Eiq "(host|cifs)/\${host_name}([.@]|$)" || {
        echo "keytab has no host/cifs principal for \$host_name" >&2
        return 1
    }
}

write_repair_marker() {
    mkdir -p "\$STATE_DIR"
    printf 'password_rotation_completed=unknown-keytab-sync-failed\\nold_keytab_diagnostic=%s\\n' "\$REPAIR_DIAGNOSTIC" > "\$REPAIR_MARKER"
    chmod 600 "\$REPAIR_MARKER"
    chown root:root "\$REPAIR_MARKER" 2>/dev/null || true
    echo "CRITICAL: Samba password changed but keytab regeneration failed." >&2
    echo "The old keytab is diagnostic evidence only; restoring it does not restore the old AD password." >&2
    echo "Run: dr-domain-machine-password-renew --repair-keytab" >&2
}

renew_keytab() {
    local delay
    for delay in "\${RETRY_DELAYS[@]}"; do
        if net ads keytab create; then
            return 0
        fi
        sleep "\$delay"
    done
    return 1
}

refresh_sssd() {
    if command -v sss_cache >/dev/null 2>&1; then
        sss_cache -E >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet sssd 2>/dev/null; then
        systemctl reload sssd >/dev/null 2>&1 || systemctl try-restart sssd >/dev/null 2>&1
    fi
    if command -v sssctl >/dev/null 2>&1; then
        sssctl config-check >/dev/null 2>&1 || fail "SSSD validation failed after renewal"
    fi
}

atomic_success_timestamp() {
    local tmp
    mkdir -p "\$STATE_DIR"
    tmp="\$LAST_SUCCESS.tmp.\$\$"
    date +%s > "\$tmp"
    chmod 600 "\$tmp"
    chown root:root "\$tmp" 2>/dev/null || true
    mv -f -- "\$tmp" "\$LAST_SUCCESS"
}

require_root
mkdir -p "\$STATE_DIR"
if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
    echo "Machine-account renewal is already running; exiting." >&2
    exit 0
fi

mode="\${1:-}"
case "\$mode" in
    --force|--repair-keytab|"") ;;
    *) echo "Usage: dr-domain-machine-password-renew [--force|--repair-keytab]" >&2; exit 2 ;;
esac

if [ -e "\$REPAIR_MARKER" ]; then
    preflight
    net ads testjoin >/dev/null 2>&1 || fail "net ads testjoin failed"
    renew_keytab || fail "keytab repair from the current Samba secret failed"
    validate_keytab || fail "repaired keytab validation failed"
    refresh_sssd
    rm -f -- "\$REPAIR_MARKER"
    echo "Outstanding keytab repair completed; no password rotation was performed."
    exit 0
fi

if [ "\$mode" = --repair-keytab ]; then
    preflight
    net ads testjoin >/dev/null 2>&1 || fail "net ads testjoin failed"
    renew_keytab || fail "keytab repair failed"
    validate_keytab || fail "repaired keytab validation failed"
    refresh_sssd
    rm -f -- "\$REPAIR_MARKER"
    echo "Keytab repaired from the current Samba machine secret; no password rotation was performed."
    exit 0
fi

now="\$(date +%s)"
last=0
if [ -r "\$LAST_SUCCESS" ]; then
    last="\$(cat "\$LAST_SUCCESS")"
fi
case "\$last" in ''|*[!0-9]*) last=0 ;; esac
if [ "\$mode" != --force ] && [ "\$last" -gt 0 ] && [ "\$((now - last))" -lt "\$MIN_AGE_SECONDS" ]; then
    echo "Machine-account password is younger than 25 days; no rotation performed."
    exit 0
fi

preflight
net ads testjoin >/dev/null 2>&1 || fail "net ads testjoin failed"

if [ -s "\$KEYTAB" ]; then
    cp -- "\$KEYTAB" "\$REPAIR_DIAGNOSTIC"
    chmod 600 "\$REPAIR_DIAGNOSTIC"
    chown root:root "\$REPAIR_DIAGNOSTIC" 2>/dev/null || true
fi
net ads changetrustpw -P || fail "Samba machine-password rotation failed"
if ! renew_keytab; then
    write_repair_marker
    exit 1
fi
if ! validate_keytab; then
    write_repair_marker
    exit 1
fi
net ads testjoin >/dev/null 2>&1 || fail "net ads testjoin failed after keytab regeneration"
refresh_sssd
atomic_success_timestamp
rm -f -- "\$REPAIR_MARKER"
echo "Samba machine password and SSSD keytab renewed successfully."
EOF
}

render_arch_machine_account_renewal_service() {
    cat << 'EOF'
[Unit]
Description=Renew the Samba AD machine account password and rebuild the Kerberos keytab
After=network-online.target sssd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dr-domain-machine-password-renew
EOF
}

render_arch_machine_account_renewal_timer() {
    cat << 'EOF'
[Unit]
Description=Periodic Samba AD machine-account renewal

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=6h

[Install]
WantedBy=timers.target
EOF
}

platform_machine_account_renewal_service_name() {
    echo "dr-domain-machine-password-renew.service"
}

platform_machine_account_renewal_timer_name() {
    echo "dr-domain-machine-password-renew.timer"
}

platform_initialize_machine_account_renewal_state() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    local marker="$STATE_DIR/machine-password-last-success"
    [ -f "$marker" ] && return 0
    mkdir -p "$STATE_DIR"
    date +%s > "$marker"
    chmod 600 "$marker"
    chown root:root "$marker" 2>/dev/null || true
    print_info "Initialized the Arch machine-password age clock after successful join validation"
}

platform_install_machine_account_renewal() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0

    local helper="/usr/local/sbin/dr-domain-machine-password-renew"
    local service="/etc/systemd/system/$(platform_machine_account_renewal_service_name)"
    local timer="/etc/systemd/system/$(platform_machine_account_renewal_timer_name)"
    backup_config_file "$helper"
    backup_config_file "$service"
    backup_config_file "$timer"
    render_arch_machine_account_renewal_helper > "$helper"
    render_arch_machine_account_renewal_service > "$service"
    render_arch_machine_account_renewal_timer > "$timer"
    chmod 755 "$helper"
    chmod 644 "$service" "$timer"
    chown root:root "$helper" "$service" "$timer"
    systemd-analyze verify "$service" "$timer"
    systemctl daemon-reload
    systemctl enable "$(platform_machine_account_renewal_timer_name)" >/dev/null
    print_info "Installed authoritative Samba machine-account renewal timer"
}

platform_verify_machine_account_renewal() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    local service="/etc/systemd/system/$(platform_machine_account_renewal_service_name)"
    local timer="/etc/systemd/system/$(platform_machine_account_renewal_timer_name)"
    [ -x /usr/local/sbin/dr-domain-machine-password-renew ] || return 1
    [ -f "$service" ] && [ -f "$timer" ] || return 1
    systemd-analyze verify "$service" "$timer" >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet "$(platform_machine_account_renewal_timer_name)" 2>/dev/null
}

platform_remove_machine_account_renewal() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    systemctl disable --now "$(platform_machine_account_renewal_timer_name)" >/dev/null 2>&1 || true
    rm -f /usr/local/sbin/dr-domain-machine-password-renew \
        "/etc/systemd/system/$(platform_machine_account_renewal_service_name)" \
        "/etc/systemd/system/$(platform_machine_account_renewal_timer_name)"
    systemctl daemon-reload
}

render_sssd_config() {
    cat << EOF
[sssd]
services = nss, pam
domains = $DOMAIN

[domain/$DOMAIN]
id_provider = ad
ad_domain = $DOMAIN
krb5_realm = $REALM
use_fully_qualified_names = False
access_provider = simple
ad_enable_gc = false
krb5_renewable_lifetime = 7d
krb5_renew_interval = 1h
krb5_ccname_template = FILE:/tmp/krb5cc_%U
ldap_id_mapping = True
cache_credentials = True
fallback_homedir = /home/%u
EOF
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        printf 'default_shell = %s\n' "$ARCH_SSSD_DEFAULT_SHELL"
        cat << 'EOF'
# Arch uses the Samba renewal timer because the SSSD default realm/adcli
# renewal helper is unavailable. Keeping this disabled avoids two competing
# password-renewal authorities.
ad_maximum_machine_account_password_age = 0
ad_update_samba_machine_account_password = false
EOF
    fi
}

platform_login_shell_is_acceptable() {
    local login_shell="${1:-}" supported_shells="${DR_SUPPORTED_SHELLS_FILE:-/etc/shells}"
    case "$login_shell" in
        /*) ;;
        *) return 1 ;;
    esac
    [ -f "$login_shell" ] && [ -x "$login_shell" ] || return 1
    [ -r "$supported_shells" ] || return 1
    awk -v expected="$login_shell" '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            if (line == expected) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$supported_shells"
}

platform_validate_arch_default_shell() {
    [ "$PLATFORM_FAMILY" = arch ] || return 0
    if ! platform_login_shell_is_acceptable "$ARCH_SSSD_DEFAULT_SHELL"; then
        print_error "Configured Arch SSSD default shell '$ARCH_SSSD_DEFAULT_SHELL' is not an executable shell listed in $DR_SUPPORTED_SHELLS_FILE"
        return 1
    fi
}

configure_sssd_settings() {
    local sssd_conf="/etc/sssd/sssd.conf"
    print_info "Applying SSSD settings ($sssd_conf)..."

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        platform_validate_arch_default_shell || return 1
        mkdir -p "$(dirname "$sssd_conf")"
        backup_config_file "$sssd_conf"
        render_sssd_config > "$sssd_conf"
        chmod 600 "$sssd_conf"
        chown root:root "$sssd_conf"
        print_info "Generated native Arch SSSD AD-provider configuration"
        return 0
    fi

    if [ ! -f "$sssd_conf" ]; then
        print_warning "$sssd_conf not found — skipping SSSD settings (realm join may not have run)"
        return 0
    fi

    backup_config_file "$sssd_conf"

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

# ── Configure NSS for SSSD identity resolution ───────────────────────────────

render_arch_nsswitch_with_sss() {
    local nsswitch="${1:-}"
    [ -f "$nsswitch" ] && [ ! -L "$nsswitch" ] || {
        print_error "Arch NSS configuration is not a regular non-symlink file: ${nsswitch:-<empty>}" >&2
        return 1
    }

    # Preserve each line byte-for-byte unless it is one of the supported NSS
    # databases and lacks the standalone `sss` service token. Bracketed NSS
    # actions are parsed separately so comments or action text cannot be
    # mistaken for a provider.
    awk '
        BEGIN {
            target["passwd"] = 1
            target["group"] = 1
            target["shadow"] = 1
            target["initgroups"] = 1
        }
        {
            original = $0
            content = original
            comment = ""
            hash = index(content, "#")
            if (hash > 0) {
                comment = substr(content, hash)
                content = substr(content, 1, hash - 1)
            }

            probe = content
            sub(/^[[:space:]]*/, "", probe)
            colon = index(probe, ":")
            if (colon == 0) {
                print original
                next
            }

            header = substr(probe, 1, colon - 1)
            sub(/^[[:space:]]*/, "", header)
            sub(/[[:space:]]*$/, "", header)
            if (!(header in target)) {
                print original
                next
            }

            seen[header]++
            rest = substr(probe, colon + 1)
            scan = rest
            sub(/^[[:space:]]*/, "", scan)
            sub(/[[:space:]]*$/, "", scan)
            if (scan == "") {
                printf "Unsafe %s NSS database line: no providers are configured.\n", header > "/dev/stderr"
                errors = 1
                print original
                next
            }

            token_count = split(scan, token, /[[:space:]]+/)
            bracket_depth = 0
            provider_count = 0
            sss_count = 0
            line_error = 0
            for (i = 1; i <= token_count; i++) {
                value = token[i]
                depth_before = bracket_depth
                opens_text = value
                closes_text = value
                opens = gsub(/\[/, "", opens_text)
                closes = gsub(/\]/, "", closes_text)

                if (depth_before == 0 && substr(value, 1, 1) != "[") {
                    if (value !~ /^[[:alnum:]_.-]+$/) {
                        printf "Unsafe %s NSS database line: malformed provider token %s.\n", header, value > "/dev/stderr"
                        line_error = 1
                    } else {
                        provider_count++
                        if (value == "sss") sss_count++
                    }
                }

                bracket_depth += opens - closes
                if (bracket_depth < 0) line_error = 1
            }
            if (bracket_depth != 0) line_error = 1
            if (provider_count == 0) line_error = 1
            if (sss_count > 1) {
                printf "Unsafe %s NSS database line: duplicate sss service tokens.\n", header > "/dev/stderr"
                line_error = 1
            }
            if (line_error) {
                printf "Unsafe %s NSS database line; refusing to rewrite it.\n", header > "/dev/stderr"
                errors = 1
                print original
                next
            }

            if (sss_count == 1) {
                print original
                next
            }

            trimmed = content
            sub(/[[:space:]]+$/, "", trimmed)
            trailing = substr(content, length(trimmed) + 1)
            print trimmed " sss" trailing comment
            next
        }
        END {
            required[1] = "passwd"
            required[2] = "group"
            required[3] = "shadow"
            for (i = 1; i <= 3; i++) {
                database = required[i]
                if (seen[database] != 1) {
                    printf "Required NSS database %s must have exactly one valid line; found %d.\n", database, seen[database] > "/dev/stderr"
                    errors = 1
                }
            }
            if (seen["initgroups"] > 1) {
                printf "Optional NSS database initgroups has multiple lines; refusing an ambiguous update.\n" > "/dev/stderr"
                errors = 1
            }
            if (errors) exit 2
        }
    ' "$nsswitch"
}

configure_arch_nss_sss() {
    local nsswitch="${1:-/etc/nsswitch.conf}"
    local directory temporary

    [ -f "$nsswitch" ] && [ ! -L "$nsswitch" ] || {
        print_error "Cannot configure Arch NSS: $nsswitch is missing, not regular, or a symlink"
        return 1
    }
    directory="$(dirname "$nsswitch")"
    temporary="$(mktemp "$directory/.nsswitch.conf.dr-domain-join.XXXXXX")" || {
        print_error "Cannot create a staged Arch NSS configuration beside $nsswitch"
        return 1
    }

    if ! render_arch_nsswitch_with_sss "$nsswitch" > "$temporary"; then
        rm -f -- "$temporary"
        print_error "Arch NSS configuration could not be updated safely; $nsswitch is unchanged"
        return 1
    fi

    if cmp -s -- "$nsswitch" "$temporary"; then
        rm -f -- "$temporary"
        print_info "Arch NSS databases already include the sss provider"
        return 0
    fi

    if ! chmod --reference="$nsswitch" "$temporary"; then
        rm -f -- "$temporary"
        print_error "Could not preserve the mode while staging $nsswitch"
        return 1
    fi
    if [ "$(stat -c '%u:%g' "$temporary")" != "$(stat -c '%u:%g' "$nsswitch")" ] &&
       ! chown --reference="$nsswitch" "$temporary" 2>/dev/null; then
        rm -f -- "$temporary"
        print_error "Could not preserve ownership while staging $nsswitch"
        return 1
    fi

    backup_config_file "$nsswitch" || {
        rm -f -- "$temporary"
        print_error "Could not back up $nsswitch; refusing the Arch NSS update"
        return 1
    }
    if ! mv -f -- "$temporary" "$nsswitch"; then
        rm -f -- "$temporary"
        print_error "Could not atomically install the Arch NSS configuration; the original file remains available in its timestamped backup"
        return 1
    fi
    print_info "Configured passwd, group, shadow, and existing initgroups NSS databases to use SSSD"
}

platform_configure_nss() {
    case "$PLATFORM_FAMILY" in
        arch) configure_arch_nss_sss "${1:-/etc/nsswitch.conf}" ;;
        debian) return 0 ;;
        *)
            print_error "No NSS adapter exists for platform family '$PLATFORM_FAMILY'"
            return 1
            ;;
    esac
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

sudoers_escape_identifier() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value// /\\ }"
    value="${value//#/\\#}"
    value="${value//,/\\,}"
    printf '%s\n' "$value"
}

normalize_domain_user_for_sudoers() {
    local user="${1:-}"
    user="${user##*\\}"
    user="${user%%@*}"
    case "$user" in
        ""|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    printf '%s\n' "$user"
}

render_workstation_sudoers() {
    local users_group admins_group
    users_group="$(sudoers_escape_identifier "$DR_WORKSTATION_USERS_GROUP")"
    admins_group="$(sudoers_escape_identifier "$DR_WORKSTATION_ADMINS_GROUP")"
    cat << EOF
# Managed by Ontrack Recovery Workstation Provisioner
# Members of $DR_WORKSTATION_ADMINS_GROUP are workstation administrators.
%$admins_group ALL=(ALL:ALL) ALL

# Every authenticated DR domain user may mount the standard Tool Server.
# SSSD is configured with use_fully_qualified_names=False, so the AD group is
# exposed as the short group name "domain users". The escaped space is required.
%domain\\ users ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools

# Locally managed workstation users may also run the remaining managed helpers.
%$users_group ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools
%$users_group ALL=(root) NOPASSWD: /usr/local/sbin/dr-post-mount-provision
%$users_group ALL=(root) NOPASSWD: /usr/local/sbin/dr-launch-kit
EOF
}

render_kit_launcher_sudoers() {
    local user
    user="$(normalize_domain_user_for_sudoers "${1:-}")" || return 1
    user="$(sudoers_escape_identifier "$user")"
    cat << EOF
# Managed by DR Domain Join
# KIT.sh owns the root cache copy/cleanup. Preserve only the invoking user's
# FILE credential-cache selector for the narrow KIT launcher command.
# SUDO_UID and SUDO_USER are supplied by sudo itself.
Defaults!/usr/local/sbin/dr-launch-kit env_keep += "KRB5CCNAME"
$user ALL=(root) NOPASSWD: /usr/local/sbin/dr-launch-kit
EOF
}

stage_generated_configurations() {
    local stage_dir="${1:-}"
    [ -n "$stage_dir" ] || {
        print_error "A staging directory is required"
        return 1
    }
    mkdir -p "$stage_dir"
    render_krb5_config > "$stage_dir/krb5.conf"
    render_sssd_config > "$stage_dir/sssd.conf"
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        local stage_cruid="${DR_TOOLS_MOUNT_CRUID:-}"
        render_arch_tools_mount_unit "/mnt/x" "$TOOLS_SERVER" "$stage_cruid" > "$stage_dir/mnt-x.mount"
        render_arch_tools_automount_unit "/mnt/x" > "$stage_dir/mnt-x.automount"
        render_arch_tools_mount_helper "$stage_cruid" > "$stage_dir/mount-kit-tools"
        render_arch_machine_account_renewal_service > "$stage_dir/dr-domain-machine-password-renew.service"
        render_arch_machine_account_renewal_timer > "$stage_dir/dr-domain-machine-password-renew.timer"
        if platform_validate_drip_search_roots; then
            local drip_entry drip_mount drip_automount
            while IFS= read -r drip_entry; do
                [ -n "$drip_entry" ] || continue
                drip_mount="$(drip_mount_unit_name "$drip_entry")"
                drip_automount="$(drip_automount_unit_name "$drip_entry")"
                render_arch_drip_mount_unit "$drip_entry" > "$stage_dir/$drip_mount"
                render_arch_drip_automount_unit "$drip_entry" > "$stage_dir/$drip_automount"
            done < <(platform_drip_search_entries)
            render_drip_search_mount_helper > "$stage_dir/dr-drip-search"
        fi
    else
        render_autofs_master_maps > "$stage_dir/auto.master"
        render_autofs_cifs_map > "$stage_dir/auto.net.cifs"
    fi
    render_workstation_sudoers > "$stage_dir/sudoers.d-zz-dr_workstation_users"
    render_arch_pam_sss_lines > "$stage_dir/system-auth-adapter.lines"
    chmod 600 "$stage_dir/krb5.conf" "$stage_dir/sssd.conf"
    chmod 440 "$stage_dir/sudoers.d-zz-dr_workstation_users"
    printf '%s\n' "$stage_dir"
}

render_domain_user_sudoers() {
    local user
    user="$(normalize_domain_user_for_sudoers "${1:-}")" || return 1
    printf '%s ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools\n' "$(sudoers_escape_identifier "$user")"
}

install_dr_workstation_manager() {
    print_info "Installing Ontrack workstation user management command..."

    groupadd -f "$DR_WORKSTATION_USERS_GROUP"
    groupadd -f "$DR_WORKSTATION_ADMINS_GROUP"

    local sudoers_file="/etc/sudoers.d/zz-dr_workstation_users"
    backup_config_file "$sudoers_file"
    render_workstation_sudoers > "$sudoers_file"
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

    if command -v net >/dev/null 2>&1 && [ -s /etc/krb5.keytab ] && net ads testjoin >/dev/null 2>&1; then
        echo "[OK] Samba ADS membership is configured"
    elif command -v realm >/dev/null 2>&1 && realm list 2>/dev/null | grep -q "configured: kerberos-member"; then
        echo "[OK] Realm membership is configured"
    else
        echo "[FAIL] Domain membership is not configured"
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

    if command -v net >/dev/null 2>&1 && net ads testjoin >/dev/null 2>&1; then
        echo "[OK] Machine account trust is valid"
    elif command -v adcli >/dev/null 2>&1 && adcli testjoin -D "$DOMAIN" >/dev/null 2>&1; then
        echo "[OK] Machine account trust is valid"
    else
        echo "[FAIL] Machine account trust could not be validated"
        failed=1
    fi

    if [ -f /etc/systemd/system/dr-domain-machine-password-renew.timer ]; then
        if systemctl is-enabled --quiet dr-domain-machine-password-renew.timer 2>/dev/null; then
            echo "[OK] Arch Samba machine-account renewal timer is enabled"
        else
            echo "[FAIL] Arch Samba machine-account renewal timer is not enabled"
            failed=1
        fi
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

# Rendered into the root KIT launcher. This deliberately validates the cache
# selected by sudo without opening, copying, or creating a root cache. KIT.sh
# remains the sole owner of /tmp/krb5cc_0 creation and EXIT-trap cleanup.
render_kit_cache_validator() {
    cat << 'EOF'
validate_kit_invoking_cache() {
    local cache_spec="${KRB5CCNAME:-}"
    local cache_path=""
    local expected_prefix=""
    local cache_suffix=""
    local owner=""
    local mode=""
    local mode_value=0
    local principal=""
    local principal_realm=""
    local initial_signature=""
    local final_signature=""

    KIT_VALIDATED_CACHE_PATH=""
    KIT_VALIDATED_CACHE_OWNER=""
    KIT_VALIDATED_CACHE_MODE=""
    KIT_VALIDATED_PRINCIPAL=""

    case "${SUDO_UID:-}" in
        ''|0|*[!0-9]*)
            echo "KIT launch requires a non-root SUDO_UID from the domain-user sudo invocation." >&2
            return 1
            ;;
    esac

    case "$cache_spec" in
        FILE:*) cache_path="${cache_spec#FILE:}" ;;
        *)
            echo "KIT launch requires KRB5CCNAME to use the FILE: cache type." >&2
            return 1
            ;;
    esac

    expected_prefix="/tmp/krb5cc_${SUDO_UID}"
    case "$cache_path" in
        "$expected_prefix") ;;
        "$expected_prefix"_*)
            cache_suffix="${cache_path#${expected_prefix}_}"
            printf '%s\n' "$cache_suffix" | LC_ALL=C grep -Eq '^[A-Za-z0-9_-]+$' || {
                echo "KIT launch rejected an unsafe cache suffix." >&2
                return 1
            }
            ;;
        *)
            echo "KIT launch requires the invoking user's /tmp FILE cache path." >&2
            return 1
            ;;
    esac

    case "$cache_path" in
        *[$'\t\r\n ']*|*\\*|*..*|*[!A-Za-z0-9_./-]*)
            echo "KIT launch rejected an unsafe Kerberos cache path." >&2
            return 1
            ;;
    esac

    if [ -z "$cache_path" ] || [ "$cache_path" = "/tmp/krb5cc_0" ]; then
        echo "KIT launch rejected an empty or root-owned Kerberos cache path." >&2
        return 1
    fi
    if [ ! -f "$cache_path" ] || [ -L "$cache_path" ]; then
        echo "KIT launch requires a regular, non-symlink Kerberos cache file." >&2
        return 1
    fi

    initial_signature="$(stat -c '%d:%i:%F:%u:%a' -- "$cache_path" 2>/dev/null || true)"
    [ -n "$initial_signature" ] || {
        echo "KIT launch could not stat the Kerberos cache." >&2
        return 1
    }
    owner="$(stat -c '%u' -- "$cache_path" 2>/dev/null || true)"
    if [ "$owner" != "$SUDO_UID" ]; then
        echo "KIT launch rejected a Kerberos cache not owned by SUDO_UID." >&2
        return 1
    fi

    mode="$(stat -c '%a' -- "$cache_path" 2>/dev/null || true)"
    case "$mode" in
        ''|*[!0-7]*)
            echo "KIT launch could not inspect Kerberos cache permissions." >&2
            return 1
            ;;
    esac
    mode_value=$((8#$mode))
    if (( mode_value & 07177 )); then
        echo "KIT launch requires a Kerberos cache with mode 0600 or stricter." >&2
        return 1
    fi

    command -v klist >/dev/null 2>&1 || {
        echo "KIT launch requires klist to validate the invoking user's ticket." >&2
        return 1
    }
    LC_ALL=C klist -s -c "$cache_path" 2>/dev/null || {
        echo "KIT launch requires a usable Kerberos credential cache." >&2
        return 1
    }

    principal="$(LC_ALL=C klist -c "$cache_path" 2>/dev/null | LC_ALL=C awk -F': ' '/Default principal:/ {print $2; exit}')"
    principal_realm="${principal##*@}"
    if [ -z "$principal" ] || [ "${principal_realm^^}" != "DR.KODR.LOCAL" ]; then
        echo "KIT launch requires a ticket principal in DR.KODR.LOCAL." >&2
        return 1
    fi

    if [ ! -f "$cache_path" ] || [ -L "$cache_path" ]; then
        echo "KIT launch detected a changed Kerberos cache path." >&2
        return 1
    fi
    final_signature="$(stat -c '%d:%i:%F:%u:%a' -- "$cache_path" 2>/dev/null || true)"
    if [ -z "$final_signature" ] || [ "$initial_signature" != "$final_signature" ]; then
        echo "KIT launch detected a Kerberos cache changed during validation." >&2
        return 1
    fi

    KIT_VALIDATED_CACHE_PATH="$cache_path"
    KIT_VALIDATED_CACHE_OWNER="$owner"
    KIT_VALIDATED_CACHE_MODE="$mode"
    KIT_VALIDATED_PRINCIPAL="$principal"
}

sanitize_kit_evidence() {
    LC_ALL=C printf '%s' "${1:-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}
EOF
}

render_kit_credential_self_test() {
    cat << 'EOF'
if [ "${1:-}" = "--credential-self-test" ]; then
    [ "$(id -u)" -eq 0 ] || {
        echo "validation=FAIL"
        echo "reason=root-helper-required"
        exit 1
    }
    evidence_user="$(sanitize_kit_evidence "${SUDO_USER:-unknown}")"
    evidence_uid="$(sanitize_kit_evidence "${SUDO_UID:-unset}")"
    evidence_cache="<unavailable>"
    case "${KRB5CCNAME:-}" in
        FILE:*) evidence_cache="$(sanitize_kit_evidence "$(basename -- "${KRB5CCNAME#FILE:}" 2>/dev/null || true)")" ;;
    esac
    if validate_kit_invoking_cache >/dev/null 2>&1; then
        printf 'invoking_user=%s\n' "$evidence_user"
        printf 'invoking_uid=%s\n' "$evidence_uid"
        printf 'cache_basename=%s\n' "$(sanitize_kit_evidence "$(basename -- "$KIT_VALIDATED_CACHE_PATH")")"
        printf 'owner_uid=%s\n' "$(sanitize_kit_evidence "$KIT_VALIDATED_CACHE_OWNER")"
        printf 'numeric_mode=%s\n' "$(sanitize_kit_evidence "$KIT_VALIDATED_CACHE_MODE")"
        printf 'validated_principal=%s\n' "$(sanitize_kit_evidence "$KIT_VALIDATED_PRINCIPAL")"
        echo "validation=PASS"
        exit 0
    fi
    printf 'invoking_user=%s\n' "$evidence_user"
    printf 'invoking_uid=%s\n' "$evidence_uid"
    printf 'cache_basename=%s\n' "$evidence_cache"
    echo 'owner_uid=<unavailable>'
    echo 'numeric_mode=<unavailable>'
    echo 'validated_principal=<unavailable>'
    echo 'validation=FAIL'
    exit 1
fi
EOF
}


# ── Post-mount provisioning helper ───────────────────────────────────────────
install_post_mount_provision_helper() {
    print_info "Installing post-mount provisioning helper for KIT installer and workstation branding..."
    install_live_validation_helper

    # Install/repair the canonical root KIT launch helper now, not only after
    # post-mount provisioning runs. The desktop shortcut and sudoers rule both
    # target this one helper. It is intentionally narrow: it only cd's into the
    # KIT runtime directory and launches KIT.sh.
    local kit_runtime_dir
    local escaped_kit_runtime_dir
    local kit_cache_validator
    local kit_credential_self_test
    local drip_launcher_support
    kit_runtime_dir="$(dirname "$KIT_INSTALLER_PATH")"
    kit_cache_validator="$(render_kit_cache_validator)"
    kit_credential_self_test="$(render_kit_credential_self_test)"
    drip_launcher_support="$(render_drip_launcher_support)"

    # Generate this helper with quoted heredoc segments so runtime variables
    # such as $LOG, $KIT_DIR, ${1:-}, and $? are preserved until launch time,
    # while the shared cache validator is inserted as generated shell code.
    {
    cat << 'EOF'
#!/bin/bash
set -u

LOG="/var/log/dr-launch-kit.log"
KIT_DIR="__KIT_RUNTIME_DIR__"
KIT_SCRIPT="./KIT.sh"

EOF
    printf '%s\n' "$kit_cache_validator"
    printf '%s\n' "$kit_credential_self_test"
    cat << 'EOF'

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
touch "$LOG" 2>/dev/null || true
chmod 644 "$LOG" 2>/dev/null || true

if [ "${1:-}" = "--sudo-self-test" ]; then
    exit 0
fi

if [ "${1:-}" = "--access-self-test" ]; then
    [ "$(id -u)" -eq 0 ] || { echo "--access-self-test must run as root" >&2; exit 1; }
    [ -r "$KIT_DIR/KIT.sh" ] || { echo "KIT.sh is not readable: $KIT_DIR/KIT.sh" >&2; exit 1; }
    while IFS= read -r -d '' runtime_file; do
        [ -r "$runtime_file" ] || { echo "KIT runtime file is not readable: $runtime_file" >&2; exit 1; }
    done < <(find "$KIT_DIR" -type f -print0)
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

validate_kit_invoking_cache
EOF
    printf '%s\n' "$drip_launcher_support"
    cat << 'EOF'

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
    } > /usr/local/sbin/dr-launch-kit
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
TOOLS_SOURCE="//$TOOLS_SERVER/Tools"
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

tools_mount_is_authoritative() {
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt --noheadings --raw --target /mnt/x --output FSTYPE,SOURCE 2>/dev/null \
        | awk -v expected="\$TOOLS_SOURCE" '\$1 == "cifs" && \$2 == expected { found=1 } END { exit(found ? 0 : 1) }'
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
$kit_cache_validator
$kit_credential_self_test

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

if [ "\${1:-}" = "--access-self-test" ]; then
    [ "\$(id -u)" -eq 0 ] || { echo "--access-self-test must run as root" >&2; exit 1; }
    [ -r "\$KIT_DIR/KIT.sh" ] || { echo "KIT.sh is not readable: \$KIT_DIR/KIT.sh" >&2; exit 1; }
    while IFS= read -r -d '' runtime_file; do
        [ -r "\$runtime_file" ] || { echo "KIT runtime file is not readable: \$runtime_file" >&2; exit 1; }
    done < <(find "\$KIT_DIR" -type f -print0)
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

validate_kit_invoking_cache
$drip_launcher_support

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

if [ "\${1:-}" = "--access-self-test" ]; then
    [ "\$(id -u)" -eq 0 ] || { echo "--access-self-test must run as root" >&2; exit 1; }
    [ -r "\$KIT_INSTALLER_PATH" ] || { echo "KIT installer is not readable: \$KIT_INSTALLER_PATH" >&2; exit 1; }
    [ -r "\$(dirname "\$KIT_INSTALLER_PATH")/KIT.sh" ] || { echo "KIT.sh is not readable" >&2; exit 1; }
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

if ! tools_mount_is_authoritative; then
    log "DR Tools share is not an authoritative CIFS mount at /mnt/x; refusing post-mount provisioning."
    exit 1
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
  net ads testjoin 2>/dev/null || realm list
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
        render_kit_launcher_sudoers "$kit_user" > "$kit_sudoers_file"
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


render_autofs_master_maps() {
    cat << 'EOF'
/smb    /etc/auto.net.cifs    --timeout=300 --ghost
/net    /etc/auto.net.cifs    --timeout=300 --ghost
EOF
}

render_autofs_cifs_map() {
    cat << 'EOF'
#!/bin/bash
key="$1"
[ -z "$key" ] && exit 1
mapfile="/etc/autofs.d/$key"
mkdir -p /etc/autofs.d
if [ ! -f "$mapfile" ]; then
    printf '*\t-fstype=cifs,sec=krb5,cruid=${UID},vers=3.0\t://%s/&\n' "$key" > "$mapfile"
fi
printf -- '-fstype=autofs\tfile:%s\n' "$mapfile"
EOF
}

tools_mount_unit_name() {
    command -v systemd-escape >/dev/null 2>&1 || return 1
    systemd-escape --path --suffix=mount "${1:-/mnt/x}"
}

tools_automount_unit_name() {
    command -v systemd-escape >/dev/null 2>&1 || return 1
    systemd-escape --path --suffix=automount "${1:-/mnt/x}"
}

resolve_domain_user_uid() {
    local user="${1:-}" passwd_line resolved_name resolved_uid resolved_home resolved_shell separators
    local -a records
    [ -n "$user" ] || return 1
    mapfile -t records < <(getent passwd "$user" 2>/dev/null || true)
    [ "${#records[@]}" -eq 1 ] || return 1
    passwd_line="${records[0]}"
    separators="${passwd_line//[^:]/}"
    [ "${#separators}" -eq 6 ] || return 1
    IFS=: read -r resolved_name _ resolved_uid _ _ resolved_home resolved_shell <<< "$passwd_line"
    [ -n "$resolved_name" ] || return 1
    case "$resolved_uid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(id -u "$resolved_name" 2>/dev/null || true)" = "$resolved_uid" ] || return 1
    # A local account with the same name is not proof of an SSSD/domain
    # identity. Never bind a Kerberos CIFS mount to that local UID.
    if awk -F: -v user="$resolved_name" '$1 == user { found=1 } END { exit(found ? 0 : 1) }' /etc/passwd 2>/dev/null; then
        return 1
    fi
    [ -n "$resolved_home" ] || return 1
    platform_login_shell_is_acceptable "$resolved_shell" || return 1
    printf '%s\n' "$resolved_uid"
}

diagnose_selected_domain_user_login_identity() {
    local user="${1:-}" passwd_line resolved_name resolved_uid resolved_home resolved_shell separators
    local -a records
    [ -n "$user" ] || return 1
    mapfile -t records < <(getent passwd "$user" 2>/dev/null || true)
    [ "${#records[@]}" -eq 1 ] || return 1
    passwd_line="${records[0]}"
    separators="${passwd_line//[^:]/}"
    [ "${#separators}" -eq 6 ] || return 1
    IFS=: read -r resolved_name _ resolved_uid _ _ resolved_home resolved_shell <<< "$passwd_line"
    [ -n "$resolved_name" ] || return 1
    case "$resolved_uid" in ''|*[!0-9]*) return 1 ;; esac
    if [ -z "$resolved_home" ]; then
        print_error "Selected domain user $user has an empty home directory in the normal NSS passwd record"
        return 1
    fi
    if [ -z "$resolved_shell" ]; then
        print_error "Selected domain user $user has an empty login shell in the normal NSS passwd record"
        return 1
    fi
    if ! platform_login_shell_is_acceptable "$resolved_shell"; then
        print_error "Selected domain user $user has an unavailable or unsupported login shell '$resolved_shell'"
        return 1
    fi
    return 0
}

diagnose_sss_direct_user_uid() {
    local user="${1:-}" passwd_line resolved_uid separators
    local -a records
    [ -n "$user" ] || return 1
    mapfile -t records < <(getent -s sss passwd "$user" 2>/dev/null || true)
    [ "${#records[@]}" -eq 1 ] || return 1
    passwd_line="${records[0]}"
    separators="${passwd_line//[^:]/}"
    [ "${#separators}" -eq 6 ] || return 1
    IFS=: read -r _ _ resolved_uid _ _ _ _ <<< "$passwd_line"
    case "$resolved_uid" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$resolved_uid"
}

tools_mount_cruid() {
    local uid="${DR_TOOLS_MOUNT_CRUID:-}"
    if [ "$PLATFORM_FAMILY" = arch ]; then
        local resolved_domain_uid
        resolved_domain_uid="$(resolve_domain_user_uid "${DOMAIN_SUDO_USER:-}" || true)"
        [ -n "$resolved_domain_uid" ] || {
            print_error "Selected Arch domain user '${DOMAIN_SUDO_USER:-}' does not resolve through NSS/SSSD"
            print_error "No local UID or SUDO_UID fallback will be used for /mnt/x"
            return 1
        }
        if [ -n "$uid" ] && [ "$uid" != "$resolved_domain_uid" ]; then
            print_error "Persisted Tool Server cruid=$uid does not match resolved domain-user UID $resolved_domain_uid"
            return 1
        fi
        uid="$resolved_domain_uid"
    else
        # Preserve the established Debian behavior. Arch deliberately does
        # not use these fallbacks because a local UID must never stand in for
        # an unresolved domain identity.
        if [ -z "$uid" ] && [ -n "${DOMAIN_SUDO_USER:-}" ]; then
            uid="$(id -u "$DOMAIN_SUDO_USER" 2>/dev/null || true)"
        fi
        if [ -z "$uid" ] && [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID}" != 0 ]; then
            uid="$SUDO_UID"
        fi
    fi
    case "$uid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$uid"
}

render_arch_tools_mount_unit() {
    local mount_point="${1:-/mnt/x}"
    local server="${2:-$TOOLS_SERVER}"
    local cruid="${3:-${DR_TOOLS_MOUNT_CRUID:-}}"
    case "$cruid" in
        ''|*[!0-9]*)
            print_error "Arch Tool Server unit requires the logged-in domain user's numeric UID as cruid" >&2
            return 1
            ;;
    esac
    cat << EOF
[Unit]
Description=DR Tool Server CIFS mount
Wants=network-online.target
After=network-online.target

[Mount]
What=//$server/Tools
Where=$mount_point
Type=cifs
Options=_netdev,nofail,sec=krb5,cruid=$cruid,vers=3.0
TimeoutSec=30s
EOF
}

render_arch_tools_automount_unit() {
    local mount_point="${1:-/mnt/x}"
    cat << EOF
[Unit]
Description=On-demand DR Tool Server CIFS automount

[Automount]
Where=$mount_point
TimeoutIdleSec=300s

[Install]
WantedBy=multi-user.target
EOF
}

drip_mount_unit_name() {
    local entry="${1:-}"
    command -v systemd-escape >/dev/null 2>&1 || return 1
    systemd-escape --path --suffix=mount "/smb/$entry"
}

drip_automount_unit_name() {
    local entry="${1:-}"
    command -v systemd-escape >/dev/null 2>&1 || return 1
    systemd-escape --path --suffix=automount "/smb/$entry"
}

render_arch_drip_mount_unit() {
    local entry="${1:-}"
    local server share
    validate_drip_search_root_entry "$entry" || return 1
    server="${entry%%/*}"
    share="${entry#*/}"
    cat << EOF
[Unit]
Description=Configured DRIP search CIFS mount //$server/$share

[Mount]
What=//$server/$share
Where=/smb/$server/$share
Type=cifs
Options=_netdev,nofail,sec=krb5,cruid=0,vers=3.0
TimeoutSec=30s
EOF
}

render_arch_drip_automount_unit() {
    local entry="${1:-}"
    validate_drip_search_root_entry "$entry" || return 1
    cat << EOF
[Unit]
Description=On-demand configured DRIP search automount /smb/$entry

[Automount]
Where=/smb/$entry
TimeoutIdleSec=300s
EOF
}

render_drip_search_mount_helper() {
    cat << EOF
#!/bin/bash
set -euo pipefail

MANIFEST="${DR_DRIP_MANIFEST}"
UNIT_DIR="${DR_DRIP_UNIT_DIR}"

require_root() {
    [ "\$(id -u)" -eq 0 ] || { echo "This DRIP search helper requires root." >&2; exit 1; }
}

read_manifest() {
    [ -r "\$MANIFEST" ] || return 0
    while IFS=$'\\t' read -r entry mount_unit automount_unit; do
        [ -n "\$entry" ] || continue
        printf '%s\\t%s\\t%s\\n' "\$entry" "\$mount_unit" "\$automount_unit"
    done < "\$MANIFEST"
}

start_roots() {
    require_root
    local entry mount_unit automount_unit
    while IFS=$'\\t' read -r entry mount_unit automount_unit; do
        [ -n "\$entry" ] || continue
        if ! systemctl start "\$automount_unit" || ! systemctl is-active --quiet "\$automount_unit"; then
            echo "DRIP search start failed for \$automount_unit; attempting safe cleanup." >&2
            cleanup_roots || true
            return 1
        fi
    done < <(read_manifest)
}

cleanup_roots() {
    require_root
    local -a entries=() mounts=() automounts=()
    local entry mount_unit automount_unit i failed=0
    while IFS=$'\\t' read -r entry mount_unit automount_unit; do
        [ -n "\$entry" ] || continue
        entries+=("\$entry")
        mounts+=("\$mount_unit")
        automounts+=("\$automount_unit")
    done < <(read_manifest)

    # Stop automounts first so no new target-path trigger can occur.
    for ((i=\${#automounts[@]}-1; i>=0; i--)); do
        if ! systemctl stop "\${automounts[i]}"; then
            echo "BUSY: could not stop DRIP automount \${automounts[i]}; preserving diagnostics." >&2
            failed=1
        fi
    done
    for ((i=\${#mounts[@]}-1; i>=0; i--)); do
        if ! systemctl stop "\${mounts[i]}"; then
            echo "BUSY: could not stop DRIP mount \${mounts[i]}; preserving diagnostics." >&2
            failed=1
        fi
    done
    return "\$failed"
}

status_roots() {
    require_root
    local entry mount_unit automount_unit
    while IFS=$'\\t' read -r entry mount_unit automount_unit; do
        [ -n "\$entry" ] || continue
        printf 'entry=%s mount=%s automount=%s active=' "\$entry" "\$mount_unit" "\$automount_unit"
        if systemctl is-active --quiet "\$automount_unit"; then echo yes; else echo no; fi
    done < <(read_manifest)
}

case "\${1:---status}" in
    start) start_roots ;;
    cleanup) cleanup_roots ;;
    status) status_roots ;;
    --dry-run)
        while IFS=$'\\t' read -r entry mount_unit automount_unit; do
            [ -n "\$entry" ] || continue
            echo "WOULD START/STOP \$automount_unit and \$mount_unit for /smb/\$entry"
        done < <(read_manifest)
        ;;
    *) echo "Usage: dr-drip-search {start|cleanup|status|--dry-run}" >&2; exit 2 ;;
esac
EOF
}

render_drip_launcher_support() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    cat << EOF
DRIP_REQUIRED="$DRIP_REQUIRED"
DRIP_SEARCH_HELPER="\${DRIP_SEARCH_HELPER:-$DR_DRIP_HELPER_PATH}"
DRIP_MANIFEST="$DR_DRIP_MANIFEST"
DRIP_UNIT_DIR="$DR_DRIP_UNIT_DIR"
DRIP_SEARCH_ROOTS="$DR_DRIP_SEARCH_ROOTS"
DRIP_SEARCH_STARTED=0

drip_validate_root_entry() {
    local entry="\$1" server share extra
    case "\$entry" in
        ''|*..*) return 1 ;;
    esac
    [[ "\$entry" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    IFS=/ read -r server share extra <<< "\$entry"
    [ -n "\$server" ] && [ -n "\$share" ] && [ -z "\${extra:-}" ]
}

drip_configured_root() {
    local configured
    read -r -a configured_roots <<< "\$DRIP_SEARCH_ROOTS"
    for configured in "\${configured_roots[@]}"; do
        [ "\$configured" = "\$1" ] && return 0
    done
    return 1
}

drip_validate_root_file() {
    local path="\$1" mode owner mode_value
    [ -f "\$path" ] && [ ! -L "\$path" ] || return 1
    owner="\$(stat -c '%u' -- "\$path" 2>/dev/null || true)"
    mode="\$(stat -c '%a' -- "\$path" 2>/dev/null || true)"
    [ "\$owner" = 0 ] || return 1
    case "\$mode" in ''|*[!0-7]*) return 1 ;; esac
    mode_value=\$((8#\$mode))
    if [ "\$path" = "\$DRIP_SEARCH_HELPER" ]; then
        [ \$((mode_value & 0111)) -ne 0 ] || return 1
        [ \$((mode_value & 0022)) -eq 0 ] || return 1
    else
        [ \$((mode_value & 07177)) -eq 0 ] || return 1
    fi
}

drip_validate_manifest() {
    local entry mount_unit automount_unit extra expected_mount expected_automount server share
    local count=0
    [ -f "\$DRIP_MANIFEST" ] && [ ! -L "\$DRIP_MANIFEST" ] || return 1
    drip_validate_root_file "\$DRIP_MANIFEST" || return 1
    while IFS=\$'\t' read -r entry mount_unit automount_unit extra; do
        [ -n "\$entry" ] || continue
        [ -z "\${extra:-}" ] || return 1
        drip_validate_root_entry "\$entry" || return 1
        drip_configured_root "\$entry" || return 1
        expected_mount="\$(systemd-escape --path --suffix=mount "/smb/\$entry" 2>/dev/null)" || return 1
        expected_automount="\$(systemd-escape --path --suffix=automount "/smb/\$entry" 2>/dev/null)" || return 1
        [ "\$mount_unit" = "\$expected_mount" ] && [ "\$automount_unit" = "\$expected_automount" ] || return 1
        [ -f "\$DRIP_UNIT_DIR/\$mount_unit" ] && [ ! -L "\$DRIP_UNIT_DIR/\$mount_unit" ] || return 1
        [ -f "\$DRIP_UNIT_DIR/\$automount_unit" ] && [ ! -L "\$DRIP_UNIT_DIR/\$automount_unit" ] || return 1
        server="\${entry%%/*}"
        share="\${entry#*/}"
        grep -Fxq "What=//\$server/\$share" "\$DRIP_UNIT_DIR/\$mount_unit" || return 1
        grep -Fxq "Where=/smb/\$entry" "\$DRIP_UNIT_DIR/\$mount_unit" || return 1
        grep -Fxq 'Options=_netdev,nofail,sec=krb5,cruid=0,vers=3.0' "\$DRIP_UNIT_DIR/\$mount_unit" || return 1
        grep -Fxq "Where=/smb/\$entry" "\$DRIP_UNIT_DIR/\$automount_unit" || return 1
        systemd-analyze verify "\$DRIP_UNIT_DIR/\$mount_unit" "\$DRIP_UNIT_DIR/\$automount_unit" >/dev/null 2>&1 || return 1
        count=\$((count + 1))
    done < "\$DRIP_MANIFEST"
    [ "\$count" -gt 0 ]
}

drip_search_cleanup() {
    if [ "\$DRIP_SEARCH_STARTED" -eq 1 ] && [ -x "\$DRIP_SEARCH_HELPER" ]; then
        if ! "\$DRIP_SEARCH_HELPER" cleanup; then
            echo "WARNING: configured DRIP search cleanup was incomplete; inspect systemd state and the manifest." >&2
        fi
    fi
}
trap 'kit_status=\$?; drip_search_cleanup; exit "\$kit_status"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "\$DRIP_REQUIRED" = true ]; then
    drip_validate_root_file "\$DRIP_SEARCH_HELPER" || {
        echo "Required DRIP search helper is missing, unsafe, or not root-owned." >&2
        exit 1
    }
    drip_validate_manifest || {
        echo "Required DRIP manifest or configured units are missing or invalid." >&2
        exit 1
    }
elif [ ! -e "\$DRIP_SEARCH_HELPER" ]; then
    echo "WARNING: DRIP_REQUIRED=false; launching KIT without configured DRIP search mounts." >&2
else
    drip_validate_root_file "\$DRIP_SEARCH_HELPER" || {
        echo "DRIP helper is present but unsafe; refusing KIT-only launch." >&2
        exit 1
    }
fi

if [ -x "\$DRIP_SEARCH_HELPER" ]; then
    DRIP_SEARCH_STARTED=1
    if ! "\$DRIP_SEARCH_HELPER" start; then
        echo "Configured DRIP search automounts could not be started; KIT launch is blocked." >&2
        exit 1
    fi
    if [ "\$DRIP_REQUIRED" = true ]; then
        while IFS=\$'\t' read -r entry mount_unit automount_unit extra; do
            [ -n "\$entry" ] || continue
            systemctl is-active --quiet "\$automount_unit" || {
                echo "Required DRIP automount is not active: \$automount_unit" >&2
                exit 1
            }
        done < "\$DRIP_MANIFEST"
    fi
fi
EOF
}

platform_install_drip_search() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    platform_validate_drip_search_roots || {
        print_error "Configured Arch DRIP search roots are invalid"
        return 1
    }

    local manifest_dir transaction_dir staging_dir unit_backup_dir
    local manifest_stage helper_stage helper_path entry mount_unit automount_unit
    local old_manifest_exists=0 old_helper_exists=0 fail_stage
    local stale_mount stale_automount
    local -a old_entries=() new_entries=() new_mounts=() new_automounts=() touched_units=()
    manifest_dir="$(dirname "$DR_DRIP_MANIFEST")"
    helper_path="${DR_DRIP_HELPER_PATH:-/usr/local/sbin/dr-drip-search}"
    fail_stage="${DR_DRIP_INSTALL_FAIL_STAGE:-}"

    if [ "${DR_DRIP_SKIP_MOUNT_ROOT:-false}" != true ]; then
        mkdir -p /smb || return 1
    fi
    mkdir -p "$manifest_dir" "$DR_DRIP_UNIT_DIR" || return 1
    transaction_dir="$(mktemp -d "$manifest_dir/.drip-install.XXXXXX")" || return 1
    staging_dir="$transaction_dir/staged"
    unit_backup_dir="$transaction_dir/unit-backups"
    mkdir -p "$staging_dir" "$unit_backup_dir" || {
        rm -rf -- "$transaction_dir"
        return 1
    }
    manifest_stage="$staging_dir/drip-units.manifest"
    helper_stage="$staging_dir/dr-drip-search"
    : > "$manifest_stage"
    chmod 600 "$manifest_stage"
    chown root:root "$manifest_stage" 2>/dev/null || true

    drip_install_add_unit() {
        local candidate="$1" existing
        for existing in "${touched_units[@]}"; do
            [ "$existing" = "$candidate" ] && return 0
        done
        touched_units+=("$candidate")
    }

    drip_install_new_entry() {
        local candidate="$1" existing
        for existing in "${new_entries[@]}"; do
            [ "$existing" = "$candidate" ] && return 0
        done
        return 1
    }

    drip_install_rollback() {
        local unit target
        for unit in "${touched_units[@]}"; do
            target="$DR_DRIP_UNIT_DIR/$unit"
            if [ -e "$unit_backup_dir/$unit" ] || [ -L "$unit_backup_dir/$unit" ]; then
                rm -f -- "$target"
                cp -a -- "$unit_backup_dir/$unit" "$target"
            else
                rm -f -- "$target"
            fi
        done
        if [ "$old_manifest_exists" -eq 1 ]; then
            rm -f -- "$DR_DRIP_MANIFEST"
            cp -a -- "$transaction_dir/previous.manifest" "$DR_DRIP_MANIFEST"
        else
            rm -f -- "$DR_DRIP_MANIFEST"
        fi
        if [ "$old_helper_exists" -eq 1 ]; then
            rm -f -- "$helper_path"
            cp -a -- "$transaction_dir/previous.helper" "$helper_path"
        else
            rm -f -- "$helper_path"
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -rf -- "$transaction_dir"
    }

    if [ -e "$DR_DRIP_MANIFEST" ] || [ -L "$DR_DRIP_MANIFEST" ]; then
        old_manifest_exists=1
        cp -a -- "$DR_DRIP_MANIFEST" "$transaction_dir/previous.manifest" || {
            rm -rf -- "$transaction_dir"
            return 1
        }
        while IFS=$'\t' read -r entry mount_unit automount_unit extra; do
            [ -n "$entry" ] || continue
            [ -z "${extra:-}" ] || {
                drip_install_rollback
                return 1
            }
            [ "$(drip_mount_unit_name "$entry")" = "$mount_unit" ] || {
                drip_install_rollback
                return 1
            }
            [ "$(drip_automount_unit_name "$entry")" = "$automount_unit" ] || {
                drip_install_rollback
                return 1
            }
            old_entries+=("$entry")
        done < "$DR_DRIP_MANIFEST"
    fi

    if [ -e "$helper_path" ] || [ -L "$helper_path" ]; then
        old_helper_exists=1
        cp -a -- "$helper_path" "$transaction_dir/previous.helper" || {
            drip_install_rollback
            return 1
        }
    fi

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        mount_unit="$(drip_mount_unit_name "$entry")" || {
            drip_install_rollback
            return 1
        }
        automount_unit="$(drip_automount_unit_name "$entry")" || {
            drip_install_rollback
            return 1
        }
        new_entries+=("$entry")
        new_mounts+=("$mount_unit")
        new_automounts+=("$automount_unit")
        drip_install_add_unit "$mount_unit"
        drip_install_add_unit "$automount_unit"
    done < <(platform_drip_search_entries)
    for entry in "${old_entries[@]}"; do
        drip_install_add_unit "$(drip_mount_unit_name "$entry")"
        drip_install_add_unit "$(drip_automount_unit_name "$entry")"
    done

    for unit in "${touched_units[@]}"; do
        if [ -e "$DR_DRIP_UNIT_DIR/$unit" ] || [ -L "$DR_DRIP_UNIT_DIR/$unit" ]; then
            cp -a -- "$DR_DRIP_UNIT_DIR/$unit" "$unit_backup_dir/$unit" || {
                drip_install_rollback
                return 1
            }
        fi
    done

    for entry in "${new_entries[@]}"; do
        mount_unit="$(drip_mount_unit_name "$entry")"
        automount_unit="$(drip_automount_unit_name "$entry")"
        if [ "$fail_stage" = render ]; then
            print_error "Injected DRIP installation failure at render"
            drip_install_rollback
            return 1
        fi
        render_arch_drip_mount_unit "$entry" > "$staging_dir/$mount_unit" || {
            drip_install_rollback
            return 1
        }
        render_arch_drip_automount_unit "$entry" > "$staging_dir/$automount_unit" || {
            drip_install_rollback
            return 1
        }
        chmod 644 "$staging_dir/$mount_unit" "$staging_dir/$automount_unit"
        chown root:root "$staging_dir/$mount_unit" "$staging_dir/$automount_unit" 2>/dev/null || true
        if [ "$fail_stage" = verify ] || ! systemd-analyze verify "$staging_dir/$mount_unit" "$staging_dir/$automount_unit"; then
            print_error "Configured DRIP systemd unit verification failed"
            drip_install_rollback
            return 1
        fi
        printf '%s\t%s\t%s\n' "$entry" "$mount_unit" "$automount_unit" >> "$manifest_stage"
    done

    render_drip_search_mount_helper > "$helper_stage" || {
        drip_install_rollback
        return 1
    }
    chmod 755 "$helper_stage"
    chown root:root "$helper_stage" 2>/dev/null || true

    for entry in "${old_entries[@]}"; do
        drip_install_new_entry "$entry" && continue
        stale_mount="$(drip_mount_unit_name "$entry")"
        stale_automount="$(drip_automount_unit_name "$entry")"
        if systemctl is-active --quiet "$stale_mount" 2>/dev/null || \
           { command -v mountpoint >/dev/null 2>&1 && mountpoint -q "/smb/$entry"; }; then
            print_error "Stale DRIP mount is active or busy; preserving it: /smb/$entry"
            drip_install_rollback
            return 1
        fi
        if systemctl is-active --quiet "$stale_automount" 2>/dev/null; then
            print_error "Stale DRIP automount is active; preserving it: $stale_automount"
            drip_install_rollback
            return 1
        fi
    done

    if [ "$fail_stage" = unit-install ]; then
        print_error "Injected DRIP installation failure at unit-install"
        drip_install_rollback
        return 1
    fi
    for mount_unit in "${new_mounts[@]}"; do
        backup_config_file "$DR_DRIP_UNIT_DIR/$mount_unit"
        mv -f -- "$staging_dir/$mount_unit" "$DR_DRIP_UNIT_DIR/$mount_unit" || {
            drip_install_rollback
            return 1
        }
    done
    for automount_unit in "${new_automounts[@]}"; do
        backup_config_file "$DR_DRIP_UNIT_DIR/$automount_unit"
        mv -f -- "$staging_dir/$automount_unit" "$DR_DRIP_UNIT_DIR/$automount_unit" || {
            drip_install_rollback
            return 1
        }
    done
    for entry in "${old_entries[@]}"; do
        drip_install_new_entry "$entry" && continue
        rm -f -- "$DR_DRIP_UNIT_DIR/$(drip_mount_unit_name "$entry")" \
            "$DR_DRIP_UNIT_DIR/$(drip_automount_unit_name "$entry")" || {
            drip_install_rollback
            return 1
        }
    done

    backup_config_file "$helper_path"
    mv -f -- "$helper_stage" "$helper_path" || {
        drip_install_rollback
        return 1
    }
    if [ "$fail_stage" = manifest ]; then
        print_error "Injected DRIP installation failure at manifest"
        drip_install_rollback
        return 1
    fi
    mv -f -- "$manifest_stage" "$DR_DRIP_MANIFEST" || {
        drip_install_rollback
        return 1
    }
    chmod 600 "$DR_DRIP_MANIFEST"
    chown root:root "$DR_DRIP_MANIFEST" 2>/dev/null || true
    if [ "$fail_stage" = daemon-reload ] || ! systemctl daemon-reload; then
        print_error "DRIP systemd daemon reload failed"
        drip_install_rollback
        return 1
    fi
    rm -rf -- "$transaction_dir"
    print_info "Installed configured Arch DRIP search units without enabling them at boot"
}

platform_verify_drip_automount_unit_file_state() {
    local automount_unit="${1:-}" unit_file_state
    [ -n "$automount_unit" ] || return 1
    if ! unit_file_state="$(systemctl show "$automount_unit" -p UnitFileState --value 2>/dev/null)"; then
        print_error "Could not determine UnitFileState for DRIP search automount $automount_unit"
        return 1
    fi

    # Managed Arch DRIP automounts intentionally omit [Install], so systemd
    # reports `static` (and `is-enabled` exits 0). Static is exactly what lets
    # the KIT lifecycle start/stop the units explicitly without a boot target.
    case "$unit_file_state" in
        static) return 0 ;;
        enabled|enabled-runtime)
            print_error "DRIP search automount must not be enabled globally: $automount_unit (UnitFileState=$unit_file_state)"
            return 1
            ;;
        masked|masked-runtime)
            print_error "DRIP search automount is masked and unusable: $automount_unit (UnitFileState=$unit_file_state)"
            return 1
            ;;
        *)
            print_error "DRIP search automount has unexpected UnitFileState '${unit_file_state:-<empty>}': $automount_unit"
            return 1
            ;;
    esac
}

platform_verify_drip_search() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    [ -r "$DR_DRIP_MANIFEST" ] && [ ! -L "$DR_DRIP_MANIFEST" ] || return 1
    local entry mount_unit automount_unit extra count=0 server share
    while IFS=$'\t' read -r entry mount_unit automount_unit extra; do
        [ -n "$entry" ] || continue
        [ -z "${extra:-}" ] || return 1
        validate_drip_search_root_entry "$entry" || return 1
        [ "$(drip_mount_unit_name "$entry")" = "$mount_unit" ] || return 1
        [ "$(drip_automount_unit_name "$entry")" = "$automount_unit" ] || return 1
        [ -f "$DR_DRIP_UNIT_DIR/$mount_unit" ] && [ ! -L "$DR_DRIP_UNIT_DIR/$mount_unit" ] || return 1
        [ -f "$DR_DRIP_UNIT_DIR/$automount_unit" ] && [ ! -L "$DR_DRIP_UNIT_DIR/$automount_unit" ] || return 1
        server="${entry%%/*}"
        share="${entry#*/}"
        grep -Fxq "What=//$server/$share" "$DR_DRIP_UNIT_DIR/$mount_unit" || return 1
        grep -Fxq "Where=/smb/$entry" "$DR_DRIP_UNIT_DIR/$mount_unit" || return 1
        grep -Fxq 'Options=_netdev,nofail,sec=krb5,cruid=0,vers=3.0' "$DR_DRIP_UNIT_DIR/$mount_unit" || return 1
        grep -Fxq "Where=/smb/$entry" "$DR_DRIP_UNIT_DIR/$automount_unit" || return 1
        systemd-analyze verify "$DR_DRIP_UNIT_DIR/$mount_unit" "$DR_DRIP_UNIT_DIR/$automount_unit" >/dev/null 2>&1 || return 1
        platform_verify_drip_automount_unit_file_state "$automount_unit" || return 1
        count=$((count + 1))
    done < "$DR_DRIP_MANIFEST"
    [ "$count" -gt 0 ]
}

platform_remove_drip_search() {
    [ "$PLATFORM_FAMILY" = "arch" ] || return 0
    local entry mount_unit automount_unit
    if [ -r "$DR_DRIP_MANIFEST" ]; then
        while IFS=$'\t' read -r entry mount_unit automount_unit; do
            [ -n "$entry" ] || continue
            systemctl stop "$automount_unit" >/dev/null 2>&1 || true
            systemctl stop "$mount_unit" >/dev/null 2>&1 || true
            rm -f -- "$DR_DRIP_UNIT_DIR/$mount_unit" "$DR_DRIP_UNIT_DIR/$automount_unit"
        done < "$DR_DRIP_MANIFEST"
    fi
    rm -f -- "$DR_DRIP_MANIFEST" /usr/local/sbin/dr-drip-search
    systemctl daemon-reload
}

render_arch_tools_rebind_helper() {
    local mount_unit automount_unit server
    mount_unit="$(tools_mount_unit_name)" || return 1
    automount_unit="$(tools_automount_unit_name)" || return 1
    server="$TOOLS_SERVER"
    cat << EOF
#!/bin/bash
set -euo pipefail

MOUNT_UNIT="$mount_unit"
AUTOMOUNT_UNIT="$automount_unit"
UNIT_DIR="\${DR_REBIND_UNIT_DIR:-/etc/systemd/system}"
UNIT_PATH="\$UNIT_DIR/\$MOUNT_UNIT"
STATE_FILE="\${DR_REBIND_STATE_FILE:-$STATE_FILE}"
LOCK_DIR="\${DR_REBIND_LOCK_DIR:-/run/dr-tools-rebind.lock}"
STAGE_ROOT="\${DR_REBIND_STAGE_ROOT:-\$UNIT_DIR/.dr-tools-rebind}"
FAIL_STAGE="\${DR_REBIND_FAIL_STAGE:-}"
TRANSACTION_ACTIVE=0
COMMITTED=0
ORIGINAL_UNIT=""
ORIGINAL_STATE=""
ORIGINAL_STATE_EXISTS=0
ORIGINAL_MOUNT_ACTIVE="inactive"
ORIGINAL_MOUNT_ENABLED="disabled"
ORIGINAL_AUTOMOUNT_ACTIVE="inactive"
ORIGINAL_AUTOMOUNT_ENABLED="disabled"
STAGED_UNIT=""

failpoint() {
    if [ "\$FAIL_STAGE" = "\$1" ]; then
        echo "Injected rebind failure at \$1" >&2
        return 1
    fi
}

unit_active_state() {
    systemctl is-active "\$1" 2>/dev/null || echo inactive
}

unit_enabled_state() {
    systemctl is-enabled "\$1" 2>/dev/null || echo disabled
}

restore_enabled_state() {
    local unit="\$1" state="\$2"
    case "\$state" in
        enabled|enabled-runtime|linked|linked-runtime) systemctl enable "\$unit" >/dev/null 2>&1 || true ;;
        masked) systemctl mask "\$unit" >/dev/null 2>&1 || true ;;
        *) systemctl disable "\$unit" >/dev/null 2>&1 || true ;;
    esac
}

restore_active_state() {
    local unit="\$1" state="\$2"
    if [ "\$state" = active ]; then
        systemctl start "\$unit" >/dev/null 2>&1 || true
    else
        systemctl stop "\$unit" >/dev/null 2>&1 || true
    fi
}

restore_original_state() {
    local restored_state="\$STATE_FILE.restore.\$\$"
    if [ -n "\$ORIGINAL_UNIT" ] && [ -f "\$ORIGINAL_UNIT" ]; then
        cp -- "\$ORIGINAL_UNIT" "\$UNIT_PATH"
        chmod 644 "\$UNIT_PATH"
    fi
    if [ "\$ORIGINAL_STATE_EXISTS" -eq 1 ] && [ -f "\$ORIGINAL_STATE" ]; then
        mkdir -p "\$(dirname -- "\$STATE_FILE")"
        cp -- "\$ORIGINAL_STATE" "\$restored_state"
        chmod 600 "\$restored_state"
        chown root:root "\$restored_state" 2>/dev/null || true
        mv -f -- "\$restored_state" "\$STATE_FILE"
    elif [ "\$ORIGINAL_STATE_EXISTS" -eq 0 ]; then
        rm -f -- "\$STATE_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    restore_enabled_state "\$MOUNT_UNIT" "\$ORIGINAL_MOUNT_ENABLED"
    restore_enabled_state "\$AUTOMOUNT_UNIT" "\$ORIGINAL_AUTOMOUNT_ENABLED"
    restore_active_state "\$MOUNT_UNIT" "\$ORIGINAL_MOUNT_ACTIVE"
    restore_active_state "\$AUTOMOUNT_UNIT" "\$ORIGINAL_AUTOMOUNT_ACTIVE"
}

finish() {
    local rc=\$?
    if [ "\$TRANSACTION_ACTIVE" -eq 1 ] && [ "\$COMMITTED" -eq 0 ]; then
        echo "Rebind failed; restoring the original unit, UID state, and service state." >&2
        restore_original_state || true
    fi
    rm -rf -- "\$STAGE_ROOT" "\$ORIGINAL_UNIT" "\$ORIGINAL_STATE"
    rmdir "\$LOCK_DIR" 2>/dev/null || true
    exit "\$rc"
}

require_root() {
    if [ "\$(id -u)" -ne 0 ]; then
        echo "Tool Server credential-owner changes require a local administrator." >&2
        echo "Run: sudo /usr/local/sbin/dr-tools-rebind \${1:-<domain-user-uid>}" >&2
        exit 1
    fi
}

read_persisted_cruid() {
    [ -r "\$STATE_FILE" ] || return 0
    awk -F= '/^DR_TOOLS_MOUNT_CRUID=/ {gsub(/^[" ]|[" ]$/, "", \$2); print \$2; exit}' "\$STATE_FILE"
}

atomic_update_cruid() {
    local tmp="\$STATE_FILE.tmp.\$\$"
    mkdir -p "\$(dirname -- "\$STATE_FILE")"
    if [ -f "\$STATE_FILE" ]; then
        awk -v value="\$NEW_CRUID" '
            BEGIN { updated = 0 }
            /^DR_TOOLS_MOUNT_CRUID=/ {
                if (!updated) { print "DR_TOOLS_MOUNT_CRUID=\"" value "\""; updated = 1 }
                next
            }
            { print }
            END { if (!updated) print "DR_TOOLS_MOUNT_CRUID=\"" value "\"" }
        ' "\$STATE_FILE" > "\$tmp"
    else
        printf 'DR_TOOLS_MOUNT_CRUID="%s"\n' "\$NEW_CRUID" > "\$tmp"
    fi
    chmod 600 "\$tmp"
    chown root:root "\$tmp" 2>/dev/null || true
    mv -f -- "\$tmp" "\$STATE_FILE"
    [ "\$(stat -c '%u:%a' -- "\$STATE_FILE")" = "0:600" ]
}

verify_unit_cruid() {
    local unit_file="\$1"
    local expected="\${2:-}"
    local line options token value
    local -a values=()

    [ -r "\$unit_file" ] || return 1
    while IFS= read -r line; do
        case "\$line" in
            Options=*)
                options="\${line#Options=}"
                IFS=, read -r -a tokens <<< "\$options"
                for token in "\${tokens[@]}"; do
                    case "\$token" in
                        cruid=*) values+=("\${token#cruid=}") ;;
                    esac
                done
                ;;
        esac
    done < "\$unit_file"

    [ "\${#values[@]}" -eq 1 ] || return 1
    value="\${values[0]}"
    [[ "\$value" =~ ^[0-9]+$ ]] || return 1
    if [ -n "\$expected" ]; then
        [[ "\$expected" =~ ^[0-9]+$ ]] || return 1
        [ "\$((10#\$value))" -eq "\$((10#\$expected))" ] || return 1
    fi
    printf '%s\n' "\$((10#\$value))"
}

validate_target_uid() {
    case "\$NEW_CRUID" in
        ''|0|*[!0-9]*) echo "Usage: dr-tools-rebind [--dry-run|--status] <non-root-domain-user-uid>" >&2; return 1 ;;
    esac
    local passwd_line resolved_username resolved_uid
    local -a passwd_records passwd_fields
    mapfile -t passwd_records < <(getent passwd "\$NEW_CRUID" 2>/dev/null || true)
    [ "\${#passwd_records[@]}" -eq 1 ] || {
        echo "UID \$NEW_CRUID did not resolve to exactly one passwd record." >&2
        return 1
    }
    passwd_line="\${passwd_records[0]}"
    IFS=: read -r -a passwd_fields <<< "\$passwd_line"
    [ "\${#passwd_fields[@]}" -eq 7 ] || {
        echo "UID \$NEW_CRUID returned a malformed passwd record." >&2
        return 1
    }
    resolved_username="\${passwd_fields[0]}"
    resolved_uid="\${passwd_fields[2]}"
    [ -n "\$resolved_username" ] && [ -n "\$resolved_uid" ] || {
        echo "UID \$NEW_CRUID returned an incomplete passwd record." >&2
        return 1
    }
    case "\$resolved_uid" in
        ''|*[!0-9]*) echo "UID \$NEW_CRUID returned a nonnumeric passwd UID." >&2; return 1 ;;
    esac
    [ "\$resolved_uid" = "\$NEW_CRUID" ] || {
        echo "NSS passwd UID \$resolved_uid does not match requested UID \$NEW_CRUID." >&2
        return 1
    }
    [ "\$(id -u "\$resolved_username" 2>/dev/null || true)" = "\$NEW_CRUID" ] || {
        echo "NSS could not confirm username \$resolved_username as UID \$NEW_CRUID." >&2
        return 1
    }
}

refuse_if_busy() {
    local pattern
    for pattern in \
        '(^|/)KIT([[:space:]]|$)' \
        '(^|/)KIT\\.sh([[:space:]]|$)' \
        '(^|/)dr-launch-kit([[:space:]]|$)' \
        '(^|/)dr-post-mount-provision([[:space:]]|$)'; do
        if pgrep -f "\$pattern" >/dev/null 2>&1; then
            echo "A protected KIT/provisioning process is active; rebind refused." >&2
            return 1
        fi
    done
    if mountpoint -q /mnt/p 2>/dev/null; then
        echo "/mnt/p is mounted; rebind refused because KIT activation owns that lifecycle." >&2
        return 1
    fi
}

show_status() {
    local unit_cruid persisted_cruid
    require_root
    printf 'mount_unit=%s active=%s enabled=%s\n' "\$MOUNT_UNIT" "\$(unit_active_state "\$MOUNT_UNIT")" "\$(unit_enabled_state "\$MOUNT_UNIT")"
    printf 'automount_unit=%s active=%s enabled=%s\n' "\$AUTOMOUNT_UNIT" "\$(unit_active_state "\$AUTOMOUNT_UNIT")" "\$(unit_enabled_state "\$AUTOMOUNT_UNIT")"
    persisted_cruid="\$(read_persisted_cruid)"
    unit_cruid="\$(verify_unit_cruid "\$UNIT_PATH" "\$persisted_cruid")" || {
        echo "unit_cruid=invalid" >&2
        return 1
    }
    printf 'unit_cruid=%s\n' "\$unit_cruid"
    printf 'persisted_cruid=%s\n' "\$(read_persisted_cruid)"
}

require_root "\${1:-}"
case "\${1:-}" in
    --status)
        show_status
        exit 0
        ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) DRY_RUN=0 ;;
esac

NEW_CRUID="\${1:-}"
validate_target_uid || exit 1
[ -f "\$UNIT_PATH" ] || { echo "Tool Server mount unit not found: \$UNIT_PATH" >&2; exit 1; }
command -v systemd-analyze >/dev/null 2>&1 || { echo "systemd-analyze is required." >&2; exit 1; }

if [ "\$DRY_RUN" -eq 1 ]; then
    mkdir -p "\$STAGE_ROOT"
    STAGED_UNIT="\$STAGE_ROOT/\$MOUNT_UNIT"
    cat > "\$STAGED_UNIT" << UNIT
[Unit]
Description=DR Tool Server CIFS mount
Wants=network-online.target
After=network-online.target

[Mount]
What=//$server/Tools
Where=/mnt/x
Type=cifs
Options=_netdev,nofail,sec=krb5,cruid=\$NEW_CRUID,vers=3.0
TimeoutSec=30s
UNIT
    systemd-analyze verify "\$STAGED_UNIT"
    verify_unit_cruid "\$STAGED_UNIT" "\$NEW_CRUID" >/dev/null
    echo "WOULD CHANGE \$UNIT_PATH cruid=\$NEW_CRUID"
    exit 0
fi

mkdir "\$LOCK_DIR" 2>/dev/null || { echo "Another Tool Server rebind is active." >&2; exit 1; }
TRANSACTION_ACTIVE=1
ORIGINAL_UNIT="\$(mktemp)"
cp -- "\$UNIT_PATH" "\$ORIGINAL_UNIT"
if [ -f "\$STATE_FILE" ]; then
    ORIGINAL_STATE_EXISTS=1
    ORIGINAL_STATE="\$(mktemp)"
    cp -- "\$STATE_FILE" "\$ORIGINAL_STATE"
fi
ORIGINAL_MOUNT_ACTIVE="\$(unit_active_state "\$MOUNT_UNIT")"
ORIGINAL_MOUNT_ENABLED="\$(unit_enabled_state "\$MOUNT_UNIT")"
ORIGINAL_AUTOMOUNT_ACTIVE="\$(unit_active_state "\$AUTOMOUNT_UNIT")"
ORIGINAL_AUTOMOUNT_ENABLED="\$(unit_enabled_state "\$AUTOMOUNT_UNIT")"
trap finish EXIT HUP INT TERM

refuse_if_busy
failpoint automount-stop
systemctl stop "\$AUTOMOUNT_UNIT"
failpoint mount-stop
systemctl stop "\$MOUNT_UNIT"

mkdir -p "\$STAGE_ROOT"
STAGED_UNIT="\$STAGE_ROOT/\$MOUNT_UNIT"
rm -f -- "\$STAGED_UNIT"
failpoint render
cat > "\$STAGED_UNIT" << UNIT
[Unit]
Description=DR Tool Server CIFS mount
Wants=network-online.target
After=network-online.target

[Mount]
What=//$server/Tools
Where=/mnt/x
Type=cifs
Options=_netdev,nofail,sec=krb5,cruid=\$NEW_CRUID,vers=3.0
TimeoutSec=30s
UNIT
chmod 644 "\$STAGED_UNIT"
chown root:root "\$STAGED_UNIT" 2>/dev/null || true
failpoint verify
systemd-analyze verify "\$STAGED_UNIT"
verify_unit_cruid "\$STAGED_UNIT" "\$NEW_CRUID" >/dev/null

failpoint replace
mv -f -- "\$STAGED_UNIT" "\$UNIT_PATH"
failpoint daemon-reload
systemctl daemon-reload

restore_enabled_state "\$MOUNT_UNIT" "\$ORIGINAL_MOUNT_ENABLED"
failpoint automount-enable
restore_enabled_state "\$AUTOMOUNT_UNIT" "\$ORIGINAL_AUTOMOUNT_ENABLED"
failpoint automount-start
restore_active_state "\$MOUNT_UNIT" "\$ORIGINAL_MOUNT_ACTIVE"
restore_active_state "\$AUTOMOUNT_UNIT" "\$ORIGINAL_AUTOMOUNT_ACTIVE"

verify_unit_cruid "\$UNIT_PATH" "\$NEW_CRUID" >/dev/null
failpoint state-update
atomic_update_cruid
COMMITTED=1
echo "Tool Server automount rebound transactionally to Kerberos credential owner UID \$NEW_CRUID."
EOF
}

platform_verify_tools_mount() {
    local mount_unit automount_unit
    mount_unit="$(tools_mount_unit_name)" || return 1
    automount_unit="$(tools_automount_unit_name)" || return 1
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        [ -f "/etc/systemd/system/$mount_unit" ] || return 1
        [ -f "/etc/systemd/system/$automount_unit" ] || return 1
        systemd-analyze verify "/etc/systemd/system/$mount_unit" "/etc/systemd/system/$automount_unit" >/dev/null 2>&1
        systemctl is-enabled --quiet "$automount_unit" 2>/dev/null || return 1
        platform_tools_mount_is_authoritative
    else
        command -v automount >/dev/null 2>&1 && systemctl is-active --quiet autofs
    fi
}

platform_tools_mount_is_authoritative() {
    local expected="//$TOOLS_SERVER/Tools"
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt --noheadings --raw --target /mnt/x --output FSTYPE,SOURCE 2>/dev/null \
        | awk -v expected="$expected" '$1 == "cifs" && $2 == expected { found=1 } END { exit(found ? 0 : 1) }'
}

platform_start_tools_mount() {
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        local automount_unit
        automount_unit="$(tools_automount_unit_name)" || return 1
        systemctl start "$automount_unit"
        return 0
    fi
    systemctl start autofs
}

platform_stop_tools_mount() {
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        local mount_unit automount_unit
        mount_unit="$(tools_mount_unit_name)" || return 1
        automount_unit="$(tools_automount_unit_name)" || return 1
        systemctl stop "$mount_unit" "$automount_unit"
        return 0
    fi
    systemctl stop autofs
}

platform_remove_tools_mount() {
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        local mount_unit automount_unit
        mount_unit="$(tools_mount_unit_name)" || return 1
        automount_unit="$(tools_automount_unit_name)" || return 1
        systemctl disable --now "$automount_unit" >/dev/null 2>&1 || true
        systemctl stop "$mount_unit" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$mount_unit" "/etc/systemd/system/$automount_unit" \
            /usr/local/sbin/dr-tools-rebind
        systemctl daemon-reload
        print_info "Removed Arch Tool Server systemd mount, automount, and rebind helper"
        return 0
    fi
    systemctl disable --now autofs
}

platform_validate_selected_domain_user() {
    [ "$PLATFORM_FAMILY" = arch ] || return 0
    local uid direct_sss_uid
    if [ -z "${DOMAIN_SUDO_USER:-}" ]; then
        print_error "No Arch domain user was selected for the Tool Server mount"
        print_error "Post-mount provisioning is blocked until a domain identity is selected and resolved"
        return 1
    fi
    if uid="$(resolve_domain_user_uid "$DOMAIN_SUDO_USER")"; then
        print_info "Selected domain user $DOMAIN_SUDO_USER resolves through NSS/SSSD as UID $uid"
        return 0
    fi
    print_error "NSS/SSSD identity resolution failed for selected domain user $DOMAIN_SUDO_USER"
    print_error "Normal getent passwd, id, home-directory, and login-shell validation must all succeed; no local UID will be substituted"
    diagnose_selected_domain_user_login_identity "$DOMAIN_SUDO_USER" || true
    direct_sss_uid="$(diagnose_sss_direct_user_uid "$DOMAIN_SUDO_USER" || true)"
    if [ -n "$direct_sss_uid" ]; then
        print_error "SSSD's direct NSS service resolves $DOMAIN_SUDO_USER as UID $direct_sss_uid, but the normal libc/NSS path does not"
        print_error "Check that the passwd, group, and shadow databases in /etc/nsswitch.conf include the standalone sss service"
    else
        print_error "SSSD may still be failing domain/site discovery; the workstation remains at a resumable post-join stage"
    fi
    if command -v sssctl >/dev/null 2>&1; then
        sssctl domain-status "$DOMAIN" 2>&1 | sed 's/^/  /' || true
    fi
    return 1
}

platform_install_tools_mount() {
    if [ "$PLATFORM_FAMILY" != "arch" ]; then
        return 0
    fi

    platform_cifs_kernel_is_ready || {
        print_error "Cannot configure the Arch Tool Server mount because CIFS is unavailable for the running kernel"
        print_error "Run --preflight and reboot into the installed kernel when its module tree is required"
        return 1
    }

    local mount_unit automount_unit cruid
    cruid="$(tools_mount_cruid)" || {
        print_error "Cannot configure Arch Tool Server mount without a verified logged-in domain-user UID"
        print_error "Set DR_TOOLS_MOUNT_CRUID to that UID or select DOMAIN_SUDO_USER before the modifying checkpoint"
        return 1
    }
    DR_TOOLS_MOUNT_CRUID="$cruid"
    mount_unit="$(tools_mount_unit_name)" || {
        print_error "systemd-escape is required to name the Tool Server mount unit"
        return 1
    }
    automount_unit="$(tools_automount_unit_name)" || return 1
    mkdir -p /mnt/x
    backup_config_file "/etc/systemd/system/$mount_unit"
    backup_config_file "/etc/systemd/system/$automount_unit"
    backup_config_file "/usr/local/sbin/dr-tools-rebind"
    render_arch_tools_mount_unit "/mnt/x" "$TOOLS_SERVER" "$cruid" > "/etc/systemd/system/$mount_unit"
    render_arch_tools_automount_unit "/mnt/x" > "/etc/systemd/system/$automount_unit"
    render_arch_tools_rebind_helper > /usr/local/sbin/dr-tools-rebind
    chmod 644 "/etc/systemd/system/$mount_unit" "/etc/systemd/system/$automount_unit"
    chmod 755 /usr/local/sbin/dr-tools-rebind
    chown root:root /usr/local/sbin/dr-tools-rebind
    systemd-analyze verify "/etc/systemd/system/$mount_unit" "/etc/systemd/system/$automount_unit"
    systemctl daemon-reload
    systemctl enable "$automount_unit" >/dev/null
    if [ -f "$STATE_FILE" ]; then
        save_state "${STAGE:-POSTJOIN_AWAITING_LIVE_VALIDATION}"
    fi
    print_info "Installed on-demand systemd CIFS units: $mount_unit, $automount_unit"
}

render_arch_tools_mount_helper() {
    local configured_cruid="${1:-${DR_TOOLS_MOUNT_CRUID:-}}"
    local mount_unit automount_unit server
    mount_unit="$(tools_mount_unit_name)" || return 1
    automount_unit="$(tools_automount_unit_name)" || return 1
    server="$TOOLS_SERVER"
    case "$configured_cruid" in
        ''|*[!0-9]*)
            print_error "Arch Tool Server helper requires a configured domain-user UID as cruid" >&2
            return 1
            ;;
    esac
    cat << EOF
#!/bin/bash
set -euo pipefail

MOUNT_POINT="\${DR_TOOLS_MOUNT_POINT:-/mnt/x}"
TOOLS_SOURCE="//$server/Tools"
MOUNT_UNIT="$mount_unit"
AUTOMOUNT_UNIT="$automount_unit"
CONFIGURED_CRUID="$configured_cruid"

verify_tools_mount() {
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt --noheadings --raw --target "\$MOUNT_POINT" --output FSTYPE,SOURCE 2>/dev/null \
        | awk -v expected="\$TOOLS_SOURCE" '\$1 == "cifs" && \$2 == expected { found=1 } END { exit(found ? 0 : 1) }'
}

if [ "\${1:-}" = "--sudo-self-test" ]; then
    exit 0
fi

if [ "\${1:-}" = "--access-self-test" ]; then
    [ "\$(id -u)" -eq 0 ] || { echo "--access-self-test must run as root" >&2; exit 1; }
    verify_tools_mount || { echo "Tool Server is not an authoritative CIFS mount at \$MOUNT_POINT" >&2; exit 1; }
    timeout 30s ls -la "\$MOUNT_POINT" >/dev/null
    exit 0
fi

CRUID="\$CONFIGURED_CRUID"
if [ "\${1:-}" = "--cruid" ]; then
    CRUID="\${2:-}"
fi
case "\$CRUID" in
    ''|*[!0-9]*) echo "Invalid Kerberos credential-cache UID" >&2; exit 1 ;;
esac
CURRENT_CONFIGURED_CRUID="\$(sed -n 's/.*cruid=\([0-9][0-9]*\).*/\1/p' "/etc/systemd/system/\$MOUNT_UNIT" | head -n 1)"
CURRENT_CONFIGURED_CRUID="\${CURRENT_CONFIGURED_CRUID:-\$CONFIGURED_CRUID}"
if [ "\$CRUID" != "\$CURRENT_CONFIGURED_CRUID" ]; then
    echo "This mount unit is bound to domain-user UID \$CURRENT_CONFIGURED_CRUID; refusing a different credential owner" >&2
    echo "A local administrator must explicitly rebind it: sudo /usr/local/sbin/dr-tools-rebind \$CRUID" >&2
    exit 1
fi

if [ "\$(id -u)" -ne 0 ]; then
    if ! sudo -n /usr/local/bin/mount-kit-tools --sudo-self-test >/dev/null 2>&1; then
        CURRENT_USER="\$(id -un)"
        echo "This domain account does not have permission to mount the Tool Server." >&2
        echo "Run: su - $DR_LOCAL_ADMIN_USER; sudo dr-workstation add-user \$CURRENT_USER; exit" >&2
        exit 1
    fi
    USER_UID="\$(id -u)"
    sudo -n /usr/local/bin/mount-kit-tools --cruid "\$USER_UID"
    if ! verify_tools_mount || ! timeout 30s ls -la "\$MOUNT_POINT" >/dev/null 2>&1; then
        echo "Tool Server access failed. Ensure the logged-in user has a valid Kerberos ticket." >&2
        exit 1
    fi
    verify_tools_mount
    exit 0
fi

mkdir -p "\$MOUNT_POINT"
if ! KRB5CCNAME="FILE:/tmp/krb5cc_\$CURRENT_CONFIGURED_CRUID" klist -s 2>/dev/null && ! klist -s 2>/dev/null; then
    echo "No valid Kerberos ticket found for configured domain-user UID \$CRUID" >&2
    exit 1
fi
systemctl start "\$AUTOMOUNT_UNIT"
if verify_tools_mount; then
    exit 0
fi

if ! timeout 30s ls -la "\$MOUNT_POINT" >/dev/null 2>&1 || ! verify_tools_mount; then
    echo "Tool Server access failed. Ensure the logged-in user has a valid Kerberos ticket." >&2
    exit 1
fi
verify_tools_mount
EOF
}

render_kit_root_access_test_plan() {
    local domain_user="${1:-DOMAIN_USER}"
    cat << EOF
KIT Kerberos ownership and root-cache lifecycle test plan (staged; not executed by preflight):
  1. Before launch, as the domain user: printenv KRB5CCNAME; klist -s -c "\$KRB5CCNAME"; ls -la /mnt/x
  2. Across sudo: sudo -n env | grep '^KRB5CCNAME=FILE:'; confirm the exact FILE cache path is preserved, with SUDO_USER and nonzero SUDO_UID
  3. Root KIT process: sudo -n /usr/local/sbin/dr-launch-kit --access-self-test; capture only UID/SUDO_UID/KRB5CCNAME metadata in a harmless fixture and confirm UID 0 plus the invoking-user cache
  4. KIT.sh lifecycle: launch the approved KIT test mode; confirm KIT.sh creates /tmp/krb5cc_0 as root:root mode 0600, with the invoking user's TGT principal
  5. DRIP ticket lifecycle: search /smb/<server>/Images and confirm cifs/<server>@DR.KODR.LOCAL is added to /tmp/krb5cc_0; activate and verify /mnt/p uses sec=krb5,cruid=0
  6. Bounded root checks: sudo -n sh -c 'ls -la /mnt/x; bash -n /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/KIT.sh'; sudo -n /usr/local/sbin/dr-post-mount-provision --access-self-test; sudo -n /usr/local/sbin/dr-launch-kit --access-self-test; then root executes only an approved harmless fixture and reads all runtime libraries
  7. Deactivate the DRIP share, confirm /mnt/p is removed, then confirm KIT.sh EXIT cleanup removes /tmp/krb5cc_0
  8. For another Arch domain user, stop/unmount first and have a local administrator run: sudo /usr/local/sbin/dr-tools-rebind <new-domain-user-uid>; verify the unit's cruid changes before access
  Mount must show sec=krb5,cruid=<logged-in-domain-user-uid>,vers=3.0; a normal-user ls alone is insufficient.
EOF
}

render_debian_kit_compatibility_contract() {
    cat << 'EOF'
Ubuntu/Debian KIT compatibility contract (KIT.sh is shared and unchanged):
  User login: KRB5CCNAME=FILE:/tmp/krb5cc_<domain-uid>_<random>
  sudo launch: preserve that exact KRB5CCNAME; SUDO_UID identifies the domain user
  KIT.sh: copy the user cache to /tmp/krb5cc_0, chown root:root, mode 0600, remove on EXIT
  DRIP /smb and /mnt/p: sec=krb5,cruid=0; CIFS service tickets accumulate in /tmp/krb5cc_0
  KIT /mnt/x: sec=krb5,cruid=<domain-user-uid>,vers=3.0
  Debian DRIP paths: dynamic autofs /smb/<server>/<share>/ and /net/<server>/<share>/
  Required live checks: root KIT read/execute, DRIP activation/deactivation, bounded read, and cache cleanup
EOF
}

install_arch_tools_mount_helper() {
    local cruid
    cruid="$(tools_mount_cruid)" || {
        print_error "Cannot install Arch Tool Server helper without a verified domain-user UID"
        return 1
    }
    render_arch_tools_mount_helper "$cruid" > /usr/local/bin/mount-kit-tools
    chmod 755 /usr/local/bin/mount-kit-tools
    chown root:root /usr/local/bin/mount-kit-tools
}

configure_autofs_cifs() {
    print_info "Configuring CIFS access for DRIP and KIT tools..."

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        platform_validate_selected_domain_user || return 1
        platform_install_tools_mount || return 1
        if platform_validate_drip_search_roots; then
            platform_install_drip_search || return 1
        elif [ "$DRIP_REQUIRED" = true ]; then
            print_error "Configured Arch DRIP search roots are invalid; core completion is blocked"
            return 1
        else
            print_warning "Skipping invalid optional Arch DRIP search roots because DRIP_REQUIRED=false"
        fi
    else
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
    backup_config_file /etc/auto.master.d/mnt.autofs
    backup_config_file /etc/auto.mnt.direct
    backup_config_file /etc/auto.mnt
    backup_config_file /etc/auto.master.d/smb.autofs
    backup_config_file /etc/auto.master.d/net.autofs
    backup_config_file /etc/auto.net.cifs
    rm -f /etc/auto.master.d/mnt.autofs /etc/auto.mnt.direct /etc/auto.mnt

    render_autofs_master_maps | awk 'NR == 1' > /etc/auto.master.d/smb.autofs
    render_autofs_master_maps | awk 'NR == 2' > /etc/auto.master.d/net.autofs

    # Executable map: called by autofs with the server hostname as $1.
    # Creates a per-server wildcard share map and returns a nested autofs mount.
    # cruid=${UID} tells the CIFS kernel module to use the accessing user's
    # Kerberos ticket — no root credentials or share enumeration required.
    render_autofs_cifs_map > /etc/auto.net.cifs

    chmod +x /etc/auto.net.cifs
    fi

    # Fixed KIT tools mount helper. This preserves the expected path:
    #   /mnt/x -> //TOOLS_SERVER/Tools
    # but avoids depending on autofs for the fixed mount point.
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        install_arch_tools_mount_helper
    else
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
        echo "  su - $DR_LOCAL_ADMIN_USER" >&2
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
    fi

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
        echo "  su - $DR_LOCAL_ADMIN_USER"
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

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        platform_start_tools_mount
        if platform_verify_tools_mount; then
            print_info "Systemd Tool Server automount is enabled and unit verification passed"
        else
            print_warning "Systemd Tool Server unit is installed but could not be fully verified"
        fi
    else
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
    fi
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

    if [ "$PLATFORM_FAMILY" = arch ] && platform_ad_dns_discovery_current && printf '%s\n' "$current" | tr ',' '\n' | awk '{$1=$1; print}' | grep -Fxq "$DOMAIN"; then
        print_info "Preserving already-valid AD DNS search configuration on '$connection'"
        return 0
    fi

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

    backup_config_file /etc/NetworkManager/system-connections
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

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        backup_config_file "$smb_conf"
        mkdir -p "$(dirname "$smb_conf")"
        render_arch_smb_conf > "$smb_conf"
        chmod 644 "$smb_conf"
        chown root:root "$smb_conf"
        if ! testparm -s "$smb_conf" >/dev/null 2>&1; then
            print_error "Generated Arch Samba configuration failed testparm"
            return 1
        fi
        platform_install_machine_account_renewal
        print_info "Installed Samba ADS configuration with documented 4.21+ keytab synchronization"
        return 0
    fi

    if [ ! -f "$smb_conf" ]; then
        mkdir -p "$(dirname "$smb_conf")"
        printf '[global]\n' > "$smb_conf"
    fi

    if grep -q "^[[:space:]]*workgroup = $WORKGROUP" "$smb_conf" 2>/dev/null && \
       grep -q "^[[:space:]]*realm = $REALM" "$smb_conf" 2>/dev/null; then
        print_info "smb.conf is already configured — skipping"
        return 0
    fi

    backup_config_file "$smb_conf"

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
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        print_info "Arch backend leaves NSS host resolution unchanged; winbind/WINS is not required"
        return 0
    fi
    local nsswitch="/etc/nsswitch.conf"
    print_info "Configuring NetBIOS name resolution..."

    if grep -qE "^hosts:.*wins" "$nsswitch" 2>/dev/null; then
        print_info "wins already present in $nsswitch"
        return 0
    fi

    backup_config_file "$nsswitch"
    if sed -i '/^hosts:/s/dns/wins dns/' "$nsswitch"; then
        print_info "Added wins to hosts resolution in $nsswitch"
    else
        print_warning "Failed to update $nsswitch — NetBIOS name resolution may not work"
    fi
}

# ── Enable and start winbind ──────────────────────────────────────────────────

enable_winbind() {
    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        print_info "Arch backend does not enable winbind; SSSD provides NSS, PAM, identity, and group resolution"
        return 0
    fi
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
# ── Desktop integration adapter ─────────────────────────────────────────────

configure_desktop_integration() {
    case "$PLATFORM_DESKTOP" in
        "GNOME")
            configure_gdm_login_prompt
            ;;
        "KDE Plasma")
            print_info "KDE Plasma detected; preserving user preferences and installing only shared desktop launchers"
            ;;
        *)
            print_warning "Desktop '$PLATFORM_DESKTOP' is not supported by the customization adapter; core provisioning continues"
            ;;
    esac
}

# ── Check display manager ─────────────────────────────────────────────────────
# Do NOT restart the display manager automatically. Restarting a login manager
# while the script is running inside a desktop session kills that session,
# which terminates the terminal and aborts the script mid-execution — leaving
# the machine in a partially configured state. Use systemd's generic alias so
# KDE Plasma Login Manager, GDM, LightDM, and future implementations are not
# conflated with the desktop environment.

check_display_manager() {
    platform_detect_display_manager
    if systemctl is-active --quiet display-manager.service 2>/dev/null; then
        DISPLAY_MANAGER_RUNNING=true
    else
        DISPLAY_MANAGER_RUNNING=false
    fi
}

# ── Verify ────────────────────────────────────────────────────────────────────

verify_join() {
    print_info "Verifying domain join..."

    if ! platform_drip_requirement_satisfied; then
        print_error "Completion is blocked because configured Arch DRIP roots are not available"
        print_error "Arch claims only configured /smb roots; arbitrary dynamic /smb and /net paths remain unsupported"
        return 1
    fi

    if ! platform_domain_is_joined; then
        print_error "Domain join verification failed — machine does not appear to be joined"
        return 1
    fi
    print_info "Domain join verified: $DOMAIN"

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        platform_validate_selected_domain_user || return 1
        platform_validate_machine_keytab || return 1
        platform_verify_machine_account_renewal || {
            print_error "Arch machine-account renewal timer/helper is missing or invalid"
            return 1
        }
    fi

    if ! systemctl is-active --quiet sssd 2>/dev/null; then
        print_error "SSSD is not running — domain logins will fail"
        print_error "Check: journalctl -u sssd -n 50"
        return 1
    fi
    print_info "SSSD is running"

    if [ "$PLATFORM_FAMILY" = "arch" ]; then
        if command -v sssctl >/dev/null 2>&1; then
            sssctl config-check
            print_info "SSSD configuration validated with sssctl"
        else
            print_error "sssctl is unavailable after the Arch sssd package checkpoint"
            return 1
        fi
        platform_verify_drip_search || {
            print_error "Configured Arch DRIP systemd units are missing, invalid, or globally enabled"
            return 1
        }
        print_info "Configured Arch DRIP search units validated; live KIT/DRIP lifecycle remains unverified"
    fi

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
    local requested_office=""
    local persisted_office="${OFFICE_CODE:-}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --platform-report)
                PLATFORM_REPORT_ONLY=true
                ;;
            --preflight)
                PREFLIGHT_ONLY=true
                ;;
            --dry-run)
                DRY_RUN_ONLY=true
                ;;
            --dns-test)
                DNS_TEST_ONLY=true
                ;;
            --full-reconfigure)
                FULL_RECONFIGURE=true
                ;;
            -h|--help)
                echo 'Usage: wget -qO- http://ontrack.link/joindomain | sudo bash'
                echo 'Args:  wget -qO- http://ontrack.link/joindomain | sudo bash -s -- [OFFICE_CODE] [--platform-report|--preflight|--dry-run|--dns-test]'
                echo "  If no office code has been saved, you will be prompted for it."
                echo "  --platform-report   Read-only platform, package, service, PAM, and desktop report."
                echo "  --preflight         Read-only readiness validation; blockers return nonzero."
                echo "  --dry-run           Read-only ordered plan; blockers return nonzero."
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
                if [ -z "$requested_office" ]; then
                    requested_office="$1"
                else
                    print_error "Unexpected argument: $1"
                    echo 'Usage: wget -qO- http://ontrack.link/joindomain | sudo bash'
                    exit 1
                fi
                ;;
        esac
        shift
    done

    if [ -n "$requested_office" ]; then
        requested_office="$(echo "$requested_office" | tr '[:lower:]' '[:upper:]' | xargs)"
        persisted_office="$(echo "$persisted_office" | tr '[:lower:]' '[:upper:]' | xargs)"
        if [ -n "$persisted_office" ] && [ "$requested_office" != "$persisted_office" ]; then
            print_error "Office code $requested_office conflicts with persisted office code $persisted_office."
            print_error "Rerun with the persisted code or resolve the state explicitly before continuing."
            return 1
        fi
        OFFICE_CODE="$requested_office"
    elif [ -n "$persisted_office" ]; then
        OFFICE_CODE="$persisted_office"
        print_info "Using saved office code: $OFFICE_CODE"
    fi

    # The inspection modes must not prompt for office selection or save state.
    if [ "$PLATFORM_REPORT_ONLY" = true ] || [ "$PREFLIGHT_ONLY" = true ] || [ "$DRY_RUN_ONLY" = true ]; then
        return 0
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
    # clobbering the installer state machine. The actual state write is delayed
    # until the read-only preflight has passed in main().
    OFFICE_CODE="$(echo "$OFFICE_CODE" | tr '[:lower:]' '[:upper:]' | xargs)"

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

# Parse only the mode/override flags before the completed-workstation guard.
# This function intentionally performs no prompts, state writes, package
# checks, service operations, or configuration changes.
parse_mode_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --platform-report) PLATFORM_REPORT_ONLY=true ;;
            --preflight) PREFLIGHT_ONLY=true ;;
            --dry-run) DRY_RUN_ONLY=true ;;
            --full-reconfigure) FULL_RECONFIGURE=true ;;
        esac
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    echo "=========================================="
  echo "  DR Domain Join"
  echo "  Version ${SCRIPT_VERSION}"
  echo "=========================================="
    echo ""

    check_privileges "$@"
    load_state || true
    parse_mode_args "$@"
    completed_workstation_rerun_guard "$@"
    parse_args "$@"

    if [ "$PLATFORM_REPORT_ONLY" = true ] || [ "$PREFLIGHT_ONLY" = true ] || [ "$DRY_RUN_ONLY" = true ]; then
        if ! detect_os; then
            if [ "$PLATFORM_REPORT_ONLY" = true ]; then
                platform_report
                exit 0
            fi
            if [ "$PREFLIGHT_ONLY" = true ]; then
                platform_preflight
                exit $?
            fi
            platform_dry_run
            exit $?
        fi
        load_config
        if [ "$PLATFORM_REPORT_ONLY" = true ]; then
            platform_report
            exit 0
        elif [ "$PREFLIGHT_ONLY" = true ]; then
            platform_preflight
            exit $?
        else
            platform_dry_run
            exit $?
        fi
    fi

    # Detect the platform before any normal-run prompt or modifying helper.
    # This also ensures the initial live checkpoint is preceded by a complete
    # read-only platform/preflight pass.
    detect_os || exit 1
    load_config

    if state_requires_recovery; then
        recover_stale_state
        exit 2
    fi

    print_resume_state
    print_machine_status

    # --- Summary ---
    if platform_domain_is_joined; then
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

    if ! platform_preflight; then
        print_error "Read-only preflight did not pass; no hostname, DNS, package, PAM, SSSD, sudoers, mount, or domain-membership changes will be made."
        exit 2
    fi

    validate_or_fix_hostname || exit 1

    if [ -f "$STATE_FILE" ] && grep -q 'STAGE="REBOOT_REQUIRED_AFTER_HOSTNAME"' "$STATE_FILE" 2>/dev/null; then
        current_hn="$(hostnamectl --static 2>/dev/null || hostname)"
        if [ -n "${DOMAIN_TARGET_HOSTNAME:-}" ] && [ "$current_hn" = "$DOMAIN_TARGET_HOSTNAME" ]; then
            print_info "Hostname reboot requirement satisfied for $current_hn"
            save_state "PREJOIN_AFTER_HOSTNAME_REBOOT"
        fi
    fi

    if [ ! -f "$STATE_FILE" ]; then
        save_state "OFFICE_CODE_SELECTED"
    else
        save_state "${STAGE:-OFFICE_CODE_SELECTED}"
    fi

    # This is the first modifying phase of a normal run. Keep these safeguards
    # out of --platform-report/--preflight/--dry-run and out of the initial
    # repository-only validation path.
    ensure_local_pam_survives_sssd_failure
    disable_sssd_if_not_joined

    # --- Automated steps (no further input required) ---
    # Time/DNS must be healthy on every run — including post-join reruns —
    # before apt, Kerberos, SSSD, or domain configuration is touched.
    # Do not run apt before sync_time(); apt can fail if the clock is wrong.
    install_time_sync_prerequisites
    configure_dns_servers
    configure_dns_search_domains
    bootstrap_time_before_packages || exit 2

    if [ "$PLATFORM_FAMILY" = "debian" ]; then
        print_info "Pre-flight package manager check: verifying apt/dpkg are not locked before installation..."
        wait_for_apt_locks || exit 1
    fi

    if [ "$DNS_TEST_ONLY" = true ]; then
        verify_ad_discovery
        print_info "DNS/domain discovery test completed. No domain join attempted."
        exit 0
    fi

    install_domain_packages
    if [ "$PLATFORM_FAMILY" = debian ] || [ "$(platform_time_provider selected)" = chronyd ] || [ "$(platform_time_provider selected)" = chrony ]; then
        configure_chrony
    fi
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
    platform_configure_nss
    platform_validate_selected_domain_user
    configure_desktop_integration
    install_dr_workstation_manager
    configure_autofs_cifs
    configure_sudoers
    configure_samba
    configure_wins_resolution
    enable_winbind
    check_display_manager

    if verify_join; then
        echo ""
        platform_initialize_machine_account_renewal_state
        save_state "POSTJOIN_AWAITING_LIVE_VALIDATION"
        rm -f /etc/motd 2>/dev/null || true
        print_info "Static domain provisioning completed; live validation is still required."
        print_info "State: POSTJOIN_AWAITING_LIVE_VALIDATION"
        print_info "Record validated phases with: sudo /usr/local/sbin/dr-domain-join-live-validate --record STATE"
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
