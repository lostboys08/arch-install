#!/usr/bin/env bash
# shellcheck shell=bash
#
# 00-aur.sh - install the paru AUR helper.
# Sourced by bootstrap.sh. Provides: install_aur_helper()

# Minimal logging fallbacks so this module can also be sourced standalone.
if ! declare -F log >/dev/null 2>&1; then
    log()  { printf '  -> %s\n' "$*"; }
    ok()   { printf '  ok %s\n' "$*"; }
    warn() { printf '   ! %s\n' "$*" >&2; }
    err()  { printf '   x %s\n' "$*" >&2; }
fi

AUR_HELPER_PKG="paru-bin"
AUR_HELPER_URL="https://aur.archlinux.org/paru-bin.git"

install_aur_helper() {
    if command -v paru >/dev/null 2>&1; then
        ok "paru is already installed ($(paru --version 2>/dev/null | head -n1))"
        return 0
    fi

    log "paru not found - building $AUR_HELPER_PKG from the AUR"

    # git and base-devel are required to fetch and build any AUR package.
    if ! sudo pacman -S --needed --noconfirm git base-devel; then
        err "Could not install the build prerequisites (git, base-devel)"
        return 1
    fi

    local build_dir
    build_dir=$(mktemp -d -t paru-build-XXXXXXXX) || {
        err "Could not create a temporary build directory"
        return 1
    }

    local rc=0
    if ! git clone --depth 1 "$AUR_HELPER_URL" "$build_dir/$AUR_HELPER_PKG"; then
        err "Failed to clone $AUR_HELPER_URL"
        rc=1
    elif ! ( cd "$build_dir/$AUR_HELPER_PKG" && makepkg -si --noconfirm ); then
        err "makepkg failed while building $AUR_HELPER_PKG"
        rc=1
    fi

    rm -rf "$build_dir"

    (( rc == 0 )) || return "$rc"

    if ! command -v paru >/dev/null 2>&1; then
        err "$AUR_HELPER_PKG was built but paru is still not on PATH"
        return 1
    fi

    ok "paru installed"
}
