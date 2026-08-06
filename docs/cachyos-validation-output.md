# CachyOS candidate validation output

Captured on 2026-08-06 from the existing CachyOS host. All commands in this
record were read-only. No package, service, network, hostname, DNS, PAM,
SSSD, sudoers, mount, or domain-membership change was made.

## Platform report

```text
Detected platform: cachyos rolling (family=arch, desktop=KDE Plasma)
Package manager: pacman
Administrator group: wheel
Resolver: systemd-resolved
Time provider: systemd-timesyncd
Time enabled: systemd-timesyncd
PASS Supported platform and configured-repository capability map
WARNING realmd: unavailable but no longer required on arch
WARNING adcli: unavailable but no longer required on arch
WARNING autofs: unavailable but no longer required on arch
WARNING winbind: unavailable but no longer required on arch
```

Installed join/mount prerequisites include `krb5`, `samba`, `smbclient`,
`cifs-utils`, `bind`, `pam`, `sudo`, NetworkManager, OpenSSH, and `xdg-utils`.
`sssd` and `chrony` are available but not installed. `openldap` is available
but optional diagnostics. The configured Samba version is 4.24.5.

## Time diagnostics

```text
Active provider:    systemd-timesyncd
Enabled provider:   systemd-timesyncd
Synchronized:       no
Server:             time.cloudflare.com
Packet count:       0
Source availability: no synchronized source is currently reported
Kerberos impact:     BLOCKED — clock skew can invalidate Kerberos
Proposed correction: operator-approved repair after checking UDP/123 and
                     approved AD NTP sources; no automatic provider switch
```

The journal showed repeated time.cloudflare.com UDP/123 timeouts. Chrony is
not installed or active. The candidate does not change that state.

## Preflight

Default production break-glass setting (`drone`): exit status 1.

```text
BLOCKED Kerberos SRV discovery failed for dr.kodr.local
BLOCKED System clock is not synchronized; no time repair will be attempted
BLOCKED Domain discovery failed for dr.kodr.local
WARNING ldapsearch is pending an available package and is not required for the Arch join command
WARNING sssctl is pending an available package and is not required for the Arch join command
Break-glass account: drone
Source: missing or not local
BLOCKED Break-glass account drone is not a local /etc/passwd account
BLOCKED Preflight found 4 blocker(s); no persistent changes were made
```

With the explicit candidate-only override `DR_LOCAL_ADMIN_USER=martin`, the
account portion becomes:

```text
Break-glass account: martin
Source: local
Administrator group: wheel
Password status: operator verification required
PASS Break-glass account martin is in native administrator group wheel
WARNING Verify martin has a working local password and offline root access; no password test was performed
```

Time and DNS remain blockers in the override run.

## Dry run

Exit status 1 because preflight blockers remain. The Arch plan includes:

```text
WOULD CHANGE /etc/systemd/system/mnt-x.mount and /etc/systemd/system/mnt-x.automount
WOULD ENABLE/RESTART services: chronyd, sssd, sshd, mnt-x.automount
WOULD JOIN with Samba: kinit (interactive), net ads join --use-kerberos=required, net ads testjoin, net ads keytab create
WOULD NOT reboot, log out, restart a display manager, disable security controls, or run pacman -Syu
BLOCKED Dry-run plan is not executable until preflight blockers are resolved
```

## Automated/static results

```text
bash -n domain-join-latest.sh tests/test_domain_join.sh scripts/dr-domain-join-backup.sh scripts/dr-domain-join-rollback.sh: PASS
git diff --check: PASS
fixture regression suite: 49 tests passed
systemd-analyze verify generated mount/automount units: PASS
testparm generated Arch smb.conf: PASS (no live file written)
visudo generated sudoers: PASS
shellcheck: NOT RUN — shellcheck is not installed on this host
```
