# CachyOS domain-join candidate

This feature branch contains the candidate implementation. `main`, the
production wrapper, and `ontrack.link/joindomain` are unchanged.

## Compatibility report

The inspected workstation is CachyOS (`ID=cachyos`, `ID_LIKE=arch`), rolling,
kernel `7.1.2-2-cachyos`, x86-64, with KDE Plasma in a remote xrdp X11 session.
NetworkManager and systemd-resolved are active and enabled. Wi-Fi `wlan0` is
connected through DHCP DNS `192.168.0.1`; Tailscale split DNS is also present.
systemd-timesyncd is active but not synchronized. Public NTP requests timed
out. The root filesystem is encrypted Btrfs with separate `/` and `/home`
subvolumes and 136 GiB free. Snapper has a root configuration; no snapshot was
created. The local administrator group is `wheel`. The expected `drone`
break-glass account is absent and was not created.

Shared and portable behavior: state transitions, office/tool-server policy,
hostname validation, DNS/Kerberos discovery, SSSD option rendering, CIFS
helpers, sudo validation, diagnostics, and completed-workstation protection.

Debian-family behavior: apt/dpkg locks and repair, `DEBIAN_FRONTEND`, apt
background services, PackageKit, Debian package names, `debconf-set-selections`,
`pam-auth-update`, `/etc/pam.d/common-*`, oddjob/`libpam-mkhomedir`, Debian
service names, and unattended-upgrades.

Arch-family replacements: pacman `--needed` installation without `-Syu`,
`chronyd`/`sshd`, `bind`/`openldap`, native `system-auth`/`system-login` PAM,
`wheel`, and KDE-aware desktop handling.

Desktop-dependent behavior: GDM login-list policy, GNOME dconf/gsettings,
GVFS trust metadata, wallpaper, and per-user launchers. KDE preserves user
preferences and treats desktop customization as optional.

Needs live validation: NetworkManager/resolver behavior, office AD DNS,
Kerberos SRV discovery, time synchronization, realm discovery, SSSD startup,
offline local login, domain login/home creation, sudo, CIFS, autofs, desktop
integration, KIT, and reboot persistence.

Potentially unsafe operations: hostname/DNS/NetworkManager changes, clock
stepping, PAM edits, SSSD enable/restart, sudoers writes, autofs restart,
realm join/leave, display-manager changes, logout, and reboot.

## Package mapping from configured repositories

| Capability | Debian/Ubuntu | Arch/CachyOS | Current CachyOS result |
| --- | --- | --- | --- |
| realmd | `realmd` | no configured package | BLOCKED |
| SSSD | `sssd` | `sssd` | available, not installed |
| SSSD tools | `sssd-tools` | mapped to `sssd`; verify `sssctl` | command absent |
| adcli | `adcli` | no configured package | BLOCKED |
| Kerberos | `krb5-user` | `krb5` | installed |
| Samba/winbind | `samba-common-bin`, `winbind` | `samba` | installed |
| CIFS | `cifs-utils` | `cifs-utils` | installed |
| autofs | `autofs` | no configured package | BLOCKED |
| time sync | `chrony` | `chrony` or healthy timesyncd | timesyncd unhealthy |
| DNS tools | `dnsutils` | `bind` | installed |
| LDAP tools | `ldap-utils` | `openldap` | available, not installed |
| PAM/home | `libpam-mkhomedir` or oddjob | `pam` | module present |
| NetworkManager | `network-manager` | `networkmanager` | installed |
| SSH | `openssh-server`, `ssh` | `openssh`, `sshd` | installed/active |
| Desktop helpers | `xdg-utils` | `xdg-utils` | installed |

No AUR or third-party repository was enabled. No pacman database refresh or
full-system upgrade was run. The missing realmd, adcli, and autofs capabilities
require operator approval and an approved source before a real join is proposed.

## Adapter design

`detect_platform` uses `/etc/os-release` `ID` and `ID_LIKE` and selects the
logical family `debian`, `arch`, or recognized-but-unimplemented `fedora`.
Package, service, admin-group, PAM, auth-stack, and desktop decisions are
centralized in adapter functions. Fedora is not advertised as supported.

The completed-state guard remains before office prompts, hostname changes,
package operations, NetworkManager/DNS, time, Kerberos, SSSD, and realm work.
Read-only modes are parsed before that guard so a completed machine's report,
preflight, or dry-run cannot refresh management sudo policy.

## Candidate commands

These use the feature branch raw file; the production short URL is not used:

```bash
wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh | sudo bash -s -- --platform-report
wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh | sudo bash -s -- --preflight
wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh | sudo bash -s -- --dry-run
```

Read-only modes may also run without root from a local checkout. Preflight and
dry-run return nonzero when blockers exist.

## Live-machine checkpoint

No persistent live-machine change is authorized by this branch work. Before
any package or configuration change, the operator must approve this exact
checkpoint:

- What changes: approved dependencies first, then staged configuration. PAM,
  authentication, DNS/hostname, realm membership, sudoers, autofs, and service
  changes remain separate checkpoints.
- Why: this host lacks realmd/adcli/autofs, has an unsynchronized clock, and
  lacks the expected `drone` break-glass account.
- Command:

```bash
sudo ./scripts/dr-domain-join-backup.sh --create /var/lib/dr-domain-join/backups/$(date +%Y%m%d%H%M%S)
```

- Validation and rollback rehearsal:

```bash
sudo ./scripts/dr-domain-join-backup.sh --verify /var/lib/dr-domain-join/backups/<timestamp>
sudo ./scripts/dr-domain-join-rollback.sh --dry-run /var/lib/dr-domain-join/backups/<timestamp>
```

Backup creation is local disk I/O only: it does not restart services, change
DNS, change hostname, install packages, alter PAM, or join the domain. Backups
are root-readable and may contain sensitive local configuration; never copy
them into Git or a world-readable directory. Rollback `--apply` is explicit,
does not silently leave the realm, and never removes `drone`.

## Manual validation checklist

1. Confirm a clean feature-branch worktree, a retained root-capable terminal,
   a working local `drone` (or an approved replacement), and verified backups.
2. Resolve and approve an official/approved source for realmd, adcli, and
   autofs. Do not enable AUR automatically.
3. Install only approved dependencies idempotently; do not run `pacman -Syu` as
   incidental setup.
4. Generate Kerberos, SSSD, PAM, sudoers, and autofs files into staging and
   validate them. Validate sudoers using a temporary full include structure.
5. Validate NetworkManager/resolver state, AD search behavior, Kerberos SRV,
   time synchronization, and `realm discover dr.kodr.local`.
6. At the join checkpoint record current/proposed hostname, DNS, time result,
   packages, files, service restarts, rollback command, and logout/reboot impact.
7. Let the human operator type the domain credential directly. Never store it.
8. Validate `realm list`, SSSD status, `sssctl config-check`, domain status,
   `getent`, `id`, `kinit`, `klist`, and intended `sudo -l -U` behavior.
9. Test domain login/home creation in a separate TTY or safe secondary session.
   Confirm `drone` and the existing local account still work offline.
10. Validate `dr-workstation`, CIFS Kerberos mounting, autofs, desktop
    integration, and reboot persistence. Defer KIT until separately approved.
11. Rerun normally and verify `POSTJOIN_COMPLETE` exits without prompts,
    pacman, DNS/hostname/time/PAM/SSSD/realm changes, or service restarts.

## Ubuntu/Debian regression checklist

- Supported Ubuntu/Debian detection and version rejection remain correct.
- apt locks, PackageKit, dpkg repair, package fallbacks, and unattended-upgrade
  handling remain confined to the Debian adapter.
- `common-*` PAM, oddjob/`libpam-mkhomedir`, Debian chrony/ssh/GDM, Samba,
  winbind, autofs, SSSD, sudoers, KIT, and state transitions remain unchanged.
- A completed workstation exits before provisioning mutations; only
  `--full-reconfigure` overrides it.

## Status and limitations

This branch does not claim completed CachyOS support. Real join, package
installation, PAM activation, SSSD authentication, offline local login, home
creation, sudo, CIFS/autofs, KIT, reboot persistence, and joined-system rollback
are unverified. The current machine is intentionally blocked before persistent
changes by missing approved packages, time sync, and the absent break-glass
account.

Proposed focused commits:

```text
refactor: isolate distro-specific platform operations
test: add platform and state regression coverage
feat: add CachyOS and Arch-family preflight support
feat: add CachyOS domain provisioning adapter
docs: add CachyOS validation and rollback guide
```
