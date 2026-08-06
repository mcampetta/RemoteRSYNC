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

    unit_dir="$TMP_DIR/systemd-units"
    mkdir -p "$unit_dir"
    DR_JOIN_STATE_DIR="$TMP_DIR/arch-units" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; render_arch_tools_mount_unit /mnt/x dr-ep1-tools > '$unit_dir/mnt-x.mount'; render_arch_tools_automount_unit /mnt/x > '$unit_dir/mnt-x.automount'"
    assert_contains "$(sed -n '1,120p' "$unit_dir/mnt-x.mount")" "Options=_netdev,nofail,sec=krb5,multiuser,vers=3.0" "systemd CIFS mount safety options"
    assert_contains "$(sed -n '1,120p' "$unit_dir/mnt-x.mount")" "TimeoutSec=30s" "systemd CIFS mount timeout"
    assert_contains "$(sed -n '1,120p' "$unit_dir/mnt-x.automount")" "TimeoutIdleSec=300s" "systemd automount idle timeout"
    command -v systemd-analyze >/dev/null 2>&1 || fail "systemd-analyze is required for unit validation"
    systemd-analyze verify "$unit_dir/mnt-x.mount" "$unit_dir/mnt-x.automount" >/dev/null 2>&1 || fail "generated systemd units validate"
    pass "generated systemd mount and automount units validate"
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
test_state_and_guard
test_modes
test_missing_capability
test_arch_backend_and_break_glass
test_missing_commands_and_packages
printf 'Completed %d tests\n' "$pass_count"
