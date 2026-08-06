# Candidate validation output

Captured from the current CachyOS host on 2026-08-06. These commands were
read-only; no packages, services, network settings, hostname, PAM, SSSD,
sudoers, autofs, or realm membership were changed.

## `--platform-report`

```text
Detected platform: cachyos rolling (family=arch, desktop=KDE Plasma)
Package manager: pacman
Administrator group: wheel
Resolver: systemd-resolved
Time provider: systemd-timesyncd
BLOCKED realmd: no configured-repository mapping
BLOCKED adcli: no configured-repository mapping
BLOCKED autofs: no configured-repository mapping
```

The report also showed installed Kerberos, Samba, CIFS, bind, PAM, sudo,
NetworkManager, OpenSSH, and xdg-utils; SSSD and openldap are available but
not installed; chrony is available but not installed.

## `--preflight`

Exit status: `1`.

```text
PASS NetworkManager is queryable
PASS A resolver and DNS server are configured
BLOCKED System clock is not synchronized
WARNING Current hostname is not AD-safe and requires an explicit decision
BLOCKED realm command is unavailable
BLOCKED adcli command is unavailable
BLOCKED automount command is unavailable
BLOCKED ldapsearch command is unavailable
BLOCKED sssctl command is unavailable
BLOCKED Local break-glass account drone is not present
BLOCKED Preflight found 9 blocker(s); no persistent changes were made
```

The current DNS resolver did answer the Kerberos SRV probe, but that does not
replace validation against the office AD DNS path.

## `--dry-run`

Exit status: `1` because preflight blockers remain. The ordered output listed
the packages, hostname/hosts, NetworkManager search domains, time, Kerberos,
SSSD, native PAM, sudoers, Samba, nsswitch, autofs, helper, desktop, and
service changes that would be proposed after approval. It explicitly stated:

```text
WOULD NOT reboot, log out, restart a display manager, disable security controls, or run pacman -Syu
BLOCKED Dry-run plan is not executable until preflight blockers are resolved
```

## Automated/static results

```text
bash -n: PASS for production candidate, tests, backup, and rollback scripts
git diff --check: PASS
fixture regression suite: 32 tests passed
generated sudoers: visudo -cf parsed OK
shellcheck: NOT RUN — shellcheck is not installed on this host
```
