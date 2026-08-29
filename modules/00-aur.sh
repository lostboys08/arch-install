#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 00-aur.sh - the paru AUR helper. Provides: install_aur_helper()

AUR_HELPER_PKG="paru-bin"
AUR_HELPER_URL="https://aur.archlinux.org/paru-bin.git"

install_aur_helper() {
    if have_cmd paru; then
        skip "paru is already installed ($(paru --version 2>/dev/null | head -n1))"
        return 0
    fi

    log "paru not found - building $AUR_HELPER_PKG from the AUR"

    if ! pacman_install git base-devel; then
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

    have_cmd paru || {
        err "$AUR_HELPER_PKG was built but paru is still not on PATH"
        return 1
    }
    ok "paru installed"
}
