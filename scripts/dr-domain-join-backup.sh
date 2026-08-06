#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  dr-domain-join-backup.sh --dry-run [BACKUP_DIR]
  dr-domain-join-backup.sh --create BACKUP_DIR
  dr-domain-join-backup.sh --verify BACKUP_DIR

The create mode is root-only and stores a root-readable local backup. It does
not install packages, restart services, change network settings, or join AD.
USAGE
}

mode="${1:-}"
backup_dir="${2:-/var/lib/dr-domain-join/backups/current}"

case "$mode" in
    --dry-run|--create|--verify) ;;
    *) usage >&2; exit 2 ;;
esac

case "$backup_dir" in
    ""|/|/etc|/home|/root|/var|/var/lib|/var/lib/dr-domain-join)
        echo "Refusing unsafe backup directory: $backup_dir" >&2
        exit 2
        ;;
esac

files=(
    /etc/sssd/sssd.conf
    /etc/krb5.conf
    /etc/samba/smb.conf
    /etc/nsswitch.conf
    /etc/hosts
    /etc/hostname
    /etc/chrony.conf
    /etc/chrony/chrony.conf
    /etc/autofs.conf
    /etc/auto.master
    /etc/auto.master.d
    /etc/auto.net.cifs
    /etc/sudoers
    /etc/sudoers.d
    /etc/pam.d
    /etc/NetworkManager
    /etc/systemd/system/mnt-x.mount
    /etc/systemd/system/mnt-x.automount
    /etc/systemd/system/dr-domain-machine-password-renew.service
    /etc/systemd/system/dr-domain-machine-password-renew.timer
    /usr/local/sbin/dr-domain-machine-password-renew
    /usr/local/sbin/dr-tools-rebind
    /var/lib/dr-domain-join/state
)

if [ "$mode" = "--dry-run" ]; then
    echo "WOULD CREATE root-readable backup: $backup_dir"
    echo "WOULD RECORD hostname, DNS, routes, NetworkManager connections, and service state"
    for file in "${files[@]}"; do
        echo "WOULD BACK UP $file when present"
    done
    echo "WOULD RECORD Btrfs/Snapper capability without creating a snapshot"
    echo "WOULD BACK UP Arch systemd Tool Server mount and machine-renewal units when present"
    exit 0
fi

if [ "$mode" = "--verify" ]; then
    [ -d "$backup_dir" ] || { echo "Missing backup directory: $backup_dir" >&2; exit 1; }
    [ -f "$backup_dir/manifest" ] || { echo "Missing backup manifest" >&2; exit 1; }
    [ -f "$backup_dir/hostname" ] || { echo "Missing hostname record" >&2; exit 1; }
    [ -f "$backup_dir/dns-state" ] || { echo "Missing DNS record" >&2; exit 1; }
    [ -f "$backup_dir/service-state" ] || { echo "Missing service record" >&2; exit 1; }
    echo "PASS Backup structure verified: $backup_dir"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "--create requires root" >&2; exit 1; }
mkdir -p "$backup_dir/files"
chmod 700 "$backup_dir" "$backup_dir/files"

{ hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true; } > "$backup_dir/hostname"
{ hostnamectl 2>/dev/null || true; } > "$backup_dir/hostnamectl"
{ resolvectl status 2>/dev/null || true; } > "$backup_dir/dns-state"
{ nmcli general status 2>/dev/null || true; } > "$backup_dir/nmcli-general"
{ nmcli device status 2>/dev/null || true; } > "$backup_dir/nmcli-devices"
{ nmcli connection show 2>/dev/null || true; } > "$backup_dir/nmcli-connections"
{ ip address 2>/dev/null || true; } > "$backup_dir/ip-address"
{ ip route 2>/dev/null || true; } > "$backup_dir/ip-route"
{ df -hT 2>/dev/null || true; } > "$backup_dir/disk-state"
{ findmnt / 2>/dev/null || true; } > "$backup_dir/root-mount"
{ findmnt /home 2>/dev/null || true; } > "$backup_dir/home-mount"
{ systemctl list-unit-files --type=service 2>/dev/null || true; } > "$backup_dir/service-state"
{ snapper list-configs 2>/dev/null || true; } > "$backup_dir/snapper-configs"
{ btrfs subvolume list / 2>/dev/null || true; } > "$backup_dir/btrfs-subvolumes"
printf 'created=%s\n' "$(date --iso-8601=seconds)" > "$backup_dir/manifest"

for file in "${files[@]}"; do
    [ -e "$file" ] || continue
    relative="${file#/}"
    mkdir -p "$backup_dir/files/$(dirname "$relative")"
    cp -a -- "$file" "$backup_dir/files/$relative"
    printf 'backed_up=%s\n' "$file" >> "$backup_dir/manifest"
done

chmod -R go-rwx "$backup_dir"
echo "PASS Created root-readable backup: $backup_dir"
echo "No Btrfs snapshot was created; review $backup_dir/snapper-configs and create one separately if approved."
