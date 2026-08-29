#!/usr/bin/env bash
# shellcheck shell=bash
#
# 30-sysctl.sh - kernel tunables for gaming workloads.
# Sourced by bootstrap.sh. Provides: apply_sysctl_tweaks()

if ! declare -F log >/dev/null 2>&1; then
    log()  { printf '  -> %s\n' "$*"; }
    ok()   { printf '  ok %s\n' "$*"; }
    warn() { printf '   ! %s\n' "$*" >&2; }
    err()  { printf '   x %s\n' "$*" >&2; }
fi

SYSCTL_FILE="/etc/sysctl.d/99-gaming.conf"

apply_sysctl_tweaks() {
    log "Writing $SYSCTL_FILE"

    if ! sudo tee "$SYSCTL_FILE" >/dev/null <<'CONF'
# Managed by arch-install/modules/30-sysctl.sh

# Several games and Proton/Wine titles map a very large number of memory
# regions; the kernel default is far too low for them.
vm.max_map_count = 2147483642

# Prefer keeping pages in RAM on a desktop with plenty of memory.
vm.swappiness = 10
CONF
    then
        err "Could not write $SYSCTL_FILE"
        return 1
    fi

    sudo chmod 644 "$SYSCTL_FILE"

    if sudo sysctl --system >/dev/null; then
        ok "sysctl settings applied"
    else
        err "sysctl --system failed"
        return 1
    fi

    log "vm.max_map_count = $(sysctl -n vm.max_map_count)"
    log "vm.swappiness    = $(sysctl -n vm.swappiness)"
}
