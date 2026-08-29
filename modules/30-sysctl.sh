#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 30-sysctl.sh - kernel tunables for gaming workloads.
# Provides: apply_sysctl_tweaks()

SYSCTL_FILE="/etc/sysctl.d/99-gaming.conf"

apply_sysctl_tweaks() {
    install_system_file "$SYSCTL_FILE" 644 <<'CONF' || return 1
# Managed by PrymX (modules/30-sysctl.sh)

# Several games and Proton/Wine titles map a very large number of memory
# regions; the kernel default is far too low for them.
vm.max_map_count = 2147483642

# Prefer keeping pages in RAM on a desktop with plenty of memory.
vm.swappiness = 10
CONF

    if sudo sysctl --system >/dev/null; then
        ok "sysctl settings applied"
    else
        err "sysctl --system failed"
        return 1
    fi

    log "vm.max_map_count = $(sysctl -n vm.max_map_count)"
    log "vm.swappiness    = $(sysctl -n vm.swappiness)"
}
