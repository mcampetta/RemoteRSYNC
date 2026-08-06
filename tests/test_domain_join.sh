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
    [[ "$haystack" == *"$needle"* ]] || fail "$name: missing '$needle'"
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
    if printf '%s\n' "$output" | grep -Fq 'Defaults!/usr/local/sbin/dr-launch-kit'; then
        fail "KIT Defaults rule must not be duplicated in workstation sudoers"
    fi
    pass "KIT command-scoped Defaults rule is not duplicated in workstation sudoers"
    if printf '%s\n' "$output" | grep -Fq 'SETENV'; then
        fail "KIT sudoers must not grant broad SETENV"
    fi
    pass "KIT sudoers avoids broad environment preservation"
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

    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/kit-sudo" bash -c "source '$SCRIPT'; render_kit_launcher_sudoers 'alice.smith@dr.kodr.local'")"
    assert_contains "$output" 'Defaults!/usr/local/sbin/dr-launch-kit env_keep += "KRB5CCNAME"' "authoritative KIT sudoers preserves only cache selector"
    assert_contains "$output" "alice.smith ALL=(root) NOPASSWD: /usr/local/sbin/dr-launch-kit" "individual KIT launcher rule"
    [ "$(printf '%s\n' "$output" | grep -Fc 'Defaults!/usr/local/sbin/dr-launch-kit')" -eq 1 ] || fail "KIT command-scoped Defaults rule must render exactly once"
    pass "KIT command-scoped Defaults rule renders exactly once"
    printf '%s\n' "$output" > "$TMP_DIR/kit-sudoers.fragment"
    visudo -cf "$TMP_DIR/kit-sudoers.fragment" >/dev/null 2>&1 || fail "command-scoped KIT sudoers validates with visudo"
    pass "command-scoped KIT sudoers validates with visudo"

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
    assert_contains "$helper_output" 'KRB5CCNAME="FILE:/tmp/krb5cc_$CURRENT_CONFIGURED_CRUID" klist -s' "Arch mount helper checks selected user's Kerberos cache"
    assert_contains "$helper_output" 'sudo -n /usr/local/bin/mount-kit-tools --cruid' "Arch mount helper passes UID through sudo"
    if printf '%s\n' "$helper_output" | grep -Fq 'sec=krb5,multiuser'; then
        fail "Arch mount helper must not claim multiuser ownership"
    fi
    assert_contains "$helper_output" "CURRENT_CONFIGURED_CRUID" "Arch helper reads the current unit credential owner"
    assert_contains "$helper_output" "sudo /usr/local/sbin/dr-tools-rebind \$CRUID" "Arch helper provides explicit multi-user rebind path"
    pass "Arch mount helper is root/Kerberos ownership aware"

    rebind_helper="$TMP_DIR/dr-tools-rebind"
    DR_JOIN_STATE_DIR="$TMP_DIR/arch-rebind" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_arch_tools_rebind_helper > '$rebind_helper'"
    bash -n "$rebind_helper" || fail "generated Arch rebind helper syntax"
    rebind_text="$(<"$rebind_helper")"
    assert_contains "$rebind_text" 'systemctl stop "$AUTOMOUNT_UNIT"' "Arch rebind stops automount before changing cruid"
    assert_contains "$rebind_text" 'systemctl stop "$MOUNT_UNIT"' "Arch rebind stops mount after automount"
    assert_contains "$rebind_text" 'systemd-analyze verify "$STAGED_UNIT"' "Arch rebind verifies a complete staged unit"
    assert_contains "$rebind_text" 'mv -f -- "$STAGED_UNIT" "$UNIT_PATH"' "Arch rebind atomically replaces the unit"
    assert_contains "$rebind_text" 'atomic_update_cruid' "Arch rebind persists the selected UID atomically"
    for failure_stage in automount-stop mount-stop render verify replace daemon-reload automount-enable automount-start state-update; do
        assert_contains "$rebind_text" "DR_REBIND_FAIL_STAGE" "rebind supports injected failure stage $failure_stage"
        assert_contains "$rebind_text" "failpoint $failure_stage" "rebind has rollback injection $failure_stage"
    done
    if printf '%s\n' "$rebind_text" | grep -Eq 'sed .* -i|umount .*--lazy|umount .*--force'; then
        fail "Arch rebind must not edit the live unit with sed or use lazy/force unmount"
    fi
    pass "Arch Tool Server rebind helper is transactional and reversible"

    renewal_dir="$TMP_DIR/renew-units"
    mkdir -p "$renewal_dir/usr/local/sbin"
    DR_JOIN_STATE_DIR="$TMP_DIR/renew-staged" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_helper > '$renewal_dir/usr/local/sbin/dr-domain-machine-password-renew'; render_arch_machine_account_renewal_service > '$renewal_dir/dr-domain-machine-password-renew.service'; render_arch_machine_account_renewal_timer > '$renewal_dir/dr-domain-machine-password-renew.timer'"
    chmod +x "$renewal_dir/usr/local/sbin/dr-domain-machine-password-renew"
    sed -i "s#/usr/local/sbin/dr-domain-machine-password-renew#$renewal_dir/usr/local/sbin/dr-domain-machine-password-renew#" "$renewal_dir/dr-domain-machine-password-renew.service"
    systemd-analyze verify "$renewal_dir/dr-domain-machine-password-renew.service" "$renewal_dir/dr-domain-machine-password-renew.timer" >/dev/null 2>&1 || fail "generated machine-renewal units validate"
    pass "generated machine-renewal units validate"
}

test_rebind_failure_rollback() {
    local rebind_helper fake_bin stage case_dir unit state original_unit original_state
    rebind_helper="$TMP_DIR/rebind-rollback-helper"
    fake_bin="$TMP_DIR/rebind-fake-bin"
    mkdir -p "$fake_bin"
    DR_JOIN_STATE_DIR="$TMP_DIR/rebind-rollback-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; render_arch_tools_rebind_helper > '$rebind_helper'"
    bash -n "$rebind_helper" || fail "rollback test helper syntax"

    cat > "$fake_bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    if [ "$#" -eq 1 ]; then
        echo 0
    else
        echo "${2:-0}"
    fi
    exit 0
fi
exec /usr/bin/id "$@"
EOF
    cat > "$fake_bin/getent" << 'EOF'
#!/bin/bash
if [ "${1:-}" = passwd ] && [ "${2:-}" = 1001 ]; then
    echo '1001:fixture:x:1001:Fixture User:/tmp/fixture:/bin/bash'
    exit 0
fi
exec /usr/bin/getent "$@"
EOF
    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
case "${1:-}" in
    is-active) echo inactive; exit 1 ;;
    is-enabled) echo disabled; exit 1 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/pgrep" << 'EOF'
#!/bin/bash
exit 1
EOF
    cat > "$fake_bin/mountpoint" << 'EOF'
#!/bin/bash
exit 1
EOF
    cat > "$fake_bin/systemd-analyze" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod 755 "$fake_bin"/*

    for stage in automount-stop mount-stop render verify replace daemon-reload automount-enable automount-start state-update; do
        case_dir="$TMP_DIR/rebind-failure-$stage"
        unit="$case_dir/units/mnt-x.mount"
        state="$case_dir/state"
        mkdir -p "$(dirname "$unit")"
        printf '%s\n' '[Mount]' 'What=//dr-ep1-tools/Tools' 'Where=/mnt/x' 'Type=cifs' 'Options=_netdev,nofail,sec=krb5,cruid=1000,vers=3.0' > "$unit"
        printf '%s\n' 'STAGE="POSTJOIN_AWAITING_LIVE_VALIDATION"' 'DR_TOOLS_MOUNT_CRUID="1000"' > "$state"
        chmod 600 "$state"
        original_unit="$case_dir/original-unit"
        original_state="$case_dir/original-state"
        cp -- "$unit" "$original_unit"
        cp -- "$state" "$original_state"

        set +e
        PATH="$fake_bin:$PATH" \
            DR_REBIND_UNIT_DIR="$case_dir/units" \
            DR_REBIND_STATE_FILE="$state" \
            DR_REBIND_LOCK_DIR="$case_dir/lock" \
            DR_REBIND_STAGE_ROOT="$case_dir/stage" \
            DR_REBIND_FAIL_STAGE="$stage" \
            "$rebind_helper" 1001 > "$case_dir/output" 2>&1
        local rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "rebind failure injection $stage returns failure"
        cmp -s "$original_unit" "$unit" || fail "rebind failure injection $stage restores unit bytes"
        cmp -s "$original_state" "$state" || fail "rebind failure injection $stage restores persisted UID"
        pass "rebind failure injection $stage restores unit and persisted UID"
    done
}

test_kit_cache_validation() {
    local validator fake_bin cache link uid
    validator="$TMP_DIR/kit-cache-validator.sh"
    fake_bin="$TMP_DIR/fake-klist"
    uid="$(id -u)"
    cache="/tmp/krb5cc_${uid}_fixture_$BASHPID"
    link="/tmp/krb5cc_${uid}_symlink_$BASHPID"

    DR_JOIN_STATE_DIR="$TMP_DIR/cache-render" bash -c "source '$SCRIPT'; render_kit_cache_validator > '$validator'"
    bash -n "$validator" || fail "generated KIT cache validator syntax"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/klist" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "-s" ]; then
    exit 0
fi
printf 'Default principal: invoking-user@DR.KODR.LOCAL\n'
EOF
    chmod 755 "$fake_bin/klist"
    : > "$cache"
    chmod 600 "$cache"

    PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="FILE:$cache" bash -c "source '$validator'; validate_kit_invoking_cache"
    pass "KIT validator accepts an owned 0600 FILE cache with a DR realm principal"

    cache_with_suffix="/tmp/krb5cc_${uid}_abc-123"
    : > "$cache_with_suffix"
    chmod 600 "$cache_with_suffix"
    PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="FILE:$cache_with_suffix" bash -c "source '$validator'; validate_kit_invoking_cache"
    pass "KIT validator accepts the conservative randomized FILE cache suffix"
    rm -f "$cache_with_suffix"

    for unsafe_cache in \
        "/tmp/krb5cc_${uid}_bad/name" \
        "/tmp/krb5cc_${uid}_bad name" \
        "/tmp/krb5cc_${uid}_.." \
        "/tmp/krb5cc_$((uid + 1))_other"; do
        if PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="FILE:$unsafe_cache" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
            fail "KIT validator must reject unsafe or wrong-owner cache path $unsafe_cache"
        fi
    done
    pass "KIT validator rejects unsafe suffixes, slashes, traversal, whitespace, and wrong UID paths"

    chmod 700 "$cache"
    if PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="FILE:$cache" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
        fail "KIT validator must reject executable cache permissions"
    fi
    chmod 600 "$cache"
    pass "KIT validator rejects cache permissions broader than 0600"

    ln -s "$cache" "$link"
    if PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="FILE:$link" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
        fail "KIT validator must reject symlinked caches"
    fi
    pass "KIT validator rejects symlinked caches"

    if PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="FILE:/tmp/krb5cc_0" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
        fail "KIT validator must reject the KIT-owned root cache"
    fi
    pass "KIT validator rejects /tmp/krb5cc_0 before KIT launch"

    if PATH="$fake_bin:$PATH" SUDO_UID="$uid" KRB5CCNAME="DIR:$cache" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
        fail "KIT validator must reject non-FILE cache types"
    fi
    pass "KIT validator rejects non-FILE cache types"

    if PATH="$fake_bin:$PATH" SUDO_UID=0 KRB5CCNAME="FILE:$cache" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
        fail "KIT validator must reject root SUDO_UID"
    fi
    pass "KIT validator rejects root SUDO_UID"

    swap_target="/tmp/krb5cc_${uid}_swap_$BASHPID"
    : > "$swap_target"
    chmod 600 "$swap_target"
    cat > "$fake_bin/klist" << 'EOF'
#!/bin/bash
if [ "$1" = "-s" ]; then
    exit 0
fi
if [ -n "$SWAP_CACHE" ] && [ -f "$SWAP_CACHE" ]; then
    mv -- "$SWAP_CACHE" "$SWAP_CACHE.old"
    : > "$SWAP_CACHE"
    chmod 600 "$SWAP_CACHE"
fi
printf 'Default principal: invoking-user@DR.KODR.LOCAL\n'
EOF
    chmod 755 "$fake_bin/klist"
    if PATH="$fake_bin:$PATH" SWAP_CACHE="$swap_target" SUDO_UID="$uid" KRB5CCNAME="FILE:$swap_target" bash -c "source '$validator'; validate_kit_invoking_cache" >/dev/null 2>&1; then
        fail "KIT validator must reject a cache whose device/inode changes during validation"
    fi
    pass "KIT validator re-stats cache identity and permissions after ticket validation"

    credential_helper="$TMP_DIR/credential-self-test.sh"
    {
        DR_JOIN_STATE_DIR="$TMP_DIR/credential-render" bash -c "source '$SCRIPT'; render_kit_cache_validator"
        DR_JOIN_STATE_DIR="$TMP_DIR/credential-render" bash -c "source '$SCRIPT'; render_kit_credential_self_test"
    } > "$credential_helper"
    bash -n "$credential_helper" || fail "generated credential self-test syntax"
    credential_text="$(<"$credential_helper")"
    assert_contains "$credential_text" '--credential-self-test' "credential self-test mode exists"
    assert_contains "$credential_text" 'cache_basename=' "credential self-test emits only cache basename evidence"
    if printf '%s\n' "$credential_text" | grep -Eq 'cp .*krb5cc_0|mv .*krb5cc_0|rm .*krb5cc_0'; then
        fail "credential self-test must not own /tmp/krb5cc_0"
    fi
    pass "credential self-test is sanitized and never owns the root cache"

    if grep -Eq '(cp|install|mv|tee|cat)[^\n]*[/]tmp/krb5cc_0|[/]tmp/krb5cc_0[^\n]*(cp|install|mv|tee|cat)' "$SCRIPT"; then
        fail "provisioning launcher must not create or overwrite /tmp/krb5cc_0"
    fi
    pass "provisioning launcher leaves /tmp/krb5cc_0 ownership to KIT.sh"
    rm -f "$cache" "$link" "$swap_target" "$swap_target.old"
}

test_drip_compatibility() {
    local output roots unit_dir mount_unit automount_unit helper
    roots="dr-ep-drip04/Images dr-ep-drip05/Images"
    output="$(DR_DRIP_SEARCH_ROOTS="$roots" DR_JOIN_STATE_DIR="$TMP_DIR/drip-path" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_drip_path_supported /smb/dr-ep-drip04/Images/test")"
    assert_eq "" "$output" "Arch supports a configured /smb root"
    if DR_JOIN_STATE_DIR="$TMP_DIR/drip-path" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_drip_path_supported /smb/dr-ep-drip04/ImageFolders/test"; then
        fail "Arch must not claim arbitrary /smb DRIP paths"
    fi
    pass "Arch blocks representative unconfigured /smb DRIP path"
    if DR_JOIN_STATE_DIR="$TMP_DIR/drip-net-path" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_drip_path_supported /net/dr-ep-drip04/ImageFolders/test"; then
        fail "Arch must not claim /net DRIP support"
    fi
    pass "Arch blocks representative /net DRIP path"
    output="$(DRIP_REQUIRED=true DR_DRIP_SEARCH_ROOTS="$roots" DR_JOIN_STATE_DIR="$TMP_DIR/drip-required" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_drip_requirement")"
    assert_contains "$output" "PASS Configured Arch DRIP roots are syntactically valid" "configured Arch DRIP is a preflight pass"
    output="$(DRIP_REQUIRED=true DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images bad root' DR_JOIN_STATE_DIR="$TMP_DIR/drip-invalid" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_drip_requirement || true; printf 'blockers=%s\\n' \"\$PREFLIGHT_BLOCKERS\"")"
    assert_contains "$output" "BLOCKED Arch DRIP configuration is invalid or empty" "malformed required Arch DRIP is a blocker"
    assert_contains "$output" "blockers=1" "malformed required Arch DRIP increments blockers"
    output="$(DRIP_REQUIRED=false DR_DRIP_SEARCH_ROOTS='bad root' DR_JOIN_STATE_DIR="$TMP_DIR/drip-optional" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_drip_requirement")"
    assert_contains "$output" "WARNING Arch configured-root DRIP is invalid or empty" "optional malformed Arch DRIP is explicit"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/debian-drip" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; platform_drip_path_supported /smb/dr-ep-drip04/ImageFolders/test; platform_drip_path_supported /net/dr-ep-drip04/ImageFolders/test; platform_validate_drip_requirement")"
    assert_contains "$output" "PASS DRIP dynamic paths are provided by the Debian autofs adapter" "Debian DRIP remains supported"

    unit_dir="$TMP_DIR/drip-units"
    mkdir -p "$unit_dir"
    mount_unit="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip04/Images)"
    automount_unit="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip04/Images)"
    DR_DRIP_SEARCH_ROOTS="$roots" DR_JOIN_STATE_DIR="$TMP_DIR/drip-unit-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_arch_drip_mount_unit dr-ep-drip04/Images > '$unit_dir/$mount_unit'; render_arch_drip_automount_unit dr-ep-drip04/Images > '$unit_dir/$automount_unit'"
    assert_contains "$(<"$unit_dir/$mount_unit")" "What=//dr-ep-drip04/Images" "Arch DRIP mount source is exact UNC"
    assert_contains "$(<"$unit_dir/$mount_unit")" "Where=/smb/dr-ep-drip04/Images" "Arch DRIP mount target is exact configured root"
    assert_contains "$(<"$unit_dir/$mount_unit")" "sec=krb5,cruid=0,vers=3.0" "Arch DRIP root mount uses root cache ownership"
    systemd-analyze verify "$unit_dir/$mount_unit" "$unit_dir/$automount_unit" >/dev/null 2>&1 || fail "configured Arch DRIP units validate"
    pass "configured Arch DRIP systemd mount and automount units validate"
    if printf '%s\n' "$(<"$unit_dir/$automount_unit")" | grep -Eq '^\[Install\]|WantedBy='; then
        fail "configured Arch DRIP automounts must not carry global install targets"
    fi
    pass "configured Arch DRIP units are rendered without global enablement"

    helper="$(DR_DRIP_MANIFEST="$TMP_DIR/drip.manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$TMP_DIR/drip-helper" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_drip_search_mount_helper")"
    assert_contains "$helper" 'systemctl start "$automount_unit"' "DRIP helper starts automount units only"
    assert_contains "$helper" 'BUSY: could not stop DRIP automount' "DRIP cleanup reports busy automounts"
    if printf '%s\n' "$helper" | grep -Eq '(/mnt/p|krb5cc_0)'; then
        fail "Arch DRIP helper must not own /mnt/p or /tmp/krb5cc_0"
    fi
    pass "Arch DRIP helper has no /mnt/p or root-cache ownership"
}

test_machine_account_renewal() {
    local policy helper service timer script_text
    policy="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-policy" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_machine_account_renewal_policy")"
    assert_contains "$policy" "authority: dr-domain-machine-password-renew.service/timer" "Arch renewal authority is explicit"
    assert_contains "$policy" "ad_maximum_machine_account_password_age=0" "SSSD default renewal is disabled on Arch"
    assert_contains "$policy" "ad_update_samba_machine_account_password: false" "SSSD Samba bridge is not enabled blindly"
    helper="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-helper" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_helper")"
    assert_contains "$helper" "net ads changetrustpw -P" "renewal uses Samba machine credentials"
    assert_contains "$helper" "net ads keytab create" "renewal rebuilds the system keytab"
    assert_contains "$helper" "net ads testjoin" "renewal validates machine membership"
    assert_contains "$helper" "machine-password-last-success" "renewal has a persistent age reference"
    assert_contains "$helper" "machine-password-keytab-repair-needed" "renewal has an explicit repair marker"
    assert_contains "$helper" "--repair-keytab" "renewal exposes keytab-only repair mode"
    assert_contains "$helper" "MIN_AGE_SECONDS=2160000" "renewal enforces a 25-day age gate"
    assert_contains "$helper" "RETRY_DELAYS=(2 5 10)" "renewal bounds keytab regeneration retries"
    assert_contains "$helper" "timedatectl show -p NTPSynchronized" "renewal checks synchronized time"
    assert_contains "$helper" "host -t SRV" "renewal checks AD DNS SRV discovery"
    script_text="$(<"$SCRIPT")"
    assert_contains "$script_text" "sssctl config-check" "Arch post-join validation uses sssctl"
    if printf '%s\n' "$helper" | grep -Eq 'realm join|adcli'; then
        fail "Arch renewal helper must not depend on realm or adcli"
    fi
    pass "Arch renewal helper excludes unavailable realm/adcli helpers"
    service="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-service" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_service")"
    timer="$(DR_JOIN_STATE_DIR="$TMP_DIR/renew-timer" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_timer")"
    assert_contains "$service" "ExecStart=/usr/local/sbin/dr-domain-machine-password-renew" "renewal service command"
    assert_contains "$timer" "OnCalendar=daily" "renewal timer cadence"
    if printf '%s\n' "$timer" | grep -Eq 'OnBootSec|OnUnitActiveSec'; then
        fail "renewal timer must not use boot-relative rotation"
    fi
    assert_contains "$timer" "RandomizedDelaySec=6h" "renewal timer jitter"
    assert_contains "$timer" "Persistent=true" "renewal timer survives reboot without boot-triggered rotation"
    if printf '%s\n' "$helper" | grep -Fq 'ad_update_samba_machine_account_password=true'; then
        fail "renewal must not enable competing SSSD Samba password rotation"
    fi
    pass "renewal ownership and repair policy are explicit"
}

test_machine_account_renewal_behavior() {
    local helper fake_bin state_dir keytab lock_dir log now old rc marker diagnostic
    helper="$TMP_DIR/renew-behavior-helper"
    fake_bin="$TMP_DIR/renew-fake-bin"
    state_dir="$TMP_DIR/renew-behavior-state"
    keytab="$TMP_DIR/renew-behavior-keytab"
    lock_dir="$TMP_DIR/renew-behavior-lock"
    log="$TMP_DIR/renew-net.log"
    mkdir -p "$fake_bin" "$state_dir"
    DR_JOIN_STATE_DIR="$TMP_DIR/renew-behavior-render" bash -c "source '$SCRIPT'; render_arch_machine_account_renewal_helper > '$helper'"
    bash -n "$helper" || fail "renewal behavior helper syntax"
    chmod 755 "$helper"

    cat > "$fake_bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
EOF
    cat > "$fake_bin/timedatectl" << 'EOF'
#!/bin/bash
if [ "${1:-}" = show ] && [ "${2:-}" = -p ]; then
    if [ "${RENEW_TIME_SYNC:-1}" = 1 ]; then echo yes; else echo no; fi
    exit 0
fi
exit 0
EOF
    cat > "$fake_bin/host" << 'EOF'
#!/bin/bash
echo '_kerberos._tcp.dr.kodr.local has SRV record 0 100 88 dc.dr.kodr.local.'
EOF
    cat > "$fake_bin/getent" << 'EOF'
#!/bin/bash
if [ "${1:-}" = hosts ]; then
    echo '10.0.0.10 dc.dr.kodr.local'
    exit 0
fi
exec /usr/bin/getent "$@"
EOF
    cat > "$fake_bin/timeout" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/testparm" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/sssctl" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/sss_cache" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
if [ "${1:-}" = is-active ]; then
    echo inactive
    exit 1
fi
exit 0
EOF
    cat > "$fake_bin/klist" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -k ]; then
    echo 'host/fixture@DR.KODR.LOCAL'
fi
exit 0
EOF
    cat > "$fake_bin/hostname" << 'EOF'
#!/bin/bash
echo fixture
EOF
    cat > "$fake_bin/net" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$RENEW_NET_LOG"
if [ "${1:-}" = ads ] && [ "${2:-}" = keytab ] && [ "${3:-}" = create ]; then
    if [ "${RENEW_KEYTAB_FAIL:-0}" = 1 ]; then
        exit 1
    fi
    printf '%s\n' 'fresh-keytab' > "$DR_RENEWAL_KEYTAB"
fi
exit 0
EOF
    cat > "$fake_bin/sleep" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod 755 "$fake_bin"/*

    printf '%s\n' 'old-keytab' > "$keytab"
    chmod 600 "$keytab"
    now="$(date +%s)"
    printf '%s\n' "$now" > "$state_dir/machine-password-last-success"
    printf '%s\n' 'ads testjoin' > "$log"
    set +e
    PATH="$fake_bin:$PATH" \
        DR_RENEWAL_STATE_DIR="$state_dir" \
        DR_RENEWAL_KEYTAB="$keytab" \
        DR_RENEWAL_LOCK_DIR="$lock_dir" \
        RENEW_NET_LOG="$log" \
        "$helper" > "$TMP_DIR/renew-age-output" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        cat "$TMP_DIR/renew-age-output" >&2
        fail "recent renewal exits without rotation"
    fi
    ! grep -Fq 'changetrustpw' "$log" || fail "recent renewal does not rotate the password"
    assert_eq "old-keytab" "$(<"$keytab")" "recent renewal preserves the keytab"
    pass "reboot/recent timer run is age-gated without password rotation"

    printf '%s\n' 'old-keytab' > "$keytab"
    : > "$log"
    printf '%s\n' 0 > "$state_dir/machine-password-last-success"
    set +e
    PATH="$fake_bin:$PATH" RENEW_TIME_SYNC=0 \
        DR_RENEWAL_STATE_DIR="$state_dir" \
        DR_RENEWAL_KEYTAB="$keytab" \
        DR_RENEWAL_LOCK_DIR="$lock_dir" \
        RENEW_NET_LOG="$log" \
        "$helper" > "$TMP_DIR/renew-preflight-output" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "failed renewal preflight blocks rotation"
    ! grep -Fq 'changetrustpw' "$log" || fail "failed preflight never changes the password"
    assert_eq "old-keytab" "$(<"$keytab")" "failed preflight preserves the keytab"
    pass "failed renewal preflight leaves password and keytab untouched"

    printf '%s\n' 'old-keytab' > "$keytab"
    old=$((now - 3000000))
    printf '%s\n' "$old" > "$state_dir/machine-password-last-success"
    : > "$log"
    set +e
    PATH="$fake_bin:$PATH" RENEW_KEYTAB_FAIL=1 \
        DR_RENEWAL_STATE_DIR="$state_dir" \
        DR_RENEWAL_KEYTAB="$keytab" \
        DR_RENEWAL_LOCK_DIR="$lock_dir" \
        RENEW_NET_LOG="$log" \
        "$helper" > "$TMP_DIR/renew-partial-output" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "partial renewal failure is nonzero"
    grep -Fq 'changetrustpw -P' "$log" || fail "partial renewal changed the password before keytab failure"
    marker="$state_dir/machine-password-keytab-repair-needed"
    [ -f "$marker" ] || fail "partial renewal writes repair marker"
    assert_eq "$old" "$(<"$state_dir/machine-password-last-success")" "partial renewal does not update success timestamp"
    diagnostic="$(sed -n 's/^old_keytab_diagnostic=//p' "$marker")"
    [ -f "$diagnostic" ] || fail "partial renewal preserves old keytab as diagnostic evidence"
    pass "partial renewal enters explicit keytab repair state"

    : > "$log"
    PATH="$fake_bin:$PATH" \
        DR_RENEWAL_STATE_DIR="$state_dir" \
        DR_RENEWAL_KEYTAB="$keytab" \
        DR_RENEWAL_LOCK_DIR="$lock_dir" \
        RENEW_NET_LOG="$log" \
        "$helper" --repair-keytab > "$TMP_DIR/renew-repair-output" 2>&1 || fail "repair-keytab completes without rotation"
    ! grep -Fq 'changetrustpw' "$log" || fail "repair-keytab does not rotate the password again"
    [ ! -e "$marker" ] || fail "repair-keytab clears the repair marker"
    grep -Fq 'host/fixture@DR.KODR.LOCAL' <(PATH="$fake_bin:$PATH" klist -k "$keytab") || fail "repair-keytab produces a realm-valid keytab"
    pass "repair-keytab rebuilds from the current Samba secret without rotation"
}

test_kit_root_access_and_helpers() {
    local plan post_section launcher drip_support start_line trap_line
    plan="$(DR_JOIN_STATE_DIR="$TMP_DIR/kit-plan" bash -c "source '$SCRIPT'; render_kit_root_access_test_plan martin")"
    assert_contains "$plan" "Before launch, as the domain user" "KIT staged domain-user test"
    assert_contains "$plan" "Root KIT process" "KIT staged root list/execute test"
    assert_contains "$plan" "bash -n /mnt/x/DRTools/UA/Imaging/KIT-Linux/V10.00/x64/KIT.sh" "KIT staged root execution check"
    assert_contains "$plan" "dr-post-mount-provision --access-self-test" "KIT staged post-mount read test"
    assert_contains "$plan" "dr-launch-kit --access-self-test" "KIT staged launcher/runtime read test"
    assert_contains "$plan" "sec=krb5,cruid=<logged-in-domain-user-uid>,vers=3.0" "KIT staged ownership model"
    assert_contains "$plan" "KIT.sh creates /tmp/krb5cc_0" "KIT root-cache creation is staged"
    assert_contains "$plan" "cifs/<server>@DR.KODR.LOCAL" "DRIP CIFS ticket lifecycle is staged"
    assert_contains "$plan" "Deactivate the DRIP share" "DRIP deactivation is staged"

    post_section="$(sed -n '/cat > \/usr\/local\/sbin\/dr-post-mount-provision << EOF/,/chmod 755 \/usr\/local\/sbin\/dr-post-mount-provision/p' "$SCRIPT")"
    if printf '%s\n' "$post_section" | grep -Fq 'AUTOMOUNT_UNIT'; then
        fail "dr-post-mount-provision must not reference undefined AUTOMOUNT_UNIT"
    fi
    pass "generated post-mount helper has no undefined AUTOMOUNT_UNIT branch"

    launcher="$(<"$SCRIPT")"
    assert_contains "$launcher" 'find "$KIT_DIR" -type f -print0' "KIT launcher checks runtime files as root"

    drip_support="$(DR_JOIN_STATE_DIR="$TMP_DIR/kit-drip-support" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_drip_launcher_support")"
    printf '%s\n' "$drip_support" > "$TMP_DIR/drip-launcher-support.sh"
    bash -n "$TMP_DIR/drip-launcher-support.sh" || fail "generated DRIP launcher support syntax"
    pass "generated DRIP launcher support syntax"
    assert_contains "$drip_support" '/usr/local/sbin/dr-drip-search start' "KIT launcher starts configured DRIP search units"
    assert_contains "$drip_support" '/usr/local/sbin/dr-drip-search cleanup' "KIT launcher cleans configured DRIP search units"
    assert_contains "$drip_support" 'Configured DRIP search automounts could not be started' "KIT launcher blocks when DRIP search start fails"
    if printf '%s\n' "$drip_support" | grep -Eq '(/mnt/p|krb5cc_0)'; then
        fail "KIT launcher DRIP support must not own /mnt/p or /tmp/krb5cc_0"
    fi
    start_line="$(printf '%s\n' "$drip_support" | grep -n '/usr/local/sbin/dr-drip-search start' | cut -d: -f1)"
    trap_line="$(printf '%s\n' "$drip_support" | grep -n 'trap .*EXIT' | head -1 | cut -d: -f1)"
    [ "$trap_line" -lt "$start_line" ] || fail "KIT launcher must install cleanup traps before DRIP start"
    pass "KIT launcher preserves root-cache and /mnt/p ownership boundaries"
}

test_debian_kit_and_autofs_regression() {
    local output contract
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/debian-autofs-regression" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; render_autofs_master_maps; render_autofs_cifs_map")"
    assert_contains "$output" "/smb    /etc/auto.net.cifs" "Debian SMB autofs map preserved"
    assert_contains "$output" "/net    /etc/auto.net.cifs" "Debian NET autofs map preserved"
    assert_contains "$output" 'sec=krb5,cruid=${UID},vers=3.0' "Debian KIT/DRIP Kerberos ownership preserved"
    contract="$(DR_JOIN_STATE_DIR="$TMP_DIR/debian-kit-contract" bash -c "source '$SCRIPT'; render_debian_kit_compatibility_contract")"
    assert_contains "$contract" 'KRB5CCNAME=FILE:/tmp/krb5cc_<domain-uid>_<random>' "Ubuntu FILE cache contract preserved"
    assert_contains "$contract" 'DRIP /smb and /mnt/p: sec=krb5,cruid=0' "Ubuntu DRIP root cache ownership preserved"
    assert_contains "$contract" 'KIT /mnt/x: sec=krb5,cruid=<domain-user-uid>,vers=3.0' "Ubuntu KIT mount ownership preserved"
    assert_contains "$contract" 'KIT.sh: copy the user cache to /tmp/krb5cc_0' "Ubuntu KIT.sh root-cache contract preserved"
    assert_contains "$contract" 'remove on EXIT' "Ubuntu KIT.sh cache cleanup contract preserved"
    pass "Ubuntu KIT credential-cache and mount contract remains explicit"
}

test_debian_golden_renderers() {
    local candidate main_source expected_master expected_map expected_krb5 uid_var main_kerb
    main_source="$(git show main:domain-join-latest.sh)" || fail "main branch source is unavailable for golden comparison"
    uid_var='$'
    main_kerb="sec=krb5,cruid=$uid_var"'{UID}'",vers=3.0"
    expected_master=$'/smb    /etc/auto.net.cifs    --timeout=300 --ghost\n/net    /etc/auto.net.cifs    --timeout=300 --ghost'
    expected_map=$'#!/bin/bash\nkey="$1"\n[ -z "$key" ] && exit 1\n\nmkdir -p /etc/autofs.d\nmapfile="/etc/autofs.d/$key"\nif [ ! -f "$mapfile" ]; then\n    printf '\''*\\t-fstype=cifs,sec=krb5,cruid='\"$uid_var\"'{UID},vers=3.0\\t://%s/&\\n'\'' "$key" > "$mapfile"\nfi\n\nprintf -- '\''-fstype=autofs\\tfile:%s\\n'\'' "$mapfile"'
    expected_krb5=$'[libdefaults]\n    default_realm = DR.KODR.LOCAL\n    udp_preference_limit = 0\n    rdns = false\n\n[realms]\n    DR.KODR.LOCAL = {\n        kdc = dr.kodr.local\n        admin_server = dr.kodr.local\n    }\n\n[domain_realm]\n    .dr.kodr.local = DR.KODR.LOCAL\n    dr.kodr.local = DR.KODR.LOCAL'
    [[ "$main_source" == *"/smb    /etc/auto.net.cifs    --timeout=300 --ghost"* ]] || fail "main lacks Debian autofs master golden"
    [[ "$main_source" == *"$main_kerb"* ]] || fail "main lacks Debian Kerberos autofs golden"
    [[ "$main_source" == *'default_realm = $REALM'* ]] || fail "main lacks Debian Kerberos configuration golden"
    candidate="$(DR_JOIN_STATE_DIR="$TMP_DIR/golden-master" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; render_autofs_master_maps")"
    assert_eq "$expected_master" "$candidate" "Debian golden renderer unchanged: render_autofs_master_maps"
    candidate="$(DR_JOIN_STATE_DIR="$TMP_DIR/golden-map" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; render_autofs_cifs_map")"
    assert_contains "$candidate" 'sec=krb5,cruid=' "Debian golden map preserves Kerberos UID ownership"
    assert_contains "$candidate" 'vers=3.0' "Debian golden map preserves CIFS version"
    assert_contains "$candidate" 'printf --' "Debian golden map preserves autofs output"
    candidate="$(DR_JOIN_STATE_DIR="$TMP_DIR/golden-krb5" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; render_krb5_config")"
    assert_eq "$expected_krb5" "$candidate" "Debian golden renderer unchanged: render_krb5_config"
}

test_state_and_guard() {
    local state_dir="$TMP_DIR/state-machine" live_helper marker_dir state_text
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; OFFICE_CODE=EP1; save_state PREJOIN; grep -q '^STAGE=\"PREJOIN\"' \"\$STATE_FILE\""
    pass "state save transition"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; [ \"\$STAGE\" = PREJOIN ] && save_state POSTJOIN_COMPLETE; grep -q '^STAGE=\"POSTJOIN_COMPLETE\"' \"\$STATE_FILE\""
    pass "post-join state transition"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; PLATFORM_REPORT_ONLY=true; completed_workstation_rerun_guard --platform-report; [ \"\$FULL_RECONFIGURE\" = false ]"
    pass "completed state permits read-only report without refresh writes"
    DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; completed_workstation_rerun_guard --full-reconfigure; [ \"\$FULL_RECONFIGURE\" = true ]"
    pass "full-reconfigure override is recognized"

    state_text="$(<"$SCRIPT")"
    assert_contains "$state_text" 'save_state "POSTJOIN_AWAITING_LIVE_VALIDATION"' "static provisioning enters awaiting-live-validation state"
    if printf '%s\n' "$state_text" | grep -Fq 'save_state "POSTJOIN_COMPLETE"'; then
        fail "static provisioning must not write POSTJOIN_COMPLETE"
    fi
    pass "static provisioning cannot claim live completion"

    marker_dir="$state_dir/live-validation"
    mkdir -p "$marker_dir"
    for marker in DOMAIN_JOIN_COMPLETE IDENTITY_VALIDATED TOOLS_MOUNT_VALIDATED KIT_CREDENTIAL_LIFECYCLE_VALIDATED; do
        : > "$marker_dir/$marker"
    done
    if DRIP_REQUIRED=true DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; platform_live_validation_complete"; then
        fail "DRIP-required completion must wait for all DRIP states"
    fi
    for marker in DRIP_SEARCH_VALIDATED DRIP_ACTIVATION_VALIDATED DRIP_BOUNDED_READ_VALIDATED DRIP_CLEANUP_VALIDATED; do
        : > "$marker_dir/$marker"
    done
    DRIP_REQUIRED=true DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; platform_live_validation_complete"
    pass "DRIP-required completion gate requires every live phase"

    live_helper="$TMP_DIR/live-validation-helper"
    DRIP_REQUIRED=true DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; render_live_validation_helper" > "$live_helper"
    bash -n "$live_helper" || fail "generated live-validation helper syntax"
    assert_contains "$(<"$live_helper")" "--record STATE" "live-validation helper records explicit states"
    assert_contains "$(<"$live_helper")" "POSTJOIN_COMPLETE" "live-validation helper owns completion promotion"
    pass "live-validation helper is explicit and separate from static generation"
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
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/time-provider" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_time_provider(){ case \"\$1\" in active) echo systemd-timesyncd ;; enabled) echo systemd-timesyncd ;; esac; }; platform_capability_status time-sync")"
    assert_contains "$output" "PASS|time-sync|existing supported provider" "existing Arch time provider satisfies time-sync"
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
test_rebind_failure_rollback
test_drip_compatibility
test_machine_account_renewal
test_machine_account_renewal_behavior
test_kit_root_access_and_helpers
test_kit_cache_validation
test_debian_kit_and_autofs_regression
test_debian_golden_renderers
test_state_and_guard
test_modes
test_missing_capability
test_arch_backend_and_break_glass
test_missing_commands_and_packages
printf 'Completed %d tests\n' "$pass_count"
