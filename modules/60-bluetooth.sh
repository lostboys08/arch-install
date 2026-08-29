#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 60-bluetooth.sh - bluez and friends, only where there is a radio.
# Provides: setup_bluetooth()
#
# The desktop has no bluetooth adapter, so this no-ops there and configures
# itself on the laptop. Set PRYMX_FORCE_BLUETOOTH=1 to install regardless.

BLUETOOTH_PACKAGES=(bluez bluez-utils blueman)

setup_bluetooth() {
    if ! _has_bluetooth_radio && [[ ${PRYMX_FORCE_BLUETOOTH:-0} != 1 ]]; then
        skip "No bluetooth adapter detected - skipping (PRYMX_FORCE_BLUETOOTH=1 overrides)"
        return 0
    fi

    pacman_install "${BLUETOOTH_PACKAGES[@]}" \
        || { record_failure "Could not install the bluetooth packages"; return 0; }

    enable_unit bluetooth.service

    # Reconnect known devices automatically after a suspend/resume cycle.
    install_system_file /etc/bluetooth/main.conf.d/prymx.conf 644 <<'CONF'
# Managed by PrymX (modules/60-bluetooth.sh)
[Policy]
AutoEnable=true

[General]
FastConnectable=true
CONF
}

_has_bluetooth_radio() {
    # A bound adapter shows up here.
    compgen -G '/sys/class/bluetooth/*' >/dev/null 2>&1 && return 0
    # An unbound one still shows on the bus.
    have_cmd lsusb && lsusb 2>/dev/null | grep -qi bluetooth && return 0
    have_cmd lspci && lspci 2>/dev/null | grep -qi bluetooth && return 0
    have_cmd rfkill && rfkill list bluetooth 2>/dev/null | grep -q . && return 0
    return 1
}
