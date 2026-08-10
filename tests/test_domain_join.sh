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

test_time_provider_and_timesyncd() {
    local fake_bin case_dir target output provider_text
    fake_bin="$TMP_DIR/time-fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
case "${1:-}" in
    is-active)
        [ "${TIME_ACTIVE:-none}" = "${!#}" ]
        ;;
    is-enabled)
        [ "${TIME_ENABLED:-none}" = "${!#}" ]
        ;;
    restart)
        printf '%s\n' "$*" >> "${TIME_SYSTEMCTL_LOG:?}"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/timedatectl" << 'EOF'
#!/bin/bash
case "${1:-}" in
    show)
        [ "${TIME_SYNC_BAD:-0}" != 1 ] && printf 'yes\n' || printf 'no\n'
        ;;
    timesync-status)
        [ "${TIME_SYNC_BAD:-0}" != 1 ] && printf 'Server: 10.59.4.201\nStratum: 3\n' || printf 'Server: time.google.com\n'
        ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/systemd-analyze" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${TIME_ANALYZE_LOG:?}"
exit 0
EOF
    chmod 755 "$fake_bin"/*

    provider_text="$(PATH="$fake_bin:$PATH" TIME_ACTIVE=systemd-timesyncd TIME_ENABLED=systemd-timesyncd TIME_SYSTEMCTL_LOG="$TMP_DIR/time-systemctl.log" TIME_ANALYZE_LOG="$TMP_DIR/time-analyze.log" DR_JOIN_STATE_DIR="$TMP_DIR/time-provider-report" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_capability_status time-sync; printf 'selected=%s active=%s enabled=%s\\n' \"\$(platform_time_provider selected)\" \"\$(platform_time_provider active)\" \"\$(platform_time_provider enabled)\"")"
    assert_contains "$provider_text" 'PASS|time-sync|existing selected provider is active or enabled (systemd-timesyncd)' "timesyncd is reported as the selected provider when chrony is absent"
    assert_contains "$provider_text" 'selected=systemd-timesyncd' "timesyncd selection is explicit"
    if printf '%s\n' "$provider_text" | grep -Fq chrony; then
        fail "timesyncd capability reporting must not label the provider chrony"
    fi
    pass "timesyncd capability reporting uses the actual selected provider"

    output="$(PATH="$fake_bin:$PATH" TIME_ACTIVE=chronyd TIME_ENABLED=chronyd TIME_SYSTEMCTL_LOG="$TMP_DIR/chrony-systemctl.log" TIME_ANALYZE_LOG="$TMP_DIR/chrony-analyze.log" DR_JOIN_STATE_DIR="$TMP_DIR/chrony-report" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_capability_status time-sync; platform_time_provider selected")"
    assert_contains "$output" 'PASS|time-sync|existing selected provider is active or enabled (chronyd)' "chrony is reported when chrony is selected"
    assert_contains "$output" 'chronyd' "chrony selected provider is visible"
    pass "chrony capability reporting remains available"

    output="$(PATH="$fake_bin:$PATH" TIME_ACTIVE=none TIME_ENABLED=none TIME_SYSTEMCTL_LOG="$TMP_DIR/no-time-systemctl.log" TIME_ANALYZE_LOG="$TMP_DIR/no-time-analyze.log" DR_JOIN_STATE_DIR="$TMP_DIR/no-time-report" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_time_provider selected")"
    assert_eq "none" "$output" "no active or enabled time provider is reported as none"

    output="$(PATH="$fake_bin:$PATH" TIME_ACTIVE=systemd-timesyncd TIME_ENABLED=systemd-timesyncd TIME_SYSTEMCTL_LOG="$TMP_DIR/both-systemctl.log" TIME_ANALYZE_LOG="$TMP_DIR/both-analyze.log" DR_JOIN_STATE_DIR="$TMP_DIR/both-report" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_time_provider selected")"
    assert_eq "systemd-timesyncd" "$output" "timesyncd remains selected when chrony is also installed but not selected"

    case_dir="$TMP_DIR/timesyncd-config"
    target="$case_dir/90-dr-domain.conf"
    mkdir -p "$case_dir"
    printf '%s\n' '[Time]' 'NTP=time.cloudflare.com' 'FallbackNTP=time.google.com' > "$target"
    : > "$case_dir/systemctl.log"
    : > "$case_dir/analyze.log"
    PATH="$fake_bin:$PATH" TIME_ACTIVE=systemd-timesyncd TIME_ENABLED=systemd-timesyncd \
        TIME_SYSTEMCTL_LOG="$case_dir/systemctl.log" TIME_ANALYZE_LOG="$case_dir/analyze.log" \
        DR_TIMESYNCD_DROPIN="$target" OFFICE_CODE=EP1 DR_TIME_SYNC_RETRIES=1 DR_TIME_SYNC_RETRY_DELAY=0 \
        DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; OFFICE_CODE=EP1; platform_configure_timesyncd force" || fail "timesyncd configuration succeeds with corporate source"
    assert_contains "$(<"$target")" 'NTP=' "timesyncd override resets the accumulated NTP list"
    assert_contains "$(<"$target")" 'NTP=10.59.4.201 10.59.4.202' "timesyncd override supplies EP1 corporate sources"
    assert_contains "$(<"$target")" 'FallbackNTP=' "timesyncd override resets fallback sources"
    if grep -Fq 'time.cloudflare.com' "$target"; then
        fail "timesyncd override must not retain vendor public NTP"
    fi
    assert_contains "$(<"$case_dir/systemctl.log")" 'restart systemd-timesyncd' "timesyncd configuration restarts only systemd-timesyncd"
    assert_contains "$(<"$case_dir/analyze.log")" 'cat-config systemd/timesyncd.conf' "timesyncd merged configuration is validated"
    [ -n "$(find "$case_dir" -maxdepth 1 -name '90-dr-domain.conf.domain-join.bak.*' -print -quit)" ] || fail "timesyncd override creates an /etc-style backup"
    pass "Arch timesyncd override resets vendor lists, validates merged config, and backs up the drop-in"

    : > "$case_dir/systemctl.log"
    PATH="$fake_bin:$PATH" TIME_ACTIVE=systemd-timesyncd TIME_ENABLED=systemd-timesyncd \
        TIME_SYSTEMCTL_LOG="$case_dir/systemctl.log" TIME_ANALYZE_LOG="$case_dir/analyze.log" \
        DR_TIMESYNCD_DROPIN="$target" OFFICE_CODE=EP1 DR_TIME_SYNC_RETRIES=1 DR_TIME_SYNC_RETRY_DELAY=0 \
        DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; OFFICE_CODE=EP1; platform_configure_timesyncd force" || fail "idempotent timesyncd configuration succeeds"
    if grep -Fq 'restart systemd-timesyncd' "$case_dir/systemctl.log"; then
        fail "idempotent timesyncd configuration must not restart the service"
    fi
    pass "idempotent timesyncd configuration skips unnecessary restart"

    printf '%s\n' '[Time]' 'NTP=old.example' 'FallbackNTP=old.example' > "$target"
    set +e
    PATH="$fake_bin:$PATH" TIME_ACTIVE=systemd-timesyncd TIME_ENABLED=systemd-timesyncd TIME_SYNC_BAD=1 \
        TIME_SYSTEMCTL_LOG="$case_dir/systemctl-failure.log" TIME_ANALYZE_LOG="$case_dir/analyze-failure.log" \
        DR_TIMESYNCD_DROPIN="$target" OFFICE_CODE=EP1 DR_TIME_SYNC_RETRIES=1 DR_TIME_SYNC_RETRY_DELAY=0 \
        DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; OFFICE_CODE=EP1; platform_configure_timesyncd force" >/dev/null 2>&1
    local timesync_rc=$?
    set -e
    [ "$timesync_rc" -ne 0 ] || fail "timesyncd configuration fails closed when synchronization is not achieved"
    assert_contains "$(<"$target")" 'NTP=old.example' "failed timesyncd configuration restores the previous drop-in"
    pass "timesyncd synchronization failure restores the previous drop-in"
}

test_dns_preservation_and_fallback() {
    local fake_bin case_dir output
    fake_bin="$TMP_DIR/dns-fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/dig" << 'EOF'
#!/bin/bash
if [ "${DNS_TEST_MODE:-current}" = current ] && [[ "$*" != *@* ]]; then
    printf '0 100 88 dc.dr.kodr.local.\n'
elif [ "${DNS_TEST_MODE:-current}" = fallback ] && [[ "$*" == *@10.59.4.201* || "$*" == *@10.59.4.202* ]]; then
    printf '0 100 88 dc.dr.kodr.local.\n'
fi
EOF
    cat > "$fake_bin/nmcli" << 'EOF'
#!/bin/bash
case "$*" in
    *"connection show --active"*) printf 'Corp:wlan0\n' ;;
    *"-g ipv4.dns-search"*) printf '%s\n' "${NM_DNS_SEARCH:-}" ;;
    *"-g ipv4.dns connection"*) printf '%s\n' "${NM_DNS:-}" ;;
    *"-g ipv4.ignore-auto-dns"*) printf '%s\n' "${NM_IGNORE_AUTO_DNS:-no}" ;;
    *"connection modify"*|*"connection up"*) printf '%s\n' "$*" >> "${DNS_NMCLI_LOG:?}" ;;
    *"device show"*) ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
case "${1:-}" in
    is-active) exit 1 ;;
    restart|daemon-reload) printf '%s\n' "$*" >> "${DNS_SYSTEMCTL_LOG:?}" ;;
    *) exit 0 ;;
esac
EOF
    chmod 755 "$fake_bin"/*

    case_dir="$TMP_DIR/dns-fallback"
    : > "$case_dir.log"
    output="$(PATH="$fake_bin:$PATH" DNS_TEST_MODE=fallback NM_DNS=192.168.0.1 NM_DNS_SEARCH= DNS_NMCLI_LOG="$case_dir.log" DNS_SYSTEMCTL_LOG="$case_dir.systemctl.log" DR_JOIN_STATE_DIR="$case_dir-state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; OFFICE_CODE=EP1; backup_config_file(){ :; }; configure_dns_servers; configure_dns_search_domains")"
    assert_contains "$output" 'reachable office-specific fallback DNS servers' "home/router DNS failure selects the EP1 fallback policy"
    assert_contains "$(<"$case_dir.log")" 'ipv4.ignore-auto-dns yes ipv4.dns 10.59.4.201 10.59.4.202' "fallback DNS disables DHCP DNS replacement safely"
    assert_contains "$(<"$case_dir.log")" 'ipv4.dns-search' "fallback DNS path adds the AD search configuration"
    pass "office-specific DNS fallback is applied only after current AD discovery fails"

    case_dir="$TMP_DIR/dns-preserve"
    : > "$case_dir.log"
    output="$(PATH="$fake_bin:$PATH" DNS_TEST_MODE=current NM_DNS='10.59.4.201 10.59.4.202' NM_DNS_SEARCH='dr.kodr.local,corp.eddom.org' NM_IGNORE_AUTO_DNS=yes DNS_NMCLI_LOG="$case_dir.log" DNS_SYSTEMCTL_LOG="$case_dir.systemctl.log" DR_JOIN_STATE_DIR="$case_dir-state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; OFFICE_CODE=EP1; backup_config_file(){ :; }; configure_dns_servers; configure_dns_search_domains")"
    assert_contains "$output" 'Preserving already-valid AD DNS configuration' "working explicit DNS is preserved"
    [ ! -s "$case_dir.log" ] || fail "already-working explicit DNS must not be modified on rerun"
    pass "already-working explicit corporate DNS and search domains remain unchanged"

    case_dir="$TMP_DIR/debian-dns-regression"
    : > "$case_dir.log"
    output="$(PATH="$fake_bin:$PATH" DNS_TEST_MODE=current NM_DNS='10.59.4.201 10.59.4.202' NM_DNS_SEARCH='dr.kodr.local' NM_IGNORE_AUTO_DNS=yes DNS_NMCLI_LOG="$case_dir.log" DNS_SYSTEMCTL_LOG="$case_dir.systemctl.log" DR_JOIN_STATE_DIR="$case_dir-state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; OFFICE_CODE=EP1; backup_config_file(){ :; }; configure_dns_servers")"
    assert_contains "$output" 'Keeping DHCP/VPN DNS servers' "Debian keeps its existing DHCP/VPN DNS behavior"
    [ ! -s "$case_dir.log" ] || fail "Debian DNS regression fixture must not use the Arch fallback path"
    pass "Debian DNS behavior remains unchanged"
}

test_office_argument_workflow() {
    local state_dir output rc
    output="$(printf 'EP1\n' | DR_JOIN_STATE_DIR="$TMP_DIR/office-prompt" bash -c "source '$SCRIPT'; parse_args; printf 'office=%s\\n' \"\$OFFICE_CODE\"" 2>&1)"
    assert_contains "$output" 'Enter the office code' "missing office state uses the interactive prompt"
    assert_contains "$output" 'office=EP1' "interactive office code is accepted"

    state_dir="$TMP_DIR/office-state"
    mkdir -p "$state_dir"
    printf '%s\n' 'OFFICE_CODE="EP1"' > "$state_dir/state"
    output="$(DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; parse_args; printf 'office=%s\\n' \"\$OFFICE_CODE\"")"
    assert_contains "$output" 'office=EP1' "persisted office code is reused without prompting"
    output="$(DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; parse_args EP1; printf 'office=%s\\n' \"\$OFFICE_CODE\"")"
    assert_contains "$output" 'office=EP1' "repeating the persisted office code is idempotent"
    output="$(DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; parse_args --preflight EP1; printf 'office=%s preflight=%s\\n' \"\$OFFICE_CODE\" \"\$PREFLIGHT_ONLY\"")"
    assert_contains "$output" 'office=EP1 preflight=true' "office code after a mode flag is accepted"
    output="$(DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; parse_args EP1 --dry-run; printf 'office=%s dry=%s\\n' \"\$OFFICE_CODE\" \"\$DRY_RUN_ONLY\"")"
    assert_contains "$output" 'office=EP1 dry=true' "office code before a mode flag is accepted"

    set +e
    output="$(DR_JOIN_STATE_DIR="$state_dir" bash -c "source '$SCRIPT'; load_state; parse_args PL1" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "conflicting positional office code is rejected"
    assert_contains "$output" 'conflicts with persisted office code EP1' "conflicting office code requires explicit resolution"
    pass "office-code parsing is idempotent and conflict-safe"
}

test_hostname_collision_and_recovery() {
    local fake_bin helper case_dir output rc case_name occupied race_host
    fake_bin="$TMP_DIR/hostname-fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/hostnamectl" << 'EOF'
#!/bin/bash
case "${1:-}" in
    --static) printf '%s\n' "${FAKE_HOSTNAME:?}" ;;
    set-hostname) printf '%s\n' "$*" >> "${HOSTNAMECTL_LOG:?}" ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -u ]; then printf '0\n'; else /usr/bin/id "$@"; fi
EOF
    cat > "$fake_bin/dig" << 'EOF'
#!/bin/bash
printf '0 100 389 dc.dr.kodr.local.\n'
EOF
    cat > "$fake_bin/ldapsearch" << 'EOF'
#!/bin/bash
candidate=""
for ((index = 1; index <= $#; index++)); do
    if [ "${!index}" = -H ]; then
        next_index=$((index + 1))
        printf '%s\n' "${!next_index}" >> "${LDAP_QUERY_LOG:?}"
    fi
done
if [ -n "${LDAP_ENV_LOG:-}" ]; then
    printf '%s|%s\n' "${KRB5_CONFIG:-<unset>}" "${KRB5CCNAME:-<unset>}" >> "$LDAP_ENV_LOG"
fi
for arg in "$@"; do
    if [[ "$arg" == *sAMAccountName=* ]]; then
        candidate="${arg#*sAMAccountName=}"
        candidate="${candidate%%)*}"
        candidate="${candidate%\$}"
    fi
done
counter_file="${LDAP_COUNTER_DIR:?}/$candidate"
count=0
if [ -f "$counter_file" ]; then count="$(<"$counter_file")"; fi
count=$((count + 1))
printf '%s\n' "$count" > "$counter_file"
if [ -n "${LDAP_FAILURE_RC:-}" ]; then
    printf 'simulated ldap failure\n' >&2
    exit "$LDAP_FAILURE_RC"
fi
if [ "${LDAP_FAIL_FINAL:-0}" = 1 ] && [ "$candidate" = EP-CR-KIT-05 ] && [ "$count" -ge 2 ]; then
    printf 'simulated pinned DC became unreachable\n' >&2
    exit 1
fi
if [[ " ${AD_OCCUPIED:-} " == *" $candidate "* ]] || { [ "$candidate" = "${RACE_HOST:-}" ] && [ "$count" -ge 2 ]; }; then
    printf 'dn: CN=%s,OU=Computers,DC=dr,DC=kodr,DC=local\nsAMAccountName: %s$\ndNSHostName: %s.dr.kodr.local\ndescription: Existing fixture object\nwhenCreated: 20260706160422.0Z\n' "$candidate" "$candidate" "${candidate,,}"
fi
EOF
    cat > "$fake_bin/timeout" << 'EOF'
#!/bin/bash
if [ -n "${FAKE_TIMEOUT_RC:-}" ]; then
    printf 'simulated timeout from fixture\n' >&2
    exit "$FAKE_TIMEOUT_RC"
fi
exec /usr/bin/timeout "$@"
EOF
    cat > "$fake_bin/kinit" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/kdestroy" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/klist" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -k ]; then
    printf '  1 host/%s@DR.KODR.LOCAL\n' "${FAKE_HOSTNAME:?}"
    exit 0
fi
exit 1
EOF
    cat > "$fake_bin/testparm" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/net" << 'EOF'
#!/bin/bash
if [[ "$*" == *"ads info"* ]]; then
    printf '%s\n' \
        'LDAP server: 10.25.1.121' \
        'LDAP server name: US1P1OINFMAD004.dr.kodr.local' \
        'Realm: DR.KODR.LOCAL' \
        'LDAP port: 389' \
        'KDC server: 10.25.1.121'
    exit 0
fi
if [[ "$*" == *"ads lookup"* ]]; then
    if [ "${NET_DC_MODE:-good}" = unusable ]; then
        printf '%s\n' \
            'Domain Controller: US1P1OINFMAD004.dr.kodr.local' \
            'Server Site Name: EP' \
            'Client Site Name: EP' \
            'Is the closest DC: yes' \
            'Is writable: no' \
            'Is an LDAP server: yes'
    else
        printf '%s\n' \
            'Domain Controller: US1P1OINFMAD004.dr.kodr.local' \
            'Server Site Name: EP' \
            'Client Site Name: EP' \
            'Is the closest DC: yes' \
            'Is writable: yes' \
            'Is an LDAP server: yes'
    fi
    exit 0
fi
if [[ "$*" == *"ads join"* ]]; then
    printf '%s\n' "$*" >> "${NET_JOIN_LOG:?}"
    exit 0
fi
if [[ "$*" == *"ads keytab create"* ]]; then
    : > "${FAKE_KEYTAB:?}"
    exit 0
fi
if [[ "$*" == *"ads testjoin"* ]]; then
    [ "${NET_TESTJOIN_OK:-0}" = 1 ]
    exit $?
fi
exit 0
EOF
    chmod 755 "$fake_bin"/*

    helper="$TMP_DIR/dr-domain-admin-join"
    DR_JOIN_STATE_DIR="$TMP_DIR/admin-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; OFFICE_CODE=EP1; render_arch_domain_admin_join_helper" > "$helper"
    chmod 755 "$helper"
    bash -n "$helper" || fail "generated Arch admin helper syntax"
    if grep -Eq 'discover_ldap_dcs|_ldap[.]_tcp|dig[[:space:]]|host[[:space:]]+-t[[:space:]]+SRV' "$helper"; then
        fail "Arch admin helper must not enumerate global LDAP SRV records"
    fi
    pass "Arch admin helper uses Samba site-aware DC selection instead of global LDAP SRV enumeration"
    if grep -Fq 'KRB5_CONFIG=/tmp/dr-domain-admin-krb5.conf' "$helper"; then
        fail "Arch LDAP collision queries must use the workstation Kerberos configuration"
    fi
    grep -Fq 'timeout 15s' "$helper" || fail "Arch LDAP collision queries retain the bounded timeout"
    grep -Fq 'ldapsearch -LLL -Q -Y GSSAPI -N' "$helper" || fail "Arch LDAP collision queries use GSSAPI ldapsearch"
    pass "Arch LDAP collision queries use the normal Kerberos environment"

    for case_name in contiguous sparse; do
        case_dir="$TMP_DIR/hostname-$case_name"
        mkdir -p "$case_dir/counters"
        printf '127.0.1.1 ep-cr-kit-01\n' > "$case_dir/hosts"
        : > "$case_dir/smb.conf"
        : > "$case_dir/join.log"
        if [ "$case_name" = contiguous ]; then
            occupied='EP-CR-KIT-01 EP-CR-KIT-02 EP-CR-KIT-03 EP-CR-KIT-04'
            race_host='EP-CR-KIT-05'
        else
            occupied='EP-CR-KIT-01 EP-CR-KIT-02 EP-CR-KIT-04'
            race_host='EP-CR-KIT-03'
        fi
        set +e
        output="$(printf 'admin\n' | PATH="$fake_bin:$PATH" FAKE_HOSTNAME=ep-cr-kit-01 HOSTNAMECTL_LOG="$case_dir/hostname.log" NET_JOIN_LOG="$case_dir/join.log" LDAP_COUNTER_DIR="$case_dir/counters" LDAP_QUERY_LOG="$case_dir/ldap.log" AD_OCCUPIED="$occupied" RACE_HOST="$race_host" DR_ADMIN_STATE_DIR="$case_dir/state" DR_ADMIN_HOSTS_FILE="$case_dir/hosts" DR_ADMIN_SMB_CONF="$case_dir/smb.conf" DR_ADMIN_KEYTAB="$case_dir/krb5.keytab" DR_ADMIN_SECRETS_TDB="$case_dir/secrets.tdb" "$helper" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "$case_name hostname race must block the join"
        [ ! -s "$case_dir/join.log" ] || fail "$case_name collision gate must prevent net ads join"
        assert_contains "$output" "${race_host,,}" "$case_name allocator identifies the next AD candidate"
        assert_contains "$output" 'No domain join was attempted' "$case_name final collision gate blocks safely"
        pass "$case_name sparse/contiguous AD allocation race is fail-closed"
    done

    case_dir="$TMP_DIR/hostname-pinned-success"
    mkdir -p "$case_dir/counters"
    printf '127.0.1.1 ep-cr-kit-01\n' > "$case_dir/hosts"
    : > "$case_dir/smb.conf" "$case_dir/join.log" "$case_dir/ldap.log"
    set +e
    output="$(printf 'admin\n' | PATH="$fake_bin:$PATH" KRB5_CONFIG=/etc/krb5.conf KRB5CCNAME=FILE:/tmp/krb5cc_0 LDAP_ENV_LOG="$case_dir/ldap-env.log" FAKE_HOSTNAME=ep-cr-kit-01 HOSTNAMECTL_LOG="$case_dir/hostname.log" NET_JOIN_LOG="$case_dir/join.log" LDAP_COUNTER_DIR="$case_dir/counters" LDAP_QUERY_LOG="$case_dir/ldap.log" FAKE_KEYTAB="$case_dir/krb5.keytab" AD_OCCUPIED='EP-CR-KIT-01 EP-CR-KIT-02 EP-CR-KIT-03 EP-CR-KIT-04' NET_TESTJOIN_OK=1 DR_ADMIN_STATE_DIR="$case_dir/state" DR_ADMIN_HOSTS_FILE="$case_dir/hosts" DR_ADMIN_SMB_CONF="$case_dir/smb.conf" DR_ADMIN_KEYTAB="$case_dir/krb5.keytab" DR_ADMIN_SECRETS_TDB="$case_dir/secrets.tdb" "$helper" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "pinned absent candidate should complete the fixture join"
    assert_contains "$output" 'Pinned site-aware writable LDAP DC' "Samba site-aware DC selection is reported"
    grep -Fq 'ldap://US1P1OINFMAD004.dr.kodr.local' "$case_dir/ldap.log" || fail "all LDAP checks use the pinned EP DC"
    if grep -Eq 'auap1oinfmad001|caap1oinfmad001|us4p1oinfmad001' "$case_dir/ldap.log"; then
        fail "unreachable global DCs must not be queried"
    fi
    grep -Fq 'ads join -S US1P1OINFMAD004.dr.kodr.local --use-kerberos=required' "$case_dir/join.log" || fail "net ads join must target the exact selected DC"
    grep -Fq '/etc/krb5.conf|FILE:/tmp/krb5cc_0' "$case_dir/ldap-env.log" || fail "LDAP query must inherit the existing Kerberos environment"
    grep -Fq 'set-hostname ep-cr-kit-05' "$case_dir/hostname.log" || fail "occupied NEW_JOIN object must not be reused"
    assert_contains "$output" 'ep-cr-kit-05' "pinned absent candidate proceeds to join"
    pass "pinned writable EP DC is used for LDAP checks and net ads join"

    case_dir="$TMP_DIR/hostname-pinned-final-unreachable"
    mkdir -p "$case_dir/counters"
    printf '127.0.1.1 ep-cr-kit-01\n' > "$case_dir/hosts"
    : > "$case_dir/smb.conf" "$case_dir/join.log" "$case_dir/ldap.log"
    set +e
    output="$(printf 'admin\n' | PATH="$fake_bin:$PATH" FAKE_HOSTNAME=ep-cr-kit-01 HOSTNAMECTL_LOG="$case_dir/hostname.log" NET_JOIN_LOG="$case_dir/join.log" LDAP_COUNTER_DIR="$case_dir/counters" LDAP_QUERY_LOG="$case_dir/ldap.log" AD_OCCUPIED='EP-CR-KIT-01 EP-CR-KIT-02 EP-CR-KIT-03 EP-CR-KIT-04' LDAP_FAIL_FINAL=1 DR_ADMIN_STATE_DIR="$case_dir/state" DR_ADMIN_HOSTS_FILE="$case_dir/hosts" DR_ADMIN_SMB_CONF="$case_dir/smb.conf" DR_ADMIN_KEYTAB="$case_dir/krb5.keytab" DR_ADMIN_SECRETS_TDB="$case_dir/secrets.tdb" "$helper" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "pinned DC failure before final collision check must block"
    [ ! -s "$case_dir/join.log" ] || fail "pinned DC failure must prevent net ads join"
    assert_contains "$output" 'AD query on pinned DC' "pinned DC failure is explicit"
    pass "pinned DC becoming unreachable fails closed before join"

    case_dir="$TMP_DIR/hostname-no-writable-dc"
    mkdir -p "$case_dir/counters"
    printf '127.0.1.1 ep-cr-kit-01\n' > "$case_dir/hosts"
    : > "$case_dir/smb.conf" "$case_dir/join.log" "$case_dir/ldap.log"
    set +e
    output="$(printf 'admin\n' | PATH="$fake_bin:$PATH" FAKE_HOSTNAME=ep-cr-kit-01 HOSTNAMECTL_LOG="$case_dir/hostname.log" NET_JOIN_LOG="$case_dir/join.log" LDAP_COUNTER_DIR="$case_dir/counters" LDAP_QUERY_LOG="$case_dir/ldap.log" NET_DC_MODE=unusable DR_ADMIN_STATE_DIR="$case_dir/state" DR_ADMIN_HOSTS_FILE="$case_dir/hosts" DR_ADMIN_SMB_CONF="$case_dir/smb.conf" DR_ADMIN_KEYTAB="$case_dir/krb5.keytab" DR_ADMIN_SECRETS_TDB="$case_dir/secrets.tdb" "$helper" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "no writable DC must block the helper"
    [ ! -s "$case_dir/join.log" ] || fail "no writable DC must prevent net ads join"
    assert_contains "$output" 'not confirmed writable' "no suitable writable DC is a hard blocker"
    pass "absence of a suitable writable LDAP DC fails closed"

    case_dir="$TMP_DIR/hostname-ldap-timeout"
    mkdir -p "$case_dir/counters"
    printf '127.0.1.1 ep-cr-kit-01\n' > "$case_dir/hosts"
    : > "$case_dir/smb.conf" "$case_dir/join.log" "$case_dir/ldap.log"
    set +e
    output="$(printf 'admin\n' | PATH="$fake_bin:$PATH" FAKE_HOSTNAME=ep-cr-kit-01 HOSTNAMECTL_LOG="$case_dir/hostname.log" NET_JOIN_LOG="$case_dir/join.log" LDAP_COUNTER_DIR="$case_dir/counters" LDAP_QUERY_LOG="$case_dir/ldap.log" FAKE_TIMEOUT_RC=124 AD_OCCUPIED='EP-CR-KIT-01' DR_ADMIN_STATE_DIR="$case_dir/state" DR_ADMIN_HOSTS_FILE="$case_dir/hosts" DR_ADMIN_SMB_CONF="$case_dir/smb.conf" DR_ADMIN_KEYTAB="$case_dir/krb5.keytab" DR_ADMIN_SECRETS_TDB="$case_dir/secrets.tdb" "$helper" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "LDAP timeout must block the helper"
    [ ! -s "$case_dir/join.log" ] || fail "LDAP timeout must prevent net ads join"
    assert_contains "$output" 'timed out after 15 seconds' "LDAP timeout has a specific diagnostic"
    assert_contains "$output" 'No domain join was attempted' "LDAP timeout preserves the no-join diagnostic"
    pass "LDAP timeout blocks the pinned join without invoking net ads join"

    case_dir="$TMP_DIR/hostname-ldap-failure"
    mkdir -p "$case_dir/counters"
    printf '127.0.1.1 ep-cr-kit-01\n' > "$case_dir/hosts"
    : > "$case_dir/smb.conf" "$case_dir/join.log" "$case_dir/ldap.log"
    set +e
    output="$(printf 'admin\n' | PATH="$fake_bin:$PATH" FAKE_HOSTNAME=ep-cr-kit-01 HOSTNAMECTL_LOG="$case_dir/hostname.log" NET_JOIN_LOG="$case_dir/join.log" LDAP_COUNTER_DIR="$case_dir/counters" LDAP_QUERY_LOG="$case_dir/ldap.log" LDAP_FAILURE_RC=68 AD_OCCUPIED='EP-CR-KIT-01' DR_ADMIN_STATE_DIR="$case_dir/state" DR_ADMIN_HOSTS_FILE="$case_dir/hosts" DR_ADMIN_SMB_CONF="$case_dir/smb.conf" DR_ADMIN_KEYTAB="$case_dir/krb5.keytab" DR_ADMIN_SECRETS_TDB="$case_dir/secrets.tdb" "$helper" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "non-timeout LDAP failure must block the helper"
    [ ! -s "$case_dir/join.log" ] || fail "non-timeout LDAP failure must prevent net ads join"
    assert_contains "$output" 'failed with exit status 68' "non-timeout LDAP status is reported"
    assert_contains "$output" 'simulated ldap failure' "captured LDAP diagnostics are preserved"
    assert_contains "$output" 'No domain join was attempted' "non-timeout LDAP failure preserves the no-join diagnostic"
    pass "non-timeout LDAP failure blocks the pinned join with captured diagnostics"

    case_dir="$TMP_DIR/stale-state"
    mkdir -p "$case_dir"
    printf '%s\n' \
        'SCRIPT_VERSION="1.1.0"' \
        'STAGE="DOMAIN_JOIN_COMPLETE"' \
        'OFFICE_CODE="EP1"' \
        'DOMAIN="dr.kodr.local"' \
        'TARGET_HOSTNAME="ep-cr-kit-01"' \
        'DOMAIN_SUDO_USER="martin.campetta"' \
        'DR_TOOLS_MOUNT_CRUID="1000"' > "$case_dir/state"
    output="$(PATH="$fake_bin:$PATH" FAKE_HOSTNAME=ep-cr-kit-05 DR_JOIN_STATE_DIR="$case_dir" DR_LOCAL_KEYTAB="$case_dir/krb5.keytab" DR_SAMBA_SECRETS_TDB="$case_dir/secrets.tdb" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; load_state; state_is_postjoin_complete && exit 1 || true; recover_stale_state; grep -E '^(STAGE|TARGET_HOSTNAME|JOIN_LIFECYCLE|DOMAIN_SUDO_USER|DR_TOOLS_MOUNT_CRUID)=' \"\$STATE_FILE\"")"
    assert_contains "$output" 'STAGE="WAITING_FOR_ADMIN"' "stale completed state returns to pre-admin stage"
    assert_contains "$output" 'TARGET_HOSTNAME="ep-cr-kit-05"' "stale recovery records the current candidate hostname"
    assert_contains "$output" 'JOIN_LIFECYCLE="RECOVERY_REQUIRED"' "stale recovery lifecycle is explicit"
    if grep -Eq 'DOMAIN_SUDO_USER="martin.campetta"|DR_TOOLS_MOUNT_CRUID="1000"' "$case_dir/state"; then
        fail "stale recovery must clear unresolved user and guessed local UID state"
    fi
    pass "exact stale persisted-state contradiction is detected and recovered"
}

test_cifs_kernel_and_mount_gates() {
    local fake_bin case_dir output helper
    fake_bin="$TMP_DIR/cifs-fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/uname" << 'EOF'
#!/bin/bash
[ "${1:-}" = -r ] && printf '7.1.2-2-cachyos\n' || /usr/bin/uname "$@"
EOF
    cat > "$fake_bin/modinfo" << 'EOF'
#!/bin/bash
[ "${CIFS_MODINFO_OK:-0}" = 1 ]
EOF
    chmod 755 "$fake_bin"/*

    case_dir="$TMP_DIR/cifs-kernel"
    mkdir -p "$case_dir/modules/7.1.2-2-cachyos"
    printf 'nodev\tcifs\n' > "$case_dir/filesystems"
    output="$(PATH="$fake_bin:$PATH" DR_CIFS_MODULES_ROOT="$case_dir/modules" DR_CIFS_PROC_FILESYSTEMS="$case_dir/filesystems" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_cifs_kernel")"
    assert_contains "$output" 'PASS CIFS is built into the running kernel 7.1.2-2-cachyos' "CIFS built-in capability passes"

    : > "$case_dir/filesystems"
    output="$(PATH="$fake_bin:$PATH" CIFS_MODINFO_OK=1 DR_CIFS_MODULES_ROOT="$case_dir/modules" DR_CIFS_PROC_FILESYSTEMS="$case_dir/filesystems" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_cifs_kernel")"
    assert_contains "$output" 'PASS CIFS module is available for the running kernel' "loadable CIFS module capability passes"

    set +e
    output="$(PATH="$fake_bin:$PATH" DR_CIFS_MODULES_ROOT="$case_dir/modules" DR_CIFS_PROC_FILESYSTEMS="$case_dir/filesystems" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_cifs_kernel || true; printf 'blockers=%s\n' \"\$PREFLIGHT_BLOCKERS\"")"
    set -e
    assert_contains "$output" 'BLOCKED CIFS is neither built into nor loadable' "missing CIFS module is blocked"

    case_dir="$TMP_DIR/cifs-missing-tree"
    mkdir -p "$case_dir"
    set +e
    output="$(PATH="$fake_bin:$PATH" DR_CIFS_MODULES_ROOT="$case_dir/modules" DR_CIFS_PROC_FILESYSTEMS="$case_dir/filesystems" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PREFLIGHT_BLOCKERS=0; platform_validate_cifs_kernel || true")"
    set -e
    assert_contains "$output" 'Running kernel 7.1.2-2-cachyos has no matching module tree' "missing running-kernel module tree is a blocker"
    assert_contains "$output" 'Reboot into the installed kernel before continuing' "kernel update recovery guidance is explicit"

    helper="$TMP_DIR/mount-kit-tools-authoritative"
    DR_JOIN_STATE_DIR="$TMP_DIR/mount-helper-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; render_arch_tools_mount_helper 1001" > "$helper"
    bash -n "$helper" || fail "generated mount helper with findmnt validation is syntactically valid"
    assert_contains "$(<"$helper")" 'findmnt --noheadings --raw --target' "mount helper uses authoritative findmnt validation"
    assert_contains "$(<"$helper")" 'FSTYPE,SOURCE' "mount helper checks filesystem type and source"

    case_dir="$TMP_DIR/mount-authority"
    mkdir -p "$case_dir/bin"
    cat > "$case_dir/bin/findmnt" << 'EOF'
#!/bin/bash
if [ "${FINDMNT_CIFS_OK:-0}" = 1 ]; then
    printf 'cifs //dr-ep1-tools/Tools\n'
else
    printf 'ext4 /dev/nvme0n1p2\n'
fi
EOF
    chmod 755 "$case_dir/bin/findmnt"
    output="$(PATH="$case_dir/bin:$PATH" FINDMNT_CIFS_OK=1 bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; platform_tools_mount_is_authoritative" 2>&1)" || fail "authoritative CIFS fixture should pass"
    pass "CIFS mount validation accepts the expected source and filesystem"
    set +e
    PATH="$case_dir/bin:$PATH" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; platform_tools_mount_is_authoritative" >/dev/null 2>&1
    local mount_rc=$?
    set -e
    [ "$mount_rc" -ne 0 ] || fail "local mountpoint must not masquerade as a successful CIFS mount"
    pass "empty/local mountpoint is rejected as Tool Server mount success"
}

test_arch_nss_configuration() {
    local case_dir nsswitch expected original output rc sss_count main_flow case_name
    local enable_line nss_line identity_line manager_line mount_line sudo_line

    case_dir="$TMP_DIR/arch-nss-default"
    mkdir -p "$case_dir"
    nsswitch="$case_dir/nsswitch.conf"
    printf '%s\n' \
        '# CachyOS NSS defaults; a comment mentioning sss is not a provider' \
        'passwd: files systemd' \
        'group: files [SUCCESS=merge] systemd' \
        'shadow: files systemd' \
        'hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns' \
        'networks: files' > "$nsswitch"
    DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; configure_arch_nss_sss '$nsswitch'" >/dev/null
    expected=$'# CachyOS NSS defaults; a comment mentioning sss is not a provider\npasswd: files systemd sss\ngroup: files [SUCCESS=merge] systemd sss\nshadow: files systemd sss\nhosts: mymachines resolve [!UNAVAIL=return] files myhostname dns\nnetworks: files'
    assert_eq "$expected" "$(<"$nsswitch")" "CachyOS NSS databases append sss without replacing native providers"
    assert_contains "$(<"$nsswitch")" 'group: files [SUCCESS=merge] systemd sss' "CachyOS group SUCCESS=merge action is preserved exactly"
    assert_contains "$(<"$nsswitch")" 'hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns' "unrelated NSS databases remain unchanged"
    if grep -qE '^[[:space:]]*initgroups[[:space:]]*:' "$nsswitch"; then
        fail "Arch NSS adapter must not invent an initgroups database"
    fi
    pass "absence of initgroups remains unchanged"
    compgen -G "$nsswitch.domain-join.bak.*" >/dev/null || fail "Arch NSS update creates a timestamped backup"
    pass "Arch NSS update uses the existing backup mechanism"

    DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; configure_arch_nss_sss '$nsswitch'" >/dev/null
    sss_count="$(awk '$1 ~ /^(passwd|group|shadow):$/ { for (i = 2; i <= NF; i++) if ($i == "sss") count++ } END { print count + 0 }' "$nsswitch")"
    [ "$sss_count" -eq 3 ] || fail "idempotent Arch NSS update must retain one sss token per required database"
    pass "running the Arch NSS adapter twice does not duplicate sss"

    case_dir="$TMP_DIR/arch-nss-existing"
    mkdir -p "$case_dir"
    nsswitch="$case_dir/nsswitch.conf"
    printf '%s\n' \
        'passwd: files sss systemd # keep exact ordering' \
        'group: files [SUCCESS=merge] systemd sss' \
        'shadow: files systemd sss' \
        'hosts: files dns' > "$nsswitch"
    original="$case_dir/original"
    cp -- "$nsswitch" "$original"
    DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; configure_arch_nss_sss '$nsswitch'" >/dev/null
    cmp -s "$original" "$nsswitch" || fail "existing standalone sss providers must remain byte-for-byte unchanged"
    pass "existing sss providers and provider ordering remain unchanged"

    case_dir="$TMP_DIR/arch-nss-initgroups"
    mkdir -p "$case_dir"
    nsswitch="$case_dir/nsswitch.conf"
    printf '%s\n' \
        'passwd: files systemd' \
        'group: files [SUCCESS=merge] systemd' \
        'shadow: files systemd' \
        'initgroups: files [NOTFOUND=return] systemd # preserve this action' > "$nsswitch"
    DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; configure_arch_nss_sss '$nsswitch'; configure_arch_nss_sss '$nsswitch'" >/dev/null
    assert_contains "$(<"$nsswitch")" 'initgroups: files [NOTFOUND=return] systemd sss # preserve this action' "existing initgroups appends sss before its comment"
    [ "$(awk '$1 == "initgroups:" { for (i = 2; i <= NF; i++) if ($i == "sss") count++ } END { print count + 0 }' "$nsswitch")" -eq 1 ] || fail "initgroups sss provider must be idempotent"
    pass "existing initgroups receives one standalone sss provider"

    for case_name in missing-passwd missing-group missing-shadow malformed-passwd duplicate-group; do
        case_dir="$TMP_DIR/arch-nss-$case_name"
        mkdir -p "$case_dir"
        nsswitch="$case_dir/nsswitch.conf"
        case "$case_name" in
            missing-passwd) printf '%s\n' 'group: files systemd' 'shadow: files systemd' > "$nsswitch" ;;
            missing-group) printf '%s\n' 'passwd: files systemd' 'shadow: files systemd' > "$nsswitch" ;;
            missing-shadow) printf '%s\n' 'passwd: files systemd' 'group: files systemd' > "$nsswitch" ;;
            malformed-passwd) printf '%s\n' 'passwd files systemd' 'group: files systemd' 'shadow: files systemd' > "$nsswitch" ;;
            duplicate-group) printf '%s\n' 'passwd: files systemd' 'group: files systemd' 'group: files sss' 'shadow: files systemd' > "$nsswitch" ;;
        esac
        original="$case_dir/original"
        cp -- "$nsswitch" "$original"
        set +e
        output="$(DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; configure_arch_nss_sss '$nsswitch'" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "$case_name NSS fixture must fail safely"
        cmp -s "$original" "$nsswitch" || fail "$case_name NSS failure must leave the source file unchanged"
        assert_contains "$output" 'could not be updated safely' "$case_name NSS failure is explicit"
    done
    pass "missing, malformed, and duplicate required NSS databases fail without overwriting the file"

    case_dir="$TMP_DIR/debian-nss-noop"
    mkdir -p "$case_dir"
    nsswitch="$case_dir/nsswitch.conf"
    printf '%s\n' 'passwd: files' 'group: files' 'shadow: files' > "$nsswitch"
    original="$case_dir/original"
    cp -- "$nsswitch" "$original"
    DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=debian; platform_configure_nss '$nsswitch'"
    cmp -s "$original" "$nsswitch" || fail "Debian NSS adapter must remain a no-op"
    pass "Debian NSS behavior remains unchanged"

    main_flow="$(sed -n '/^main() {/,/^}/p' "$SCRIPT")"
    enable_line="$(printf '%s\n' "$main_flow" | awk '/^[[:space:]]*enable_sssd[[:space:]]*$/ { print NR; exit }')"
    nss_line="$(printf '%s\n' "$main_flow" | awk '/^[[:space:]]*platform_configure_nss[[:space:]]*$/ { print NR; exit }')"
    identity_line="$(printf '%s\n' "$main_flow" | awk '/^[[:space:]]*platform_validate_selected_domain_user[[:space:]]*$/ { print NR; exit }')"
    manager_line="$(printf '%s\n' "$main_flow" | awk '/^[[:space:]]*install_dr_workstation_manager[[:space:]]*$/ { print NR; exit }')"
    mount_line="$(printf '%s\n' "$main_flow" | awk '/^[[:space:]]*configure_autofs_cifs[[:space:]]*$/ { print NR; exit }')"
    sudo_line="$(printf '%s\n' "$main_flow" | awk '/^[[:space:]]*configure_sudoers[[:space:]]*$/ { print NR; exit }')"
    [ -n "$enable_line" ] && [ "$enable_line" -lt "$nss_line" ] && [ "$nss_line" -lt "$identity_line" ] && [ "$identity_line" -lt "$manager_line" ] && [ "$manager_line" -lt "$mount_line" ] && [ "$mount_line" -lt "$sudo_line" ] || fail "Arch NSS and identity gates must precede workstation, mount, and user sudo provisioning"
    pass "SSSD startup, NSS configuration, normal identity validation, mount, and user sudo provisioning are correctly ordered"
}

test_domain_uid_resolution_gate() {
    local fake_bin output rc unit
    fake_bin="$TMP_DIR/domain-uid-fake-bin"
    mkdir -p "$fake_bin"
    cat > "$fake_bin/getent" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -s ] && [ "${2:-}" = sss ] && [ "${3:-}" = passwd ] && [ "${4:-}" = martin.campetta ] && [ "${DIRECT_SSS_RESOLVES:-0}" = 1 ]; then
    printf 'martin.campetta:*:%s:350000513:Campetta, Martin:/home/martin.campetta:\n' "${DOMAIN_UID:-350020586}"
elif [ "${1:-}" = passwd ] && [ "${2:-}" = martin.campetta ] && [ "${DOMAIN_USER_RESOLVES:-0}" = 1 ]; then
    printf 'martin.campetta:*:%s:350000513:Campetta, Martin:/home/martin.campetta:\n' "${DOMAIN_UID:-350020586}"
fi
EOF
    cat > "$fake_bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -u ] && [ "${2:-}" = martin.campetta ]; then printf '%s\n' "${DOMAIN_UID:-350020586}"; else /usr/bin/id "$@"; fi
EOF
    chmod 755 "$fake_bin"/*

    set +e
    output="$(PATH="$fake_bin:$PATH" DOMAIN_SUDO_USER=martin.campetta DR_TOOLS_MOUNT_CRUID=1000 bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; tools_mount_cruid" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "unresolved domain user must block Arch cruid generation"
    assert_contains "$output" 'does not resolve through NSS/SSSD' "unresolved domain user is reported"
    if printf '%s\n' "$output" | grep -Fq '1000'; then
        fail "unresolved martin.campetta must not inherit local martin UID 1000"
    fi
    pass "unresolved domain user cannot generate a guessed/local cruid"

    output="$(PATH="$fake_bin:$PATH" DOMAIN_USER_RESOLVES=1 DOMAIN_SUDO_USER=martin.campetta DR_TOOLS_MOUNT_CRUID=350020586 bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; tools_mount_cruid")"
    assert_eq '350020586' "$output" "resolved domain user supplies the only Arch cruid"

    unit="$TMP_DIR/domain-user-mnt-x.mount"
    PATH="$fake_bin:$PATH" DOMAIN_USER_RESOLVES=1 DOMAIN_SUDO_USER=martin.campetta DR_JOIN_STATE_DIR="$TMP_DIR/domain-user-mount-state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; platform_validate_selected_domain_user; uid=\$(tools_mount_cruid); render_arch_tools_mount_unit /mnt/x \"\$TOOLS_SERVER\" \"\$uid\" > '$unit'"
    assert_contains "$(<"$unit")" 'cruid=350020586' "normal NSS domain UID is used to render the Arch Tool Server mount"

    unit="$TMP_DIR/direct-sss-only-mnt-x.mount"
    set +e
    output="$(PATH="$fake_bin:$PATH" DIRECT_SSS_RESOLVES=1 DOMAIN_SUDO_USER=martin.campetta DR_JOIN_STATE_DIR="$TMP_DIR/direct-sss-only-state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; platform_validate_selected_domain_user || exit 17; uid=\$(tools_mount_cruid); render_arch_tools_mount_unit /mnt/x \"\$TOOLS_SERVER\" \"\$uid\" > '$unit'" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 17 ] || fail "direct SSSD success without normal NSS must stop at the identity gate"
    [ ! -e "$unit" ] || fail "direct SSSD success without normal NSS must not render /mnt/x"
    assert_contains "$output" "SSSD's direct NSS service resolves martin.campetta as UID 350020586" "direct SSSD-only resolution receives a focused nsswitch diagnostic"
    assert_contains "$output" 'normal libc/NSS path does not' "direct SSSD-only resolution remains blocked"
    pass "direct SSSD lookup cannot substitute for normal NSS identity resolution"
}

test_rebind_failure_rollback() {
    local rebind_helper fake_bin stage case_dir unit state original_unit original_state
    rebind_helper="$TMP_DIR/rebind-rollback-helper"
    fake_bin="$TMP_DIR/rebind-fake-bin"
    mkdir -p "$fake_bin"
    DR_JOIN_STATE_DIR="$TMP_DIR/rebind-rollback-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; TOOLS_SERVER=dr-ep1-tools; render_arch_tools_rebind_helper > '$rebind_helper'"
    chmod 755 "$rebind_helper"
    bash -n "$rebind_helper" || fail "rollback test helper syntax"

    cat > "$fake_bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ]; then
    if [ "$#" -eq 1 ]; then
        echo 0
    elif [ "${2:-}" = fixture.user ]; then
        echo 1001
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
    if [ "${REBIN_OLD_FIXTURE:-0}" = 1 ]; then
        echo '1001:fixture:x:1001:Fixture User:/tmp/fixture:/bin/bash'
    elif [ "${REBIN_EMPTY_FIXTURE:-0}" = 1 ]; then
        exit 0
    elif [ "${REBIN_DUPLICATE_FIXTURE:-0}" = 1 ]; then
        echo 'fixture.user:x:1001:1001:Fixture User:/tmp/fixture:/bin/bash'
        echo 'fixture.user2:x:1001:1001:Fixture User 2:/tmp/fixture2:/bin/bash'
    elif [ "${REBIN_MISMATCH_FIXTURE:-0}" = 1 ]; then
        echo 'fixture.user:x:1000:1000:Fixture User:/tmp/fixture:/bin/bash'
    else
        echo 'fixture.user:x:1001:1001:Fixture User:/tmp/fixture:/bin/bash'
    fi
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
    cat > "$fake_bin/chown" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$REBIND_CHOWN_LOG"
exit 0
EOF
    cat > "$fake_bin/stat" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -c ] && [ "${2:-}" = '%u:%a' ]; then
    echo '0:600'
    exit 0
fi
exec /usr/bin/stat "$@"
EOF
    chmod 755 "$fake_bin"/*

    case_dir="$TMP_DIR/rebind-malformed-record"
    unit="$case_dir/units/mnt-x.mount"
    state="$case_dir/state"
    mkdir -p "$(dirname "$unit")"
    printf '%s\n' '[Mount]' 'What=//dr-ep1-tools/Tools' 'Where=/mnt/x' 'Type=cifs' 'Options=_netdev,nofail,sec=krb5,cruid=1000,vers=3.0' > "$unit"
    printf '%s\n' 'DR_TOOLS_MOUNT_CRUID="1000"' > "$state"
    chmod 600 "$state"
    set +e
    PATH="$fake_bin:$PATH" REBIN_OLD_FIXTURE=1 \
        DR_REBIND_UNIT_DIR="$case_dir/units" DR_REBIND_STATE_FILE="$state" \
        DR_REBIND_LOCK_DIR="$case_dir/lock" DR_REBIND_STAGE_ROOT="$case_dir/stage" \
        "$rebind_helper" 1001 > "$case_dir/output" 2>&1
    local malformed_rc=$?
    set -e
    [ "$malformed_rc" -ne 0 ] || fail "old malformed getent fixture is rejected"
    pass "old malformed getent fixture is not sufficient"

    for fixture in empty duplicate mismatch; do
        set +e
        env "REBIN_${fixture^^}_FIXTURE=1" PATH="$fake_bin:$PATH" \
            DR_REBIND_UNIT_DIR="$case_dir/units" DR_REBIND_STATE_FILE="$state" \
            DR_REBIND_LOCK_DIR="$case_dir/lock-$fixture" DR_REBIND_STAGE_ROOT="$case_dir/stage-$fixture" \
            "$rebind_helper" 1001 >/dev/null 2>&1
        local fixture_rc=$?
        set -e
        [ "$fixture_rc" -ne 0 ] || fail "NSS $fixture passwd fixture is rejected"
        pass "NSS $fixture passwd fixture is rejected"
    done

    case_dir="$TMP_DIR/rebind-success"
    unit="$case_dir/units/mnt-x.mount"
    state="$case_dir/state"
    mkdir -p "$(dirname "$unit")"
    printf '%s\n' '[Mount]' 'What=//dr-ep1-tools/Tools' 'Where=/mnt/x' 'Type=cifs' 'Options=_netdev,nofail,sec=krb5,cruid=1000,vers=3.0' > "$unit"
    printf '%s\n' 'STAGE="POSTJOIN_AWAITING_LIVE_VALIDATION"' 'DR_TOOLS_MOUNT_CRUID="1000"' > "$state"
    chmod 600 "$state"
    : > "$case_dir/chown.log"
    PATH="$fake_bin:$PATH" REBIND_CHOWN_LOG="$case_dir/chown.log" \
        DR_REBIND_UNIT_DIR="$case_dir/units" DR_REBIND_STATE_FILE="$state" \
        DR_REBIND_LOCK_DIR="$case_dir/lock" DR_REBIND_STAGE_ROOT="$case_dir/stage" \
        "$rebind_helper" 1001 > "$case_dir/output" 2>&1 || fail "successful rebind fixture commits"
    assert_contains "$(<"$unit")" "cruid=1001" "successful rebind changes the installed UID"
    assert_contains "$(<"$state")" 'DR_TOOLS_MOUNT_CRUID="1001"' "successful rebind persists the new UID"
    [ "$(stat -c '%a' "$unit")" = 644 ] || fail "successful rebind preserves unit mode"
    [ "$(stat -c '%a' "$state")" = 600 ] || fail "successful rebind preserves state mode"
    assert_contains "$(<"$case_dir/chown.log")" "root:root" "successful rebind requests root ownership"
    if grep -Fq 'restoring the original' "$case_dir/output"; then
        fail "successful rebind must not trigger rollback"
    fi
    pass "successful rebind commits NSS-resolved UID, unit, and state"
    status_output="$(PATH="$fake_bin:$PATH" DR_REBIND_UNIT_DIR="$case_dir/units" DR_REBIND_STATE_FILE="$state" "$rebind_helper" --status)"
    assert_contains "$status_output" "unit_cruid=1001" "rebind status uses numeric cruid extraction"

    for bad_cruid in absent conflicting nonnumeric mismatch; do
        bad_unit="$case_dir/units/bad-$bad_cruid.mount"
        case "$bad_cruid" in
            absent) printf '%s\n' '[Mount]' 'Options=_netdev,nofail,vers=3.0' > "$bad_unit" ;;
            conflicting) printf '%s\n' '[Mount]' 'Options=sec=krb5,cruid=1000,cruid=1001,vers=3.0' > "$bad_unit" ;;
            nonnumeric) printf '%s\n' '[Mount]' 'Options=sec=krb5,cruid=user,vers=3.0' > "$bad_unit" ;;
            mismatch) printf '%s\n' '[Mount]' 'Options=sec=krb5,cruid=1000,vers=3.0' > "$bad_unit" ;;
        esac
        cp -- "$unit" "$case_dir/units/mnt-x.mount.save"
        cp -- "$bad_unit" "$unit"
        set +e
        PATH="$fake_bin:$PATH" DR_REBIND_UNIT_DIR="$case_dir/units" DR_REBIND_STATE_FILE="$state" "$rebind_helper" --status >/dev/null 2>&1
        local bad_rc=$?
        set -e
        [ "$bad_rc" -ne 0 ] || fail "cruid extraction rejects $bad_cruid unit"
        mv -f -- "$case_dir/units/mnt-x.mount.save" "$unit"
        pass "cruid extraction rejects $bad_cruid unit"
    done

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

    nested_entry='dr-ep-drip04/Image-Folders'
    nested_mount_unit="$(systemd-escape --path --suffix=mount "/smb/$nested_entry")"
    nested_automount_unit="$(systemd-escape --path --suffix=automount "/smb/$nested_entry")"
    DR_JOIN_STATE_DIR="$TMP_DIR/drip-nested-render" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_arch_drip_mount_unit '$nested_entry' > '$unit_dir/$nested_mount_unit'; render_arch_drip_automount_unit '$nested_entry' > '$unit_dir/$nested_automount_unit'"
    [[ "$nested_mount_unit" == *'\x2d'* ]] || fail "hyphenated DRIP server/share must use systemd hexadecimal escaping"
    [[ "$nested_mount_unit" != 'smb-dr-ep-drip04-Image-Folders.mount' ]] || fail "DRIP validator must not use ad-hoc hyphen escaping"
    assert_contains "$(<"$unit_dir/$nested_mount_unit")" 'Where=/smb/dr-ep-drip04/Image-Folders' "nested DRIP target preserves the configured path"
    printf '%s\t%s\t%s\n' "$nested_entry" "$nested_mount_unit" "$nested_automount_unit" > "$TMP_DIR/drip-nested.manifest"
    DR_DRIP_SEARCH_ROOTS="$nested_entry" DR_DRIP_MANIFEST="$TMP_DIR/drip-nested.manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$TMP_DIR/drip-nested-verify" bash -c "source '$SCRIPT'; systemctl(){ [ \"\${1:-}\" = show ] && { printf 'static\\n'; return 0; }; return 1; }; PLATFORM_FAMILY=arch; platform_verify_drip_search"
    pass "DRIP generation, manifest, validator, and cleanup share canonical systemd escaping"

    helper="$(DR_DRIP_MANIFEST="$TMP_DIR/drip.manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$TMP_DIR/drip-helper" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_drip_search_mount_helper")"
    assert_contains "$helper" 'systemctl start "$automount_unit"' "DRIP helper starts automount units only"
    assert_contains "$helper" 'BUSY: could not stop DRIP automount' "DRIP cleanup reports busy automounts"
    if printf '%s\n' "$helper" | grep -Eq '(/mnt/p|krb5cc_0)'; then
        fail "Arch DRIP helper must not own /mnt/p or /tmp/krb5cc_0"
    fi
    pass "Arch DRIP helper has no /mnt/p or root-cache ownership"
}

test_drip_automount_unit_file_state() {
    local case_dir fake_bin unit_dir manifest helper mount_unit automount_unit output rc state enabled_output
    case_dir="$TMP_DIR/drip-unit-file-state"
    fake_bin="$case_dir/bin"
    unit_dir="$case_dir/units"
    manifest="$case_dir/drip.manifest"
    helper="$case_dir/dr-drip-search"
    mkdir -p "$fake_bin" "$unit_dir"

    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${DRIP_SYSTEMCTL_LOG:?}"
case "${1:-}" in
    show)
        [ "${DRIP_SHOW_FAIL:-0}" != 1 ] || exit 1
        printf '%s\n' "${DRIP_UNIT_STATE-static}"
        ;;
    is-enabled)
        # This mirrors systemd's intentionally counterintuitive static-unit
        # behavior: text is static but the command returns success.
        printf 'static\n'
        ;;
    start|stop|daemon-reload) exit 0 ;;
    is-active) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/systemd-analyze" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/id" << 'EOF'
#!/bin/bash
if [ "${1:-}" = -u ]; then
    printf '0\n'
    exit 0
fi
exec /usr/bin/id "$@"
EOF
    chmod 755 "$fake_bin/systemctl" "$fake_bin/systemd-analyze" "$fake_bin/id"

    mount_unit="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip04/Images)"
    automount_unit="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip04/Images)"
    assert_eq 'smb-dr\x2dep\x2ddrip04-Images.automount' "$automount_unit" "DRIP automount uses the canonical escaped unit name"
    DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/render" bash -c "source '$SCRIPT'; render_arch_drip_mount_unit dr-ep-drip04/Images > '$unit_dir/$mount_unit'; render_arch_drip_automount_unit dr-ep-drip04/Images > '$unit_dir/$automount_unit'; render_drip_search_mount_helper > '$helper'"
    chmod 755 "$helper"
    printf 'dr-ep-drip04/Images\t%s\t%s\n' "$mount_unit" "$automount_unit" > "$manifest"
    chmod 600 "$manifest"
    if grep -Eq '^\[Install\]|WantedBy=' "$unit_dir/$automount_unit"; then
        fail "managed DRIP automount must not gain an Install target"
    fi
    pass "managed DRIP automount remains static by rendering without Install metadata"

    set +e
    enabled_output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" systemctl is-enabled "$automount_unit" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 0 ] || fail "fixture must model systemctl is-enabled static success"
    assert_eq static "$enabled_output" "systemctl is-enabled reports static with exit status zero"
    : > "$case_dir/systemctl.log"
    PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/state-static" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_verify_drip_search" || fail "static DRIP automount must pass verification"
    grep -Fq "show $automount_unit -p UnitFileState --value" "$case_dir/systemctl.log" || fail "DRIP verifier must inspect UnitFileState"
    if grep -Fq "is-enabled $automount_unit" "$case_dir/systemctl.log"; then
        fail "DRIP verifier must not treat is-enabled exit status as enablement"
    fi
    pass "static DRIP automount is accepted despite is-enabled success"

    for state in enabled enabled-runtime; do
        set +e
        output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_UNIT_STATE="$state" DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/state-$state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_verify_drip_search" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "$state DRIP automount must fail verification"
        assert_contains "$output" 'must not be enabled globally' "$state DRIP automount is rejected as globally enabled"
    done

    for state in masked masked-runtime; do
        set +e
        output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_UNIT_STATE="$state" DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/state-$state" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_verify_drip_search" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "$state DRIP automount must fail verification"
        assert_contains "$output" 'masked and unusable' "$state DRIP automount is rejected as unusable"
    done

    for state in linked linked-runtime alias generated transient not-found unknown ''; do
        set +e
        output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_UNIT_STATE="$state" DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/state-unknown" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_verify_drip_search" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "$state DRIP automount must fail closed"
        assert_contains "$output" 'unexpected UnitFileState' "$state DRIP automount failure is explicit"
    done

    set +e
    output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_UNIT_STATE=$'static\nmalformed' DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/state-malformed" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_verify_drip_search" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "malformed UnitFileState output must fail closed"
    assert_contains "$output" 'unexpected UnitFileState' "malformed UnitFileState output is explicit"

    set +e
    output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_SHOW_FAIL=1 DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_JOIN_STATE_DIR="$case_dir/state-show-fail" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_verify_drip_search" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "failed UnitFileState lookup must fail closed"
    assert_contains "$output" 'Could not determine UnitFileState' "systemctl UnitFileState failure is explicit"
    pass "masked, missing, unknown, and failed DRIP unit-file states fail closed"

    : > "$case_dir/systemctl.log"
    PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" "$helper" start || fail "DRIP helper can explicitly start a static automount"
    PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" "$helper" cleanup || fail "DRIP helper cleanup remains intact"
    grep -Fq "start $automount_unit" "$case_dir/systemctl.log" || fail "DRIP helper must explicitly start the static automount"
    grep -Fq "stop $automount_unit" "$case_dir/systemctl.log" || fail "DRIP helper must stop the automount during cleanup"
    grep -Fq "stop $mount_unit" "$case_dir/systemctl.log" || fail "DRIP helper must stop the mount during cleanup"
    pass "DRIP helper explicitly starts and safely cleans up static automounts"
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
    assert_contains "$drip_support" 'DRIP_SEARCH_HELPER="' "KIT launcher embeds the configured DRIP helper path"
    assert_contains "$drip_support" '"$DRIP_SEARCH_HELPER" start' "KIT launcher starts configured DRIP search units"
    assert_contains "$drip_support" '"$DRIP_SEARCH_HELPER" cleanup' "KIT launcher cleans configured DRIP search units"
    assert_contains "$drip_support" 'Configured DRIP search automounts could not be started' "KIT launcher blocks when DRIP search start fails"
    if printf '%s\n' "$drip_support" | grep -Eq '(/mnt/p|krb5cc_0)'; then
        fail "KIT launcher DRIP support must not own /mnt/p or /tmp/krb5cc_0"
    fi
    start_line="$(printf '%s\n' "$drip_support" | grep -n '"\$DRIP_SEARCH_HELPER" start' | cut -d: -f1)"
    trap_line="$(printf '%s\n' "$drip_support" | grep -n 'trap .*EXIT' | head -1 | cut -d: -f1)"
    [ "$trap_line" -lt "$start_line" ] || fail "KIT launcher must install cleanup traps before DRIP start"
    pass "KIT launcher preserves root-cache and /mnt/p ownership boundaries"
}

test_drip_launcher_fail_closed() {
    local case_dir fake_bin launcher support output rc mount_unit automount_unit helper manifest
    case_dir="$TMP_DIR/drip-launcher-fail-closed"
    fake_bin="$case_dir/bin"
    launcher="$case_dir/launcher"
    helper="$case_dir/dr-drip-search"
    manifest="$case_dir/drip.manifest"
    mkdir -p "$fake_bin" "$case_dir/units"

    cat > "$fake_bin/stat" << 'EOF'
#!/bin/bash
set -euo pipefail
path="${!#}"
if [ "${1:-}" = -c ]; then
    case "${2:-}" in
        %u)
            [ "${path:-}" = "${FAKE_UNSAFE_PATH:-}" ] && printf '%s\n' "${FAKE_UNSAFE_OWNER:-1000}" || printf '0\n'
            ;;
        %a)
            if [ "${path:-}" = "${FAKE_HELPER:-}" ]; then
                printf '%s\n' "${FAKE_HELPER_MODE:-755}"
            elif [ "${path:-}" = "${FAKE_MANIFEST:-}" ]; then
                printf '%s\n' "${FAKE_MANIFEST_MODE:-600}"
            else
                printf '644\n'
            fi
            ;;
        *) exec /usr/bin/stat "$@" ;;
    esac
    exit 0
fi
exec /usr/bin/stat "$@"
EOF
    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    start)
        [ "${DRIP_TEST_FAIL_START:-0}" != 1 ] || exit 1
        exit 0
        ;;
    is-active)
        unit="${!#}"
        if [ "${DRIP_TEST_INACTIVE:-0}" = 1 ] && [[ "$unit" = *.automount ]]; then
            exit 1
        fi
        exit 0
        ;;
    stop|daemon-reload) exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/systemd-analyze" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$helper" << 'EOF'
#!/bin/bash
set -euo pipefail
case "${1:-}" in
    start)
        printf 'start\n' >> "${DRIP_HELPER_LOG:?}"
        [ "${DRIP_TEST_HELPER_FAIL:-0}" != 1 ]
        ;;
    cleanup)
        printf 'cleanup\n' >> "${DRIP_HELPER_LOG:?}"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod 755 "$fake_bin/stat" "$fake_bin/systemctl" "$fake_bin/systemd-analyze" "$helper"

    mount_unit="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip04/Images)"
    automount_unit="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip04/Images)"
    DR_JOIN_STATE_DIR="$case_dir/render" bash -c "source '$SCRIPT'; render_arch_drip_mount_unit dr-ep-drip04/Images > '$case_dir/units/$mount_unit'; render_arch_drip_automount_unit dr-ep-drip04/Images > '$case_dir/units/$automount_unit'"
    printf 'dr-ep-drip04/Images\t%s\t%s\n' "$mount_unit" "$automount_unit" > "$manifest"
    chmod 600 "$manifest"

    support="$(DRIP_REQUIRED=true DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$case_dir/units" DR_DRIP_HELPER_PATH="$helper" DR_JOIN_STATE_DIR="$case_dir/support" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_drip_launcher_support")"
    {
        printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
        printf '%s\n' 'if [ "${1:-}" = --credential-self-test ]; then echo SELF_TEST; exit 0; fi'
        printf '%s\n' "$support"
        printf '%s\n' 'echo KIT_STARTED'
    } > "$launcher"
    chmod 755 "$launcher"

    run_launcher() {
        set +e
        output="$(PATH="$fake_bin:$PATH" FAKE_HELPER="$helper" FAKE_MANIFEST="$manifest" DRIP_HELPER_LOG="$case_dir/helper.log" DRIP_SEARCH_HELPER="$helper" "$@" 2>&1)"
        rc=$?
        set -e
    }

    run_launcher env DRIP_SEARCH_HELPER="$case_dir/missing-helper" "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks when helper is missing"
    [[ "$output" != *KIT_STARTED* ]] || fail "missing required DRIP helper cannot launch KIT"
    pass "required DRIP launch blocks when helper is missing"

    mv -- "$manifest" "$manifest.saved"
    run_launcher "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks when manifest is missing"
    pass "required DRIP launch blocks when manifest is missing"
    mv -- "$manifest.saved" "$manifest"
    printf 'dr-ep-drip04/Images\t%s\t%s\n' "$mount_unit" "$automount_unit" > "$manifest"
    chmod 600 "$manifest"

    run_launcher env FAKE_UNSAFE_PATH="$helper" FAKE_UNSAFE_OWNER=1000 "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks unsafe helper ownership"
    pass "required DRIP launch blocks unsafe helper ownership"

    run_launcher env FAKE_UNSAFE_PATH="$manifest" FAKE_UNSAFE_OWNER=1000 "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks unsafe manifest ownership"
    pass "required DRIP launch blocks unsafe manifest ownership"

    run_launcher env FAKE_HELPER_MODE=777 "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks group/other-writable helper"
    pass "required DRIP launch blocks group/other-writable helper"

    run_launcher env FAKE_MANIFEST_MODE=666 "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks group/other-writable manifest"
    pass "required DRIP launch blocks group/other-writable manifest"

    ln -s -- "$helper" "$case_dir/helper.link"
    run_launcher env DRIP_SEARCH_HELPER="$case_dir/helper.link" "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks symlinked helper"
    pass "required DRIP launch blocks symlinked helper"
    cp -- "$manifest" "$manifest.real"
    rm -f -- "$manifest"
    ln -s -- "$manifest.real" "$manifest"
    run_launcher "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks symlinked manifest"
    pass "required DRIP launch blocks symlinked manifest"
    rm -f -- "$manifest"
    mv -- "$manifest.real" "$manifest"
    chmod 600 "$manifest"

    : > "$manifest"
    run_launcher "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks empty manifest"
    pass "required DRIP launch blocks empty manifest"
    printf 'dr-ep-drip04/Images\t%s\t%s\n' "$mount_unit" "$automount_unit" > "$manifest"
    chmod 600 "$manifest"

    run_launcher env DRIP_TEST_HELPER_FAIL=1 "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks failed automount startup"
    pass "required DRIP launch blocks failed automount startup"

    run_launcher env DRIP_TEST_INACTIVE=1 "$launcher"
    [ "$rc" -ne 0 ] || fail "required DRIP launch blocks inactive automount"
    pass "required DRIP launch blocks inactive automount"

    support="$(DRIP_REQUIRED=false DR_DRIP_SEARCH_ROOTS='dr-ep-drip04/Images' DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$case_dir/units" DR_DRIP_HELPER_PATH="$case_dir/no-helper" DR_JOIN_STATE_DIR="$case_dir/optional-support" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; render_drip_launcher_support")"
    {
        printf '%s\n' '#!/bin/bash' 'set -euo pipefail'
        printf '%s\n' "$support"
        printf '%s\n' 'echo KIT_STARTED'
    } > "$case_dir/optional-launcher"
    chmod 755 "$case_dir/optional-launcher"
    : > "$case_dir/helper.log"
    run_launcher env DRIP_SEARCH_HELPER="$case_dir/no-helper" "$case_dir/optional-launcher"
    [ "$rc" -eq 0 ] || fail "optional DRIP launch permits approved KIT-only path"
    assert_contains "$output" KIT_STARTED "optional DRIP launch permits KIT-only path"
    if [ -f "$case_dir/helper.log" ]; then
        if grep -Fq start "$case_dir/helper.log"; then
            fail "optional KIT-only launch must not start an absent DRIP helper"
        fi
    fi
    pass "DRIP_REQUIRED=false permits KIT-only launch with a warning"

    : > "$case_dir/helper.log"
    run_launcher "$launcher" --credential-self-test
    [ "$rc" -eq 0 ] || fail "credential self-test does not require DRIP startup"
    assert_contains "$output" SELF_TEST "credential self-test exits before DRIP startup"
    [ ! -s "$case_dir/helper.log" ] || fail "credential self-test must not start DRIP automounts"
    pass "credential self-test does not start DRIP automounts"
    if printf '%s\n' "$support" | grep -Eq '(/mnt/p|/tmp/krb5cc_0)'; then
        fail "generated DRIP launcher support must not own /mnt/p or /tmp/krb5cc_0"
    fi
    pass "generated DRIP launcher support has no /mnt/p or root-cache ownership"
}

test_drip_install_transaction() {
    local base fake_bin stage case_dir unit_dir manifest helper old_mount old_auto new_mount new_auto
    local old_manifest original_helper original_mount original_auto output rc
    base="$TMP_DIR/drip-install"
    fake_bin="$base/bin"
    mkdir -p "$fake_bin"

    cat > "$fake_bin/systemctl" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${DRIP_SYSTEMCTL_LOG:?}"
case "${1:-}" in
    is-active) exit 1 ;;
    daemon-reload)
        [ "${DRIP_TEST_DAEMON_FAIL:-0}" != 1 ]
        ;;
    *) exit 0 ;;
esac
EOF
    cat > "$fake_bin/systemd-analyze" << 'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$fake_bin/mountpoint" << 'EOF'
#!/bin/bash
exit 1
EOF
    cat > "$fake_bin/chown" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${DRIP_CHOWN_LOG:?}"
exit 0
EOF
    chmod 755 "$fake_bin"/*

    prepare_fixture() {
        local root="$1"
        local units="$root/units" manifest_path="$root/drip.manifest" helper_path="$root/helper"
        local old_mount_name old_automount_name
        rm -rf -- "$root"
        mkdir -p "$units"
        old_mount_name="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip04/Images)"
        old_automount_name="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip04/Images)"
        printf 'OLD-MOUNT\n' > "$units/$old_mount_name"
        printf 'OLD-AUTOMOUNT\n' > "$units/$old_automount_name"
        printf 'dr-ep-drip04/Images\t%s\t%s\n' "$old_mount_name" "$old_automount_name" > "$manifest_path"
        printf 'old helper\n' > "$helper_path"
        chmod 644 "$units/$old_mount_name" "$units/$old_automount_name"
        chmod 600 "$manifest_path"
        chmod 755 "$helper_path"
    }

    for stage in render verify unit-install manifest daemon-reload; do
        case_dir="$base/failure-$stage"
        prepare_fixture "$case_dir"
        unit_dir="$case_dir/units"
        manifest="$case_dir/drip.manifest"
        helper="$case_dir/helper"
        old_mount="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip04/Images)"
        old_auto="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip04/Images)"
        new_mount="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip05/Images)"
        new_auto="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip05/Images)"
        old_manifest="$case_dir/original.manifest"
        original_helper="$case_dir/original.helper"
        original_mount="$case_dir/original.mount"
        original_auto="$case_dir/original.automount"
        cp -- "$manifest" "$old_manifest"
        cp -- "$helper" "$original_helper"
        cp -- "$unit_dir/$old_mount" "$original_mount"
        cp -- "$unit_dir/$old_auto" "$original_auto"
        : > "$case_dir/systemctl.log"
        : > "$case_dir/chown.log"
        set +e
        output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_CHOWN_LOG="$case_dir/chown.log" \
            DR_DRIP_SKIP_MOUNT_ROOT=true DR_DRIP_SEARCH_ROOTS='dr-ep-drip05/Images' \
            DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_DRIP_HELPER_PATH="$helper" \
            DR_DRIP_INSTALL_FAIL_STAGE="$stage" DR_JOIN_STATE_DIR="$case_dir/state" \
            bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_install_drip_search" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -ne 0 ] || fail "DRIP install failure injection $stage returns failure"
        cmp -s "$original_mount" "$unit_dir/$old_mount" || fail "DRIP install failure $stage restores old mount unit"
        cmp -s "$original_auto" "$unit_dir/$old_auto" || fail "DRIP install failure $stage restores old automount unit"
        cmp -s "$old_manifest" "$manifest" || fail "DRIP install failure $stage restores manifest"
        cmp -s "$original_helper" "$helper" || fail "DRIP install failure $stage restores helper"
        [ ! -e "$unit_dir/$new_mount" ] && [ ! -e "$unit_dir/$new_auto" ] || fail "DRIP install failure $stage removes orphan new units"
        [ -z "$(find "$case_dir" -maxdepth 2 -type d -name '.drip-install.*' -print -quit)" ] || fail "DRIP install failure $stage removes transaction directory"
        pass "DRIP install failure injection $stage restores units, manifest, helper, and cleanup"
    done

    case_dir="$base/success"
    prepare_fixture "$case_dir"
    unit_dir="$case_dir/units"
    manifest="$case_dir/drip.manifest"
    helper="$case_dir/helper"
    old_mount="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip04/Images)"
    old_auto="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip04/Images)"
    new_mount="$(systemd-escape --path --suffix=mount /smb/dr-ep-drip05/Images)"
    new_auto="$(systemd-escape --path --suffix=automount /smb/dr-ep-drip05/Images)"
    : > "$case_dir/systemctl.log"
    : > "$case_dir/chown.log"
    PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_CHOWN_LOG="$case_dir/chown.log" \
        DR_DRIP_SKIP_MOUNT_ROOT=true DR_DRIP_SEARCH_ROOTS='dr-ep-drip05/Images' \
        DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_DRIP_HELPER_PATH="$helper" \
        DR_JOIN_STATE_DIR="$case_dir/state" \
        bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_install_drip_search" >/dev/null || fail "successful DRIP install commits"
    [ -f "$unit_dir/$new_mount" ] && [ -f "$unit_dir/$new_auto" ] || fail "successful DRIP install creates new units"
    [ ! -e "$unit_dir/$old_mount" ] && [ ! -e "$unit_dir/$old_auto" ] || fail "successful DRIP install removes inactive stale units"
    grep -Fq $'dr-ep-drip05/Images\t' "$manifest" || fail "successful DRIP install persists the new manifest"
    [ "$(stat -c '%a' "$manifest")" = 600 ] || fail "successful DRIP install keeps manifest mode 0600"
    [ "$(stat -c '%a' "$helper")" = 755 ] || fail "successful DRIP install keeps helper executable mode"
    [ "$(stat -c '%a' "$unit_dir/$new_mount")" = 644 ] || fail "successful DRIP install keeps mount unit mode"
    if grep -Eq '(^|[[:space:]])(enable|is-enabled|start)([[:space:]]|$)' "$case_dir/systemctl.log"; then
        fail "successful DRIP install must not enable or start units globally"
    fi
    assert_contains "$(<"$case_dir/chown.log")" 'root:root' "successful DRIP install requests root ownership"
    pass "successful DRIP install commits configured roots and removes inactive stale units"

    prepare_fixture "$base/busy"
    case_dir="$base/busy"
    unit_dir="$case_dir/units"
    manifest="$case_dir/drip.manifest"
    helper="$case_dir/helper"
    : > "$case_dir/systemctl.log"
    : > "$case_dir/chown.log"
    set +e
    output="$(PATH="$fake_bin:$PATH" DRIP_SYSTEMCTL_LOG="$case_dir/systemctl.log" DRIP_CHOWN_LOG="$case_dir/chown.log" \
        DRIP_TEST_STALE_ACTIVE=1 DR_DRIP_SKIP_MOUNT_ROOT=true DR_DRIP_SEARCH_ROOTS='dr-ep-drip05/Images' \
        DR_DRIP_MANIFEST="$manifest" DR_DRIP_UNIT_DIR="$unit_dir" DR_DRIP_HELPER_PATH="$helper" \
        DR_JOIN_STATE_DIR="$case_dir/state" bash -c "source '$SCRIPT'; systemctl(){ if [ \"\${1:-}\" = is-active ] && [ \"\${DRIP_TEST_STALE_ACTIVE:-0}\" = 1 ]; then return 0; fi; return 1; }; export -f systemctl; PLATFORM_FAMILY=arch; platform_install_drip_search" 2>&1)"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "active stale DRIP unit blocks configuration replacement"
    assert_contains "$output" 'Stale DRIP mount is active or busy' "active stale DRIP unit reports a preservation blocker"
    pass "active stale DRIP unit blocks replacement and preserves evidence"
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

    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/dry-plan-preserve" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PLATFORM_PACKAGE_MANAGER=pacman; OFFICE_CODE=EP1; platform_preflight(){ PREFLIGHT_BLOCKERS=0; PLATFORM_REPORT_BLOCKERS=0; }; platform_ad_dns_configuration_usable(){ return 0; }; platform_time_provider(){ case \"\$1\" in selected|active|enabled) echo systemd-timesyncd ;; esac; }; platform_timesyncd_dropin_matches(){ return 0; }; platform_timesyncd_is_ready(){ return 0; }; platform_dry_run")"
    assert_contains "$output" 'WOULD PRESERVE already-valid AD DNS configuration' "dry-run preserves valid AD DNS"
    assert_contains "$output" 'WOULD PRESERVE already-valid corporate systemd-timesyncd configuration' "dry-run preserves valid corporate timesyncd"
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/dry-plan-install" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; PLATFORM_PACKAGE_MANAGER=pacman; OFFICE_CODE=EP1; platform_preflight(){ PREFLIGHT_BLOCKERS=0; PLATFORM_REPORT_BLOCKERS=0; }; platform_ad_dns_configuration_usable(){ return 1; }; platform_time_provider(){ case \"\$1\" in selected|active|enabled) echo systemd-timesyncd ;; esac; }; platform_timesyncd_dropin_matches(){ return 1; }; platform_timesyncd_is_ready(){ return 1; }; platform_dry_run")"
    assert_contains "$output" 'WOULD INSTALL/VERIFY Arch corporate timesyncd override' "dry-run identifies the required timesyncd override"
}

test_missing_capability() {
    local output
    output="$(DR_JOIN_STATE_DIR="$TMP_DIR/time-provider" bash -c "source '$SCRIPT'; PLATFORM_FAMILY=arch; platform_time_provider(){ case \"\$1\" in active|enabled|selected) echo systemd-timesyncd ;; esac; }; platform_capability_status time-sync")"
    assert_contains "$output" "PASS|time-sync|existing selected provider is active or enabled (systemd-timesyncd)" "existing Arch time provider satisfies time-sync"
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
    assert_contains "$plan" "net ads join -S PINNED_DC --use-kerberos=required" "Arch Samba join command is explicitly DC-pinned"
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
test_time_provider_and_timesyncd
test_dns_preservation_and_fallback
test_office_argument_workflow
test_hostname_collision_and_recovery
test_cifs_kernel_and_mount_gates
test_arch_nss_configuration
test_domain_uid_resolution_gate
test_rebind_failure_rollback
test_drip_compatibility
test_drip_automount_unit_file_state
test_machine_account_renewal
test_machine_account_renewal_behavior
test_kit_root_access_and_helpers
test_kit_cache_validation
test_drip_launcher_fail_closed
test_drip_install_transaction
test_debian_kit_and_autofs_regression
test_debian_golden_renderers
test_state_and_guard
test_modes
test_missing_capability
test_arch_backend_and_break_glass
test_missing_commands_and_packages
printf 'Completed %d tests\n' "$pass_count"
