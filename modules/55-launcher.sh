#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 55-launcher.sh - vicinae, the spotlight-style launcher.
# Provides: setup_launcher()
#
# niri starts `vicinae server` at login and binds Mod+Space to
# `vicinae toggle` (see dotfiles/niri). The systemd user unit that vicinae
# ships is deliberately not enabled: outside a uwsm-managed session it
# starts without the compositor's environment, and launched applications
# then misbehave. Spawning it from niri keeps that environment intact.

# In preference order; the AUR carries a prebuilt package and a source build.
VICINAE_CANDIDATES=(vicinae-bin vicinae)

setup_launcher() {
    if have_cmd vicinae; then
        skip "vicinae is already installed"
        _launcher_note_binding
        return 0
    fi

    if ! have_cmd paru; then
        record_failure "paru is required to install vicinae from the AUR"
        return 0
    fi

    local pkg
    for pkg in "${VICINAE_CANDIDATES[@]}"; do
        log "Trying AUR package: $pkg"
        if paru -S --needed --noconfirm "$pkg"; then
            ok "Installed $pkg"
            _launcher_note_binding
            return 0
        fi
        warn "$pkg did not install"
    done

    record_failure "Could not install vicinae (tried: ${VICINAE_CANDIDATES[*]}); fuzzel remains bound to Mod+D"
}

_launcher_note_binding() {
    log "Mod+Space toggles vicinae; Mod+D still opens fuzzel as a fallback"
}
