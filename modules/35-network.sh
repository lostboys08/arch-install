#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 35-network.sh - make sure the machine has a network manager, without
# fighting the one it already has.
# Provides: setup_network()
#
# A machine installed with archinstall usually already runs NetworkManager,
# systemd-networkd or iwd. PrymX only steps in when nothing is managing the
# network at all, because two managers on one link is worse than none.

setup_network() {
    local existing
    existing=$(_network_active_manager)

    if [[ -n $existing ]]; then
        skip "$existing is already managing the network - leaving it alone"
        _network_install_tools "$existing"
        return 0
    fi

    warn "No network manager is active - installing NetworkManager"
    pacman_install networkmanager || {
        record_failure "Could not install NetworkManager"
        return 0
    }

    # iwd as the wifi backend is a deliberate non-choice: wpa_supplicant is
    # the default and needs no extra configuration.
    enable_unit NetworkManager.service
    _network_install_tools NetworkManager
}

# Which manager, if any, is running right now.
_network_active_manager() {
    have_systemd || { printf 'unknown (systemd is not running)\n'; return 0; }

    local unit
    for unit in NetworkManager.service systemd-networkd.service iwd.service connman.service; do
        if [[ $(systemctl is-active "$unit" 2>/dev/null) == active ]]; then
            printf '%s\n' "${unit%.service}"
            return 0
        fi
    done
    return 0
}

# The waybar network module calls nm-connection-editor on click; only useful
# when NetworkManager is the thing in charge.
_network_install_tools() {
    local manager=$1
    [[ $manager == NetworkManager ]] || return 0
    pacman_install nm-connection-editor || warn "Could not install nm-connection-editor"
}
