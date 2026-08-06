# CachyOS domain-join candidate

This feature branch contains the CachyOS/Arch-family candidate. `main`,
`domain-join-latest.sh` on `main`, the production wrapper, and
`ontrack.link/joindomain` are unchanged.

The candidate does not claim completed CachyOS support. No package was
installed and no live configuration, service, network, PAM, SSSD, hostname,
DNS, Kerberos, sudoers, mount, or domain-membership change was made during
this revision.

## Revised architecture

Platform detection uses `/etc/os-release` `ID` and `ID_LIKE` and selects the
families `debian`, `arch`, or recognized-but-unimplemented `fedora`.
Debian/Ubuntu continue to use the existing realmd/adcli flow and traditional
autofs implementation. Arch/CachyOS uses:

- Samba ADS (`net ads`) for discovery, interactive Kerberos authentication,
  computer-account join/update, testjoin, leave, and machine-keytab creation.
- SSSD's AD provider for NSS, PAM, identity, authentication, groups, and
  cached credentials. Winbind is not enabled or started.
- Native Arch PAM files (`system-auth`/`system-login`) with `pam_sss` and the
  installed `pam_mkhomedir` module.
- Native systemd `.mount` and `.automount` units for `/mnt/x`.
- Configured-root Arch DRIP support: persisted DR_DRIP_SEARCH_ROOTS entries
  generate exact /smb/<server>/<share> systemd mount/automount pairs with
  cruid=0. Arbitrary dynamic /smb and all /net semantics remain unsupported;
  /mnt/p remains exclusively owned by native KIT.
- KDE-aware optional desktop integration. Desktop customization failures do
  not fail core provisioning.

The `POSTJOIN_COMPLETE` guard remains before office prompts, hostname changes,
package operations, NetworkManager/DNS, time, Kerberos, PAM, SSSD, mount, or
domain operations. Only the existing explicit `--full-reconfigure` override
can bypass it.

## Configured-repository package mapping

The current configured repositories report these Arch mappings:

| Classification | Capability | Arch package/status |
| --- | --- | --- |
| Core AD login | SSSD | `sssd`, available, not installed |
| Core AD login | Kerberos | `krb5`, installed |
| Core AD login | PAM/home creation | `pam`, installed; `pam_mkhomedir.so` present |
| Core AD login | local admin tooling | `sudo`, installed |
| Arch join backend | Samba ADS | `samba`, installed |
| Arch join backend | Samba client/net utility | `smbclient`, installed and supplied by the Samba package set |
| Tool Server mounting | CIFS helper | `cifs-utils`, installed |
| DNS/discovery | resolver tools | `bind`, installed |
| Time provider fallback | chrony | `chrony` available; active/enabled `systemd-timesyncd` satisfies the capability on this host |
| SSH handoff | OpenSSH | `openssh`, installed |
| Diagnostics only | `sssctl` | `/usr/bin/sssctl` is in the official `sssd` file list; live install validation remains pending |
| Diagnostics only | `ldapsearch` | `/usr/bin/ldapsearch` is in the official `openldap` file list; live install validation remains pending |
| Optional desktop | desktop helpers | `xdg-utils`, installed |
| Unavailable but no longer required | realmd | no configured package; not used on Arch |
| Unavailable but no longer required | adcli | no configured package; not used on Arch |
| Unavailable but no longer required | userspace autofs | no configured package; replaced by systemd automount |
| Unavailable but no longer required | winbind | no Arch dependency; SSSD remains the identity stack |

The Arch installer requests only the core/join/mount packages. It never runs
`pacman -Syu` as incidental setup. `openldap` remains optional diagnostics; an
Arch join does not use LDAP computer-object allocation.

Arch DRIP is configured-root support, not arbitrary autofs replacement:

    DR_DRIP_SEARCH_ROOTS="dr-ep-drip04/Images"

This creates /smb/dr-ep-drip04/Images -> //dr-ep-drip04/Images on demand.
Multiple server/share roots are supported, strictly validated, named with
systemd-escape --path, verified with systemd-analyze verify, and listed in
the root-owned manifest. /smb/dr-ep-drip04/Images/test is supported after
live validation; /smb/dr-ep-drip04/ImageFolders/test and
/net/dr-ep-drip04/ImageFolders/test remain blocked unless separately
configured under the exact /smb root contract. The Arch launcher starts only
configured automounts for a KIT run and safely stops them afterward. Native
KIT alone creates and removes /mnt/p.

## Samba 4.24 join and keytab strategy

The installed Samba version is 4.24.5. Its local documentation states that
`net ads keytab add` is removed after Samba 4.20 and that keytab content is
declared with `sync machine password to keytab`, then created with
`net ads keytab create`.

The generated Arch `/etc/samba/smb.conf` contains the equivalent of:

```ini
[global]
    workgroup = DR
    realm = DR.KODR.LOCAL
    security = ADS
    client ipc signing = required
    client min protocol = SMB2
    idmap config * : backend = tdb
    idmap config * : range = 100000-199999
    kerberos method = secrets only
    sync machine password to keytab = /etc/krb5.keytab:spn_prefixes=host:account_name:sync_spns:sync_kvno:machine_password
```

The declarative rule generates `/etc/krb5.keytab` from the Samba machine
secret and synchronizes the host/SPN entries without relying on legacy
`net ads keytab add` behavior. The keytab is root-owned and mode 600.

Machine-account renewal has one Arch authority: the generated
dr-domain-machine-password-renew.timer. It runs daily with Persistent=true
and a randomized delay, but a root-owned timestamp prevents rotation until
25 days have elapsed. Reboot does not itself rotate the password. SSSD's
default 30-day renewal is disabled with ad_maximum_machine_account_password_age
= 0 because Arch's SSSD realm/adcli renewal helper is unavailable.
ad_update_samba_machine_account_password is explicitly false.

The normal sequence applies the 25-day age gate first, then checks synchronized
time, AD DNS SRV and controller reachability, testparm, keytab access, free
space, the renewal lock, and sssctl when present; then it runs net ads testjoin, net ads changetrustpw -P,
bounded retries of net ads keytab create, klist/keytab principal validation,
net ads testjoin, a safe SSSD refresh, and an atomic success timestamp. If
password rotation succeeds but keytab regeneration fails, a persistent repair
marker and diagnostic copy of the old keytab are retained. The old keytab is
not a rollback of the AD password. The normal timer services the marker, and
the explicit --repair-keytab mode rebuilds from the current Samba secret
without rotating the password again.

After DNS, time, hostname, Kerberos, and package checkpoints pass, the human
domain administrator runs the generated helper. Its sequence is:

```text
kdestroy
kinit ADMIN_USER@DR.KODR.LOCAL                 # password entered by the human
net ads join --use-kerberos=required           # creates or updates computer account
net ads testjoin                               # validates local membership
net ads keytab create                          # creates /etc/krb5.keytab
klist -k /etc/krb5.keytab
```

No password is passed on a command line, put in an environment variable, or
written to a file. The explicit leave path is
`net ads leave --use-kerberos=required` with a human-provided Kerberos ticket.
The helper's rollback prompt can remove local keytab/SSSD state and attempt an
AD leave; it does not silently remove the AD computer object.

## SSSD strategy

Arch generates a complete SSSD configuration after the join and before SSSD
is enabled. The relevant settings are:

```ini
[sssd]
services = nss, pam
domains = dr.kodr.local

[domain/dr.kodr.local]
id_provider = ad
ad_domain = dr.kodr.local
krb5_realm = DR.KODR.LOCAL
use_fully_qualified_names = False
access_provider = simple
ad_enable_gc = false
ldap_id_mapping = True
cache_credentials = True
fallback_homedir = /home/%u
krb5_ccname_template = FILE:/tmp/krb5cc_%U
ad_maximum_machine_account_password_age = 0
ad_update_samba_machine_account_password = false
```

This preserves short domain-user names and SSSD UID/GID mapping. PAM changes
are native Arch changes only; Debian `/etc/pam.d/common-*` files are never
copied to Arch. Local `pam_unix` authentication remains in the native stack.

## Tool Server systemd automount

The established path remains `/mnt/x`, backed by `//<office>-tools/Tools`.
Arch generates units whose names are obtained with `systemd-escape`:

```text
mnt-x.mount
mnt-x.automount
```

The mount unit uses:

```ini
[Mount]
What=//dr-ep1-tools/Tools
Where=/mnt/x
Type=cifs
Options=_netdev,nofail,sec=krb5,cruid=<logged-in-domain-user-uid>,vers=3.0
TimeoutSec=30s
```

The automount unit uses `TimeoutIdleSec=300s`. The automount itself has no
network ordering dependency, so boot is not blocked; the mount unit waits for
`network-online.target` and a failed access can be retried after network
recovery. No password or domain credential is embedded. The Arch adapter uses
the known-good `cruid` ownership model instead of unproven `multiuser`: the
mount is created for the selected/logged-in domain user's credential cache, and
root KIT helpers access the resulting filesystem mount. `mount-kit-tools`
passes that UID through its narrow sudo rule, verifies the user's Kerberos
cache, starts the automount, and triggers access. `platform_verify_tools_mount`
uses `systemd-analyze verify` and systemd state checks. The explicit uninstall
adapter stops/disables both units, removes them, and reloads systemd.

The required staged KIT test is more than a normal-user `ls`:

```bash
klist -s && ls -la /mnt/x
sudo -n /usr/local/bin/mount-kit-tools --cruid "$(id -u <domain-user>)"
sudo -n /usr/local/bin/mount-kit-tools --access-self-test
sudo -n /usr/local/sbin/dr-post-mount-provision --access-self-test
sudo -n /usr/local/sbin/dr-launch-kit --access-self-test
```

The last two helpers run as root and verify that the KIT installer, `KIT.sh`,
and runtime files are readable through `/mnt/x`. A harmless executable fixture
must also be run as root from the mounted share during live validation. Any
`sudo sh`/fixture command belongs to the retained root-capable recovery
terminal; it is not granted by the domain-user `mount-kit-tools` sudo rule.

### KIT credential-cache ownership

The shared `KIT.sh` is not modified. The launcher preserves only
`KRB5CCNAME` for the exact `/usr/local/sbin/dr-launch-kit` sudo command through
a command-scoped `env_keep` rule. `SUDO_UID` and `SUDO_USER` continue to be
provided by sudo. Before launching `KIT.sh`, the root launcher requires:

- a nonzero `SUDO_UID`;
- a `FILE:` cache that is a regular non-symlink file owned by `SUDO_UID`;
- mode 0600 or stricter;
- `klist -s -c <cache>` success; and
- a default principal in `DR.KODR.LOCAL`, with the path not equal to
  `/tmp/krb5cc_0`.

The provisioning launcher never creates or overwrites `/tmp/krb5cc_0`.
`KIT.sh` remains solely responsible for copying the invoking user's cache to
that root-owned path, adding CIFS service tickets, and removing it through its
existing EXIT trap. A live validation must therefore prove the whole lifecycle:
the cache is visible before launch, the exact `KRB5CCNAME` survives sudo, the
KIT process is UID 0 with the invoking user's `SUDO_UID`, KIT creates the root
cache with the matching principal, DRIP search adds a `cifs/<server>` ticket,
`/smb/<server>/Images` and `/mnt/p` work with `cruid=0`, a bounded root read and
execution succeed, deactivation removes `/mnt/p`, and KIT exit removes the
root cache.

The known-good Ubuntu ownership model remains explicit: DRIP `/smb` and
`/mnt/p` use `sec=krb5,cruid=0`; `/mnt/x` uses
`sec=krb5,cruid=<domain-user-uid>,vers=3.0`. A normal-user `ls` is not enough
to validate KIT access.

### Arch `/mnt/x` multi-user boundary

Arch's systemd mount is deliberately bound to one selected domain-user UID;
the adapter does not claim shared multi-user `/mnt/x` semantics. The generated
`mount-kit-tools` helper reads the current `cruid` from the mount unit and
refuses a different invoking UID. A local administrator must explicitly stop
the automount and run:

```bash
sudo /usr/local/sbin/dr-tools-rebind <new-domain-user-uid>
```

The helper is transactional: it locks, refuses active KIT or `/mnt/p` use,
records unit bytes and active/enabled state, stops the automount before the
mount, stages and verifies a complete replacement, atomically installs it,
updates the root-owned UID state, and restores both unit bytes and state on
any failure. It has `--dry-run` and `--status` modes and bounded failure
injection fixtures. No lazy or force unmount is used.

Debian keeps the existing dynamic `/smb` and `/net` autofs maps, including
`sec=krb5,cruid=${UID},vers=3.0`, and the existing autofs service behavior.

The launcher also exposes a non-launching credential check through the same
command-scoped sudo path:

    sudo -n /usr/local/sbin/dr-launch-kit --credential-self-test

It validates the exact cache basename contract, owner UID, mode, principal,
FILE type, ticket validity, and cache identity before and after parsing. It
prints only sanitized evidence and never creates or touches /tmp/krb5cc_0.
The existing --sudo-self-test and --access-self-test remain convenience
checks, not proof that KRB5CCNAME survived sudo.

## Configured-root Arch DRIP lifecycle

The Arch DRIP adapter owns only configured search roots. It generates a
root-owned manifest and exact pairs named with systemd-escape --path, such as
the mount and automount units for /smb/dr-ep-drip04/Images.

The launcher validates the invoking FILE cache, starts only those automount
units without touching their target paths, launches the unchanged KIT.sh, and
stops automounts before mounts on exit. Busy cleanup is reported and retained
for diagnosis. The adapter never creates, removes, or inspects /mnt/p, and
never creates, copies, renames, or removes /tmp/krb5cc_0.

Configured-root support does not reproduce arbitrary autofs behavior. A path
outside a configured /smb/server/share root and every /net path are
unsupported on Arch. Native KIT remains solely responsible for activation,
the /mnt/p mount, deactivation, and the root-cache lifecycle.

## Break-glass account

Production defaults to:

```bash
DR_LOCAL_ADMIN_USER="${DR_LOCAL_ADMIN_USER:-drone}"
```

The candidate machine has no `drone` account, and the script does not create
one. An engineer may explicitly set an existing local account, for example:

```bash
DR_LOCAL_ADMIN_USER=martin \
  wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh \
  | sudo env DR_LOCAL_ADMIN_USER=martin bash -s -- --preflight
```

Before any PAM or SSSD change, the operator must verify manually that the
override is a local `/etc/passwd` account, has a working local password, is in
`wheel`, can obtain root without SSSD, can log in while SSSD is stopped, and
will remain available in a separate privileged terminal. The script prints
the account, source, administrator group, and `Password status: operator
verification required`; it never tests or records the password.

## Current time diagnosis

The host currently reports:

```text
Active provider:  systemd-timesyncd
Enabled provider: systemd-timesyncd
Synchronized:    no
Server:          time.cloudflare.com
Packet count:    0
Journal:         repeated UDP/123 timeouts
Kerberos impact: BLOCKED
```

The candidate does not switch providers or change NTP servers. Preflight keeps
an unsynchronized clock as a hard blocker and prints the proposed correction:
check UDP/123 reachability and approved AD NTP sources, then make an
operator-approved repair of the active provider. The current candidate host
has not had that correction applied.

## Read-only modes and captured result

```bash
wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh | sudo bash -s -- --platform-report
wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh | sudo bash -s -- --preflight
wget -qO- https://raw.githubusercontent.com/mcampetta/RemoteRSYNC/feature/cachyos-domain-join/domain-join-latest.sh | sudo bash -s -- --dry-run
```

Current host results after this revision:

- --platform-report: exit 0. CachyOS is detected as Arch; realmd, adcli,
  autofs, and winbind are reported unavailable but not required. Configured
  /smb root support is reported separately from arbitrary dynamic paths.
- --preflight: exit 1. With DR_LOCAL_ADMIN_USER=martin, current blockers are
  the unsynchronized clock and failed current-resolver AD SRV/domain
  discovery. Configured DRIP syntax passes; live DRIP/KIT validation remains
  pending. Missing sssctl and ldapsearch are warnings pending package
  validation. With production default drone, the absent break-glass account
  is an additional blocker.
- DR_LOCAL_ADMIN_USER=martin --preflight: the account is reported as local
  and in wheel; password verification remains manual. Time, DNS, and domain
  discovery remain blockers.
- --dry-run: exit 1 and prints the Arch Samba/systemd ordered plan, configured
  /smb roots, cruid ownership model, and machine-renewal timer. It explicitly
  reports no reboot, logout, display-manager restart, security disablement,
  or pacman -Syu.

## Package-install checkpoint — not approved or executed

After the current preflight blockers are resolved and the operator approves
the dependency checkpoint, the exact core command is:

```bash
sudo pacman -S --needed sssd krb5 samba smbclient cifs-utils bind pam sudo openssh
```

If the approved time plan selects chrony instead of repairing the existing
timesyncd provider, install it separately at that checkpoint:

```bash
sudo pacman -S --needed chrony
```

Do not append `-Syu` without a separate explicit approval. `openldap` is an
optional diagnostic install:

```bash
sudo pacman -S --needed openldap
```

Immediately validate package signatures, command availability (`sssctl`,
`ldapsearch`, `net`, `testparm`, `klist`, `mount.cifs`), `testparm`, and the
staged SSSD/Kerberos/systemd files. No PAM, DNS, hostname, service, or join
change belongs in this checkpoint.

## Backup and rollback

Before any persistent live change, retain a root shell and run:

```bash
sudo ./scripts/dr-domain-join-backup.sh --create /var/lib/dr-domain-join/backups/$(date +%Y%m%d%H%M%S)
sudo ./scripts/dr-domain-join-backup.sh --verify /var/lib/dr-domain-join/backups/<timestamp>
sudo ./scripts/dr-domain-join-rollback.sh --dry-run /var/lib/dr-domain-join/backups/<timestamp>
```

The backup is root-readable and includes existing network/DNS/hostname/service
state, relevant configuration, the Arch mnt-x.mount/mnt-x.automount units,
configured DRIP units from the root-owned manifest, the DRIP helper, live
validation markers, and the Arch machine-renewal service/timer when present.
It does not copy domain passwords or put secrets in Git. No Btrfs
snapshot was created; Snapper has a root configuration and a separate,
operator-approved snapshot decision is still required.

An explicit file rollback is:

```bash
sudo ./scripts/dr-domain-join-rollback.sh --apply /var/lib/dr-domain-join/backups/<timestamp>
```

This stops/removes candidate systemd units, restores backed-up files, checks
sudoers, restores the recorded hostname, and leaves services stopped for
review unless `--restart-services` is explicitly requested. It does not leave
AD, delete `/etc/krb5.keytab`, remove users, remove `drone`, reboot, or log
out. Domain membership rollback remains the human-approved Samba leave path.

## Manual validation checklist

1. Resolve DNS against the office AD DNS path and repair/synchronize time with
   explicit operator approval; keep the current root-capable terminal open.
2. Confirm a clean feature-branch worktree, current backups, local break-glass
   login, and any approved Btrfs snapshot.
3. Approve and install only the exact dependencies above; do not full-upgrade
   the system incidentally.
4. Stage and validate Kerberos, SSSD, native PAM, sudoers, Samba, and both
   systemd units. Use `testparm`, `systemd-analyze verify`, and `visudo`.
5. Validate DNS SRV records, `kinit` readiness, and Samba discovery without a
   join. Do not run `net ads join` until the join checkpoint is presented.
6. At the credential boundary, let the human operator type the domain
   credential into `kinit`; never pass or record it.
7. Validate `net ads testjoin`, `net ads keytab create`, `klist -k`,
   `sssctl config-check`, `sssctl domain-status`, SSSD status, `getent`, `id`,
   and intended sudo policy.
8. Test domain login and home creation from a separate TTY/secondary session;
   test the local break-glass and existing personal account with network
   disconnected or SSSD unavailable before closing recovery access.
9. On Arch, validate the configured root `/smb/dr-ep-drip04/Images`, confirm
   `/smb/dr-ep-drip04/ImageFolders/test` and
   `/net/dr-ep-drip04/ImageFolders/test` remain outside the claimed scope,
   then perform the full root KIT cache lifecycle, cifs ticket, activation
   `/mnt/p`, bounded-read, cleanup, and reboot tests. Record each phase with
   `dr-domain-join-live-validate --record STATE`.
10. Do not record `POSTJOIN_COMPLETE` until every required live marker exists.
    Rerun the candidate only after completion and verify the guard exits
    without office prompts, pacman, DNS/hostname/time/PAM/SSSD changes,
    service restarts, or Samba join operations.

## Ubuntu/Debian regression checklist

- Detection/version checks for Ubuntu/Debian remain unchanged.
- The existing apt/dpkg, PackageKit, unattended-upgrades, `debconf`,
  `pam-auth-update`, common-PAM, oddjob/libpam-mkhomedir, chrony, GDM,
  realmd/adcli, winbind, and autofs paths remain Debian-only.
- Debian still allocates hostnames authoritatively through its existing LDAP
  and realmd/adcli helper.
- Shared office selection, state transitions, SSSD options, sudoers, KIT,
  diagnostics, and the completed-workstation guard remain covered by fixture
  tests.

## Status and known limitations

Static and read-only validation is passing: the fixture suite reports 189
tests, including configured-root DRIP units, cache-path/TOCTOU validation,
command-scoped sudoers, transactional Arch rebind coverage, Samba renewal
repair policy, completion gating, Debian autofs, and Ubuntu KIT compatibility.
ShellCheck remains unrun because the host does not have `shellcheck` installed;
installing it is intentionally outside this no-live-change phase. The real
package install, Samba join, SSSD/PAM activation, local fallback login, domain
login/home creation, sudo, Kerberos CIFS mount, automount recovery after
reboot, KIT, configured-root DRIP, and completed-state rerun have not been
validated on CachyOS. In particular, the sec=krb5,cruid=... systemd mount
behavior, root KIT cache lifecycle, machine-password renewal, configured
/smb root lifecycle, and the actual Tool Server must be tested with real SSSD
credential caches. Arch does not claim arbitrary dynamic /smb or /net behavior.

Do not advertise or merge this branch as complete until those live tests pass.
