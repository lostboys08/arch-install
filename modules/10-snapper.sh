#!/usr/bin/env bash
# shellcheck shell=bash
#
# 10-snapper.sh - Btrfs snapshot support via snapper + snap-pac + grub-btrfs.
# Sourced by bootstrap.sh. Provides: setup_snapper()

if ! declare -F log >/dev/null 2>&1; then
    log()  { printf '  -> %s\n' "$*"; }
    ok()   { printf '  ok %s\n' "$*"; }
    warn() { printf '   ! %s\n' "$*" >&2; }
    err()  { printf '   x %s\n' "$*" >&2; }
fi

SNAPPER_PACKAGES=(snapper snap-pac grub-btrfs inotify-tools)

setup_snapper() {
    local fstype
    fstype=$(findmnt -no FSTYPE / 2>/dev/null || true)

    if [[ $fstype != btrfs ]]; then
        warn "Root filesystem is '${fstype:-unknown}', not btrfs - skipping snapper setup"
        return 0
    fi
    ok "Root filesystem is btrfs"

    log "Installing: ${SNAPPER_PACKAGES[*]}"
    if ! sudo pacman -S --needed --noconfirm "${SNAPPER_PACKAGES[@]}"; then
        err "Could not install the snapper packages"
        return 1
    fi

    _snapper_create_root_config || return 1
    _snapper_tune_root_config
    _snapper_enable_timers
    _snapper_enable_grub_btrfsd
}

# Create the 'root' config for / and repair the /.snapshots mount that
# `create-config` replaces with a fresh subvolume.
_snapper_create_root_config() {
    if sudo snapper list-configs 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx root; then
        ok "Snapper config 'root' already exists"
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
    if ! sudo snapper -c root create-config /; then
        err "snapper create-config failed"
        return 1
    fi

    if (( snapshots_in_fstab )); then
        # create-config made a new @/.snapshots subvolume; drop it and remount
        # the subvolume that /etc/fstab points at.
        log "Restoring the /.snapshots mount from /etc/fstab"
        sudo btrfs subvolume delete /.snapshots >/dev/null 2>&1 || true
        sudo mkdir -p /.snapshots
        sudo mount -a || warn "mount -a reported an error; check /.snapshots manually"
    fi

    sudo chmod 750 /.snapshots 2>/dev/null || true
    sudo chown :wheel /.snapshots 2>/dev/null || true

    ok "Snapper config 'root' created"
}

# Opinionated defaults: let the current user read snapshots and keep the
# timeline small enough for a desktop.
_snapper_tune_root_config() {
    local setting
    for setting in \
        "ALLOW_USERS=${USER:-$(id -un)}" \
        "TIMELINE_CREATE=yes" \
        "TIMELINE_CLEANUP=yes" \
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

_snapper_enable_timers() {
    local timer
    for timer in snapper-timeline.timer snapper-cleanup.timer; do
        if sudo systemctl enable --now "$timer" >/dev/null 2>&1; then
            ok "Enabled $timer"
        else
            warn "Could not enable $timer"
        fi
    done
}

# grub-btrfsd regenerates the GRUB menu when snapshots appear; only useful
# when GRUB is actually the bootloader.
_snapper_enable_grub_btrfsd() {
    if ! command -v grub-mkconfig >/dev/null 2>&1; then
        warn "GRUB is not installed - skipping grub-btrfsd"
        return 0
    fi

    if sudo systemctl enable --now grub-btrfsd >/dev/null 2>&1; then
        ok "Enabled grub-btrfsd"
    else
        warn "Could not enable grub-btrfsd"
    fi

    if [[ -d /boot/grub ]]; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
            && ok "Regenerated /boot/grub/grub.cfg" \
            || warn "Could not regenerate the GRUB configuration"
    fi
}
