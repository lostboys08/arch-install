#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 10-snapper.sh - Btrfs snapshots (snapper + snap-pac + grub-btrfs).
# Provides: setup_snapper(), snapshot_pre_bootstrap()

SNAPPER_PACKAGES=(snapper snap-pac grub-btrfs inotify-tools)

setup_snapper() {
    if ! is_btrfs_root; then
        skip "Root filesystem is '$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)', not btrfs - skipping snapper"
        return 0
    fi
    ok "Root filesystem is btrfs"

    pacman_install "${SNAPPER_PACKAGES[@]}" || {
        err "Could not install the snapper packages"
        return 1
    }

    _snapper_create_root_config || return 1
    _snapper_tune_root_config
    enable_unit snapper-timeline.timer
    enable_unit snapper-cleanup.timer
    _snapper_enable_grub_btrfsd
}

# Called by bootstrap.sh before it starts changing the system.
snapshot_pre_bootstrap() {
    snapper_snapshot "prymx-pre-bootstrap-$(date +%F-%T)" || true
    return 0
}

# Create the 'root' config for / and repair the /.snapshots mount that
# `create-config` replaces with a fresh subvolume.
_snapper_create_root_config() {
    if sudo snapper list-configs 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx root; then
        skip "Snapper config 'root' already exists"
        return 0
    fi

    local snapshots_in_fstab=0
    grep -Eq '^[^#].*[[:space:]]/\.snapshots[[:space:]]' /etc/fstab && snapshots_in_fstab=1

    # snapper refuses to create the config while /.snapshots is a mount point.
    if (( snapshots_in_fstab )) && mountpoint -q /.snapshots; then
        log "Unmounting the existing /.snapshots subvolume"
        sudo umount /.snapshots || { err "Could not unmount /.snapshots"; return 1; }
        sudo rm -rf /.snapshots
    fi

    log "Creating snapper config 'root' for /"
    sudo snapper -c root create-config / || { err "snapper create-config failed"; return 1; }

    if (( snapshots_in_fstab )); then
        # create-config made a new @/.snapshots subvolume; drop it and remount
        # the subvolume /etc/fstab points at.
        log "Restoring the /.snapshots mount from /etc/fstab"
        sudo btrfs subvolume delete /.snapshots >/dev/null 2>&1 || true
        sudo mkdir -p /.snapshots
        sudo mount -a || warn "mount -a reported an error; check /.snapshots manually"
    fi

    sudo chmod 750 /.snapshots 2>/dev/null || true
    sudo chown :wheel /.snapshots 2>/dev/null || true
    ok "Snapper config 'root' created"
}

# Desktop-sized timeline, and let the invoking user read snapshots.
_snapper_tune_root_config() {
    local setting
    for setting in \
        "ALLOW_USERS=$USER" \
        "SYNC_ACL=yes" \
        "TIMELINE_CREATE=yes" \
        "TIMELINE_CLEANUP=yes" \
        "NUMBER_CLEANUP=yes" \
        "NUMBER_LIMIT=20" \
        "NUMBER_LIMIT_IMPORTANT=10" \
        "TIMELINE_LIMIT_HOURLY=5" \
        "TIMELINE_LIMIT_DAILY=7" \
        "TIMELINE_LIMIT_WEEKLY=0" \
        "TIMELINE_LIMIT_MONTHLY=0" \
        "TIMELINE_LIMIT_YEARLY=0"
    do
        sudo snapper -c root set-config "$setting" \
            || warn "Could not apply snapper setting: $setting"
    done
    ok "Snapper 'root' config tuned"
}

# grub-btrfsd regenerates the GRUB menu when snapshots appear; only useful
# when GRUB is actually the bootloader.
_snapper_enable_grub_btrfsd() {
    if ! have_cmd grub-mkconfig; then
        skip "GRUB is not installed - skipping grub-btrfsd"
        return 0
    fi

    enable_unit grub-btrfsd

    if [[ -d /boot/grub ]]; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
            && ok "Regenerated /boot/grub/grub.cfg" \
            || warn "Could not regenerate the GRUB configuration"
    fi
}
