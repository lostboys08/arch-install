#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 50-greeter.sh - ly, a lightweight TUI display manager.
# Provides: setup_greeter()
#
# ly reads /usr/share/wayland-sessions, so the niri session shows up on its
# own once niri is installed.

LY_CONFIG="/etc/ly/config.ini"

setup_greeter() {
    have_systemd || { skip "systemd is not running - skipping the greeter"; return 0; }

    pacman_install ly || { record_failure "Could not install ly"; return 0; }

    _greeter_check_conflicts || return 0
    _greeter_configure

    enable_unit ly.service

    if [[ ! -f /usr/share/wayland-sessions/niri.desktop ]]; then
        warn "No niri session file yet - ly will only list what is installed"
    fi
}

# Never fight another display manager: /etc/systemd/system/display-manager.service
# is a symlink to whichever one is enabled.
_greeter_check_conflicts() {
    local link=/etc/systemd/system/display-manager.service
    [[ -L $link ]] || return 0

    local current
    current=$(basename "$(readlink -f "$link")")
    if [[ $current == ly.service ]]; then
        skip "ly is already the active display manager"
        return 0
    fi

    warn "$current is currently the display manager"
    log "Switch to ly by hand with: sudo systemctl disable $current && sudo systemctl enable ly.service"
    return 1
}

# ly's config keys have moved between releases, so only touch keys that the
# installed version already ships.
_greeter_configure() {
    [[ -f $LY_CONFIG ]] || { skip "No $LY_CONFIG - using ly's built-in defaults"; return 0; }

    sudo cp -a "$LY_CONFIG" "$LY_CONFIG.prymx.bak" 2>/dev/null || true

    set_ini_key_if_present "$LY_CONFIG" "animation"        "none"
    set_ini_key_if_present "$LY_CONFIG" "animate"          "false"
    set_ini_key_if_present "$LY_CONFIG" "clock"            "%F %T"
    set_ini_key_if_present "$LY_CONFIG" "hide_borders"     "true"
    set_ini_key_if_present "$LY_CONFIG" "clear_password"   "true"
    set_ini_key_if_present "$LY_CONFIG" "asterisk"         "*"
    set_ini_key_if_present "$LY_CONFIG" "blank_password"   "false"

    ok "Configured ly (previous config kept at $LY_CONFIG.prymx.bak)"
}
