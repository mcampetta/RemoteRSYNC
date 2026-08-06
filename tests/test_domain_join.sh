#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPT="$REPO_DIR/domain-join-latest.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass_count=0
pass() { pass_count=$((pass_count + 1)); printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
assert_eq() {
    local expected="$1" actual="$2" name="$3"
    [ "$expected" = "$actual" ] || fail "$name: expected '$expected', got '$actual'"
    pass "$name"
}
assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    printf '%s\n' "$haystack" | grep -Fq "$needle" || fail "$name: missing '$needle'"
    pass "$name"
}
write_os_release() {
    local file="$1" id="$2" like="$3" version="$4"
    printf 'NAME="%s"\nID=%s\nID_LIKE="%s"\nVERSION_ID="%s"\n' "$id" "$id" "$like" "$version" > "$file"
}

test_detection() {
    local fixture
    fixture="$TMP_DIR/cachyos-release"; write_os_release "$fixture" cachyos arch rolling
    DR_JOIN_OS_RELEASE_FILE="$fixture" DR_JOIN_STATE_DIR="$TMP_DIR/state-cachyos" bash -c "source '$SCRIPT'; detect_platform; [ \"\$PLATFORM_FAMILY\" = arch ] && [ \"\$PLATFORM_SUPPORTED\" = true ]"
    pass "CachyOS is detected as Arch family"
    fixture="$TMP_DIR/arch-release"; write_os_release "$fixture" arch arch rolling
    DR_JOIN_OS_RELEASE_FILE="$fixture" DR_JOIN_STATE_DIR="$TMP_DIR/state-arch" bash -c "source '$SCRIPT'; detect_platform; [ \"\$PLATFORM_FAMILY\" = arch ]"
    pass "Native Arch is detected as Arch family"
    fixture="$TMP_DIR/ubuntu-release"; write_os_release "$fixture" ubuntu debian 24.04
    DR_JOIN_OS_RELEASE_FILE="$fixture" DR_JOIN_STATE_DIR="$TMP_DIR/state-ubuntu" bash -c "source '$SCRIPT'; detect_platform; [ \"\$PLATFORM_FAMILY\" = debian ] && [ \"\$PLATFORM_SUPPORTED\" = true ]"
    pass "Ubuntu is detected as Debian family"
    fixture="$TMP_DIR/debian-release"; write_os_release "$fixture" debian debian 13
    DR_JOIN_OS_RELEASE_FILE="$fixture" DR_JOIN_STATE_DIR="$TMP_DIR/state-debian" bash -c "source '$SCRIPT'; detect_platform; [ \"\$PLATFORM_FAMILY\" = debian ] && [ \"\$PLATFORM_SUPPORTED\" = true ]"
    pass "Debian is detected as Debian family"
    fixture="$TMP_DIR/unsupported-release"; write_os_release "$fixture" alpine linux 3.22
    DR_JOIN_OS_RELEASE_FILE="$fixture" DR_JOIN_STATE_DIR="$TMP_DIR/state-unsupported" bash -c "source '$SCRIPT'; detect_platform; [ \"\$PLATFORM_FAMILY\" = unknown ] && [ \"\$PLATFORM_SUPPORTED\" = false ]"
    pass "Unsupported distro is rejected"
}

test_mappings() {
    local output
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/map" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; printf '%s\\n' \"\$(platform_package_name kerberos)\" \"\$(platform_package_name dns)\" \"\$(platform_package_name ssh-server)\" \"\$(platform_package_name realmd)\"")"
    assert_eq $'krb5\nbind\nopenssh' "$output" "Arch package mapping"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/map2" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; OS=ubuntu; printf '%s\\n' \"\$(platform_package_name kerberos)\" \"\$(platform_package_name dns)\" \"\$(platform_package_name ssh-server)\"")"
    assert_eq $'krb5-user\ndnsutils\nopenssh-server' "$output" "Debian package mapping"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/service" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_service_name time-sync; platform_service_name ssh-server")"
    assert_eq $'chronyd\nsshd' "$output" "Arch service mapping"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/admin" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_admin_group")"
    assert_eq "wheel" "$output" "Arch administrator group selection"
}

test_renderers() {
    local output
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/sssd" bash -c "source '$SCRIPT'; render_sssd_config")"
    assert_contains "$output" "use_fully_qualified_names = False" "SSSD renderer short-name setting"
    assert_contains "$output" "access_provider = simple" "SSSD renderer local-access policy"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/sssd-arch" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_sssd_config")"
    assert_contains "$output" "ad_maximum_machine_account_password_age = 0" "Arch disables competing SSSD renewal"
    assert_contains "$output" "ad_update_samba_machine_account_password = false" "Arch does not blindly enable SSSD Samba renewal"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/krb" bash -c "source '$SCRIPT'; render_krb5_config")"
    assert_contains "$output" "default_realm = DR.KODR.LOCAL" "Kerberos renderer realm"
    assert_contains "$output" "rdns = false" "Kerberos renderer reverse-DNS policy"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/auto" bash -c "source '$SCRIPT'; render_autofs_master_maps")"
    assert_contains "$output" "/smb    /etc/auto.net.cifs" "autofs SMB map"
    assert_contains "$output" "/net    /etc/auto.net.cifs" "autofs NET map"
    stage_dir="$TMP_DIR/staged-config"
    DR_JOIN_STATE_DIR="$TMP_DIR/stage-state" bash -c "source '$SCRIPT'; stage_generated_configurations '$stage_dir' >/dev/null"
    [ -s "$stage_dir/krb5.conf" ] && [ -s "$stage_dir/sssd.conf" ] && [ -s "$stage_dir/auto.net.cifs" ] || fail "configuration staging output"
    pass "configuration staging output"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/sudo" bash -c "source '$SCRIPT'; render_workstation_sudoers")"
    assert_contains "$output" "%domain\\ users ALL=(root) NOPASSWD" "domain-users sudoers quoting"
    assert_contains "$output" "%dr-workstation-admins ALL=(ALL:ALL) ALL" "managed admin sudoers policy"
    printf '%s\n' "$output" > "$TMP_DIR/sudoers.fragment"
    if visudo -cf "$TMP_DIR/sudoers.fragment" >/dev/null 2>&1; then
        pass "generated sudoers validates with visudo"
    else
        fail "generated sudoers validates with visudo"
    fi
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/user" bash -c "source '$SCRIPT'; render_domain_user_sudoers 'alice.smith@dr.kodr.local'")"
    assert_eq "alice.smith ALL=(root) NOPASSWD: /usr/local/bin/mount-kit-tools" "$output" "domain username normalization"
    if DR_JOIN_STATE_DIR="$TMP_DIR/invalid-user" bash -c "source '$SCRIPT'; render_domain_user_sudoers 'alice smith'" >/dev/null 2>&1; then
        fail "unsafe sudoers username is rejected"
    fi
    pass "unsafe sudoers username is rejected"

    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/arch-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; render_arch_smb_conf")"
    assert_contains "$output" "kerberos method = secrets only" "Samba 4.21 keytab method"
    assert_contains "$output" "sync machine password to keytab = /etc/krb5.keytab" "Samba declarative keytab rule"
    assert_contains "$output" "idmap config * : range = 100000-199999" "Samba testparm idmap range"
    printf '%s\n' "$output" > "$TMP_DIR/arch-smb.conf"
    if testparm -s "$TMP_DIR/arch-smb.conf" >/dev/null 2>&1; then
        pass "generated Arch smb.conf validates with testparm"
    else
        fail "generated Arch smb.conf validates with testparm"
    fi

    unit_dir="$TMP_DIR/systemd-units"
    mkdir -p "$unit_dir"
    DR_JOIN_STATE_DIR="$TMP_DIR/arch-units" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; render_arch_tools_mount_unit /mnt/x dr-ep1-tools 1000 > '$unit_dir/mnt-x.mount'; render_arch_tools_automount_unit /mnt/x > '$unit_dir/mnt-x.automount'"
    assert_contains "$(sed -n '1,120p' "$unit_dir/mnt-x.mount")" "Options=_netdev,nofail,sec=krb5,cruid=1000,vers=3.0" "systemd CIFS mount ownership options"
    if grep -Fq 'multiuser' "$unit_dir/mnt-x.mount"; then
        fail "Arch KIT mount must not use unproven multiuser root ownership"
    fi
    pass "Arch KIT mount avoids unproven multiuser ownership"
    assert_contains "$(sed -n '1,120p' "$unit_dir/mnt-x.mount")" "TimeoutSec=30s" "systemd CIFS mount timeout"
    assert_contains "$(sed -n '1,120p' "$unit_dir/mnt-x.automount")" "TimeoutIdleSec=300s" "systemd automount idle timeout"
    command -v systemd-analyze >/dev/null 2>&1 || fail "systemd-analyze is required for unit validation"
    systemd-analyze verify "$unit_dir/mnt-x.mount" "$unit_dir/mnt-x.automount" >/dev/null 2>&1 || fail "generated systemd units validate"
    pass "generated systemd mount and automount units validate"

    helper="$TMP_DIR/mount-kit-tools"
    DR_JOIN_STATE_DIR="$TMP_DIR/arch-helper" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; DR_TOOLS_MOUNT_CRUID=1000; render_arch_tools_mount_helper 1000 > '$helper'"
    bash -n "$helper" || fail "generated Arch mount helper syntax"
    helper_output="$(sed -n '1,180p' "$helper")"
    assert_contains "$helper_output" 'AUTOMOUNT_UNIT="mnt-x.automount"' "Arch mount helper defines automount unit"
    assert_contains "$helper_output" 'KRB5CCNAME="FILE:/tmp/krb5cc_$CRUID" klist -s' "Arch mount helper checks selected user's Kerberos cache"
    assert_contains "$helper_output" 'sudo -n /usr/local/bin/mount-kit-tools --cruid' "Arch mount helper passes UID through sudo"
    if printf '%s\n' "$helper_output" | grep -Fq 'sec=krb5,multiuser'; then
        fail "Arch mount helper must not claim multiuser ownership"
    fi
    pass "Arch mount helper is root/Kerberos ownership aware"

    renewal_dir="$TMP_DIR/renew-units"
    mkdir -p "$renewal_dir/usr/local/sbin"
    DR_JOIN_STATE_DIR="$TMP_DIR/renew-staged" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_helper > '$renewal_dir/usr/local/sbin/dr-domain-machine-password-renew'; render_arch_machine_account_renewal_service > '$renewal_dir/dr-domain-machine-password-renew.service'; render_arch_machine_account_renewal_timer > '$renewal_dir/dr-domain-machine-password-renew.timer'"
    chmod +x "$renewal_dir/usr/local/sbin/dr-domain-machine-password-renew"
    sed -i "s#/usr/local/sbin/dr-domain-machine-password-renew#$renewal_dir/usr/local/sbin/dr-domain-machine-password-renew#" "$renewal_dir/dr-domain-machine-password-renew.service"
    systemd-analyze verify "$renewal_dir/dr-domain-machine-password-renew.service" "$renewal_dir/dr-domain-machine-password-renew.timer" >/dev/null 2>&1 || fail "generated machine-renewal units validate"
    pass "generated machine-renewal units validate"
}

test_drip_compatibility() {
    local output
    if DR_JOIN_STATE_DIR="$TMP_DIR/drip-path" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_drip_path_supported /smb/dr-ep-drip04/ImageFolders/test"; then
        fail "Arch must not claim /smb DRIP support"
    fi
    pass "Arch blocks representative /smb DRIP path"
    if DR_JOIN_STATE_DIR="$TMP_DIR/drip-net-path" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_drip_path_supported /net/dr-ep-drip04/ImageFolders/test"; then
        fail "Arch must not claim /net DRIP support"
    fi
    pass "Arch blocks representative /net DRIP path"
    output="$(DRIP_REQUIRED=true DR_JOIN_STATE_DIR="$TMP_DIR/drip-required" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_drip_requirement || true; printf 'blockers=%s\\n' \"\$PREFLIGHT_BLOCKERS\"")"
    assert_contains "$output" "BLOCKED Arch DRIP is unsupported" "required Arch DRIP is a blocker"
    assert_contains "$output" "blockers=1" "required Arch DRIP increments blockers"
    output="$(DRIP_REQUIRED=false DR_JOIN_STATE_DIR="$TMP_DIR/drip-optional" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_drip_requirement; printf 'blockers=%s\\n' \"\$PREFLIGHT_BLOCKERS\"")"
    assert_contains "$output" "WARNING Arch DRIP is unsupported" "optional Arch DRIP is explicit"
    assert_contains "$output" "blockers=0" "optional Arch DRIP does not block KIT-only mode"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/debian-drip" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; platform_drip_path_supported /smb/dr-ep-drip04/ImageFolders/test; platform_drip_path_supported /net/dr-ep-drip04/ImageFolders/test; platform_validate_drip_requirement")"
    assert_contains "$output" "PASS DRIP dynamic paths are provided by the Debian autofs adapter" "Debian DRIP remains supported"
}

test_machine_account_renewal() {
    local policy helper service timer
    policy="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-policy" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_machine_account_renewal_policy")"
    assert_contains "$policy" "authority: dr-domain-machine-password-renew.service/timer" "Arch renewal authority is explicit"
    assert_contains "$policy" "ad_maximum_machine_account_password_age=0" "SSSD default renewal is disabled on Arch"
    assert_contains "$policy" "ad_update_samba_machine_account_password: false" "SSSD Samba bridge is not enabled blindly"
    helper="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-helper" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_helper")"
    assert_contains "$helper" "net ads changetrustpw -P" "renewal uses Samba machine credentials"
    assert_contains "$helper" "net ads keytab create" "renewal rebuilds the system keytab"
    assert_contains "$helper" "net ads testjoin" "renewal validates machine membership"
    assert_contains "$(sed -n '6160,6215p' "$SCRIPT")" "sssctl config-check" "Arch post-join validation uses sssctl"
    if printf '%s\n' "$helper" | grep -Eq 'realm join|adcli'; then
        fail "Arch renewal helper must not depend on realm or adcli"
    fi
    pass "Arch renewal helper excludes unavailable realm/adcli helpers"
    service="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-service" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_service")"
    timer="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-timer" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_timer")"
    assert_contains "$service" "ExecStart=/usr/local/sbin/dr-domain-machine-password-renew" "renewal service command"
    assert_contains "$timer" "OnUnitActiveSec=25d" "renewal timer cadence"
    assert_contains "$timer" "RandomizedDelaySec=6h" "renewal timer jitter"
}

test_kit_root_access_and_helpers() {
    local plan post_section launcher
    plan="$(DR_JOIN_STATE_DIR="$TMP_DIR/kit-plan" bash -c "source '$SCRIPT'; render_kit_root_access_test_plan martin")"
    assert_contains "$plan" "Domain user ticket/list" "KIT staged domain-user test"
    assert_contains "$plan" "Root-through-sudo list/execute" "KIT staged root list/execute test"
    assert_contains "$plan" "dr-post-mount-provision --access-self-test" "KIT staged post-mount read test"
    assert_contains "$plan" "dr-launch-kit --access-self-test" "KIT staged launcher/runtime read test"
    assert_contains "$plan" "sec=krb5,cruid=<logged-in-domain-user-uid>,vers=3.0" "KIT staged ownership model"

    post_section="$(sed -n '/cat > \/usr\/local\/sbin\/dr-post-mount-provision << EOF/,/chmod 755 \/usr\/local\/sbin\/dr-post-mount-provision/p' "$SCRIPT")"
    if printf '%s\n' "$post_section" | grep -Fq 'AUTOMOUNT_UNIT'; then
        fail "dr-post-mount-provision must not reference undefined AUTOMOUNT_UNIT"
    fi
    pass "generated post-mount helper has no undefined AUTOMOUNT_UNIT branch"

    launcher="$(sed -n '4488,4540p' "$SCRIPT")"
    assert_contains "$launcher" 'find "\$KIT_DIR" -type f -print0' "KIT launcher checks runtime files as root"
}

test_debian_kit_and_autofs_regression() {
    local output
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/debian-autofs-regression" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; render_autofs_master_maps; render_autofs_cifs_map")"
    assert_contains "$output" "/smb    /etc/auto.net.cifs" "Debian SMB autofs map preserved"
    assert_contains "$output" "/net    /etc/auto.net.cifs" "Debian NET autofs map preserved"
    assert_contains "$output" 'sec=krb5,cruid=${UID},vers=3.0' "Debian KIT/DRIP Kerberos ownership preserved"
}

test_state_and_guard() {
    local state_dir="$TMP_DIR/state-machine"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; OFFICE_CODE=EP1; save_state PREJOIN; grep -q '^STAGE=\"PREJOIN\"' \"\$STATE_FILE\""
    pass "state save transition"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; [ \"\$STAGE\" = PREJOIN ] && save_state POSTJOIN_COMPLETE; grep -q '^STAGE=\"POSTJOIN_COMPLETE\"' \"\$STATE_FILE\""
    pass "post-join state transition"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; PLATFORM_REPORT_ONLY=true; completed_workstation_rerun_guard --platform-report; [ \"\$FULL_RECONFIGURE\" = false ]"
    pass "completed state permits read-only report without refresh writes"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; completed_workstation_rerun_guard --full-reconfigure; [ \"\$FULL_RECONFIGURE\" = true ]"
    pass "full-reconfigure override is recognized"
}

test_modes() {
    local output rc
    output="$(DR_JOIN_TEST_MODE=true DR_JOIN_STATE_DIR="$TMP_DIR/mode-report" bash "$SCRIPT" --platform-report 2>&1)" || fail "platform-report mode exits successfully"
    assert_contains "$output" "Platform report" "platform-report output"
    assert_contains "$output" "family=arch" "platform-report Arch family"
    set +e
    output="$(DR_JOIN_TEST_MODE=true DR_JOIN_STATE_DIR="$TMP_DIR/mode-preflight" bash "$SCRIPT" --preflight 2>&1)"; rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "preflight reports current host blockers"
    assert_contains "$output" "BLOCKED Preflight" "preflight blocker output"
    set +e
    output="$(DR_JOIN_TEST_MODE=true DR_JOIN_STATE_DIR="$TMP_DIR/mode-dry" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "dry-run propagates blockers"
    assert_contains "$output" "Ordered dry-run plan" "dry-run plan output"
    assert_contains "$output" "WOULD CHANGE" "dry-run change markers"
}

test_missing_capability() {
    local output
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/missing" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_capability_status realmd")"
    assert_contains "$output" "WARNING|realmd|unavailable but no longer required" "Arch realmd is not required"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/missing2" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_capability_status autofs")"
    assert_contains "$output" "WARNING|autofs|unavailable but no longer required" "Arch autofs is not required"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/missing3" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_capability_status adcli")"
    assert_contains "$output" "WARNING|adcli|unavailable but no longer required" "Arch adcli is not required"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/missing4" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_capability_status smbclient")"
    assert_contains "$output" "smbclient" "Arch Samba client package mapping"
}

test_arch_backend_and_break_glass() {
    local plan current_user output
    plan="$(DR_JOIN_STATE_DIR="$TMP_DIR/arch-plan" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_domain_join_plan")"
    assert_contains "$plan" "net ads join --use-kerberos=required" "Arch Samba join command"
    assert_contains "$plan" "net ads keytab create" "Arch Samba keytab command"
    if printf '%s\n' "$plan" | grep -Eq 'realm join|adcli testjoin|autofs'; then
        fail "Arch backend plan contains a removed dependency"
    fi
    pass "Arch backend plan excludes realmd/adcli/autofs"

    current_user="$(id -un)"
    output="$(DR_LOCAL_ADMIN_USER="$current_user" DR_JOIN_STATE_DIR="$TMP_DIR/break-glass" bash -c "source '$SCRIPT'; platform_admin_group >/dev/null; platform_break_glass_is_local")"
    assert_eq "" "$output" "configurable break-glass account resolves as local"
    output="$(DR_LOCAL_ADMIN_USER="$current_user" DR_JOIN_STATE_DIR="$TMP_DIR/break-glass-report" bash -c "source '$SCRIPT'; PLATFORM_ADMIN_GROUP=wheel; PREFLIGHT_BLOCKERS=0; platform_validate_break_glass wheel || true")"
    assert_contains "$output" "Break-glass account: $current_user" "break-glass account is displayed"
    assert_contains "$output" "Password status: operator verification required" "break-glass password is never tested automatically"
}

test_missing_commands_and_packages() {
    local output
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/unavailable-package" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_is_package_installed(){ return 1; }; platform_is_package_available(){ return 1; }; platform_capability_status sssd")"
    assert_contains "$output" "BLOCKED|sssd|sssd unavailable in configured repositories" "unavailable Arch AD package is a blocker"
    if PATH="$TMP_DIR/empty-path" DR_JOIN_STATE_DIR="$TMP_DIR/missing-command" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_domain_testjoin" >/dev/null 2>&1; then
        fail "missing Samba command is rejected safely"
    fi
    pass "missing Samba command is rejected safely"
}

test_detection
test_mappings
test_renderers
test_drip_compatibility
test_machine_account_renewal
test_kit_root_access_and_helpers
test_debian_kit_and_autofs_regression
test_state_and_guard
test_modes
test_missing_capability
test_arch_backend_and_break_glass
test_missing_commands_and_packages
printf 'Completed %d tests\n' "$pass_count"
