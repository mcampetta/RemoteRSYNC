#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  dr-domain-join-rollback.sh --dry-run BACKUP_DIR
  dr-domain-join-rollback.sh --apply BACKUP_DIR [--restart-services]

Apply restores backed-up configuration and hostname state. It does not leave
the AD realm, delete a keytab, remove users, or remove the drone account.
Realm cleanup is a separate human-approved action.
USAGE
}

mode="${1:-}"
backup_dir="${2:-}"
restart_services=false
[ "${3:-}" = "--restart-services" ] && restart_services=true

case "$mode" in
    --dry-run|--apply) ;;
    *) usage >&2; exit 2 ;;
esac
[ -n "$backup_dir" ] || { usage >&2; exit 2; }
[ -d "$backup_dir/files" ] || { echo "Invalid backup directory: $backup_dir" >&2; exit 1; }
[ -f "$backup_dir/manifest" ] || { echo "Backup manifest is missing" >&2; exit 1; }

restore_files=(
    etc/sssd/sssd.conf
    etc/krb5.conf
    etc/samba/smb.conf
    etc/nsswitch.conf
    etc/hosts
    etc/hostname
    etc/chrony.conf
    etc/chrony/chrony.conf
    etc/autofs.conf
    etc/auto.master
    etc/auto.master.d
    etc/auto.net.cifs
    etc/sudoers
    etc/sudoers.d
    etc/pam.d
    etc/NetworkManager
    var/lib/dr-domain-join/state
)

if [ "$mode" = "--dry-run" ]; then
    echo "WOULD RESTORE files from $backup_dir/files"
    for relative in "${restore_files[@]}"; do
        [ -e "$backup_dir/files/$relative" ] && echo "WOULD RESTORE /$relative"
    done
    echo "WOULD VALIDATE sudoers before any service action"
    echo "WOULD NOT leave the realm, delete /etc/krb5.keytab, remove users, remove drone, reboot, or log out"
    if [ "$restart_services" = true ]; then
        echo "WOULD RESTART only explicitly requested services after restore"
    fi
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "--apply requires root" >&2; exit 1; }
echo "Applying configuration rollback from: $backup_dir"
echo "This restores files but does not leave the domain or remove local accounts."

for relative in "${restore_files[@]}"; do
    source_path="$backup_dir/files/$relative"
    target_path="/$relative"
    [ -e "$source_path" ] || continue

    if [ -d "$source_path" ]; then
        mkdir -p "$target_path"
        cp -a -- "$source_path/." "$target_path/"
    else
        mkdir -p "$(dirname "$target_path")"
        cp -a -- "$source_path" "$target_path"
    fi
done

if [ -f /etc/sudoers ]; then
    visudo -cf /etc/sudoers >/dev/null
fi

if [ -f "$backup_dir/hostname" ]; then
    restored_hostname="$(head -n1 "$backup_dir/hostname")"
    if [ -n "$restored_hostname" ]; then
        hostnamectl set-hostname "$restored_hostname"
    fi
fi

if [ "$restart_services" = true ]; then
    systemctl daemon-reload
    for service in NetworkManager systemd-resolved chronyd chrony systemd-timesyncd sssd winbind autofs; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            systemctl restart "$service"
        fi
    done
else
    echo "Configuration restored. Services were not restarted. Review and restart each affected service during an approved maintenance step."
fi

echo "PASS Rollback file restore completed"
