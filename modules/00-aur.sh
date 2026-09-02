#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 00-aur.sh - the paru AUR helper. Provides: install_aur_helper()
#
# paru is built against libalpm, whose soname moves with pacman. When the two
# disagree paru refuses to run, and because every package list goes through it
# the whole bootstrap fails at once. So this step does not just install paru:
# it checks that the paru on the machine actually works, and rebuilds it when
# it does not.
#
# The candidates are tried in order. paru-bin is a prebuilt binary and costs
# seconds instead of a full Rust build, but it is the package that lags a
# soname bump. paru is built from source by makepkg, which links it against
# the libalpm installed right now - slower, and mismatch-proof.

AUR_HELPER_PKGS=(paru-bin paru)
AUR_BASE_URL="https://aur.archlinux.org"

# The other half of a paru install. With the stock makepkg.conf (OPTIONS
# contains 'debug') a source build also produces paru-debug, and paru-bin
# ships paru-bin-debug alongside the binary. They own the same file,
# /usr/lib/debug/usr/bin/paru.debug, so one left behind blocks the next
# candidate: pacman aborts the whole transaction on the file conflict and
# the rebuild fails for a reason that has nothing to do with the rebuild.
AUR_HELPER_DEBUG_PKGS=(paru-bin-debug paru-debug)

install_aur_helper() {
    if have_cmd paru; then
        if paru_usable; then
            skip "paru is already installed ($(paru --version 2>/dev/null | head -n1))"
            return 0
        fi
        warn "paru is installed but unusable: $(paru_problem)"
        log "Rebuilding it against the libalpm this system actually has"
        remove_paru || return 1
    else
        log "paru not found - building it from the AUR"
    fi

    build_aur_helper
}

build_aur_helper() {
    local pkg
    for pkg in "${AUR_HELPER_PKGS[@]}"; do
        # A candidate removed earlier - or by a previous run that stopped
        # halfway - can still have its debug half installed.
        remove_paru_debug_packages

        log "Building $pkg from the AUR"
        if ! build_aur_package "$pkg"; then
            warn "$pkg did not build - trying the next candidate"
            continue
        fi

        paru_health_reset
        if paru_usable; then
            ok "paru installed from $pkg ($(paru --version 2>/dev/null | head -n1))"
            return 0
        fi

        warn "$pkg installed but is not usable: $(paru_problem)"
        remove_paru || return 1
    done

    err "Could not install a working paru (tried: ${AUR_HELPER_PKGS[*]})"
    return 1
}

# paru and paru-bin conflict, and --noconfirm answers 'no' to pacman's conflict
# prompt - so the broken one has to be gone before the rebuild, or the rebuild
# fails for a reason that has nothing to do with the mismatch.
remove_paru() {
    local bin owner doomed=()
    bin=$(command -v paru 2>/dev/null) || { remove_paru_debug_packages; return 0; }

    owner=$(pacman -Qqo "$bin" 2>/dev/null | head -n1 | awk '{print $1}')
    # A package name, and nothing that could be read as a pacman option: this
    # feeds a removal.
    if [[ -z $owner || ! $owner =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then
        warn "$bin is not owned by a package - leaving it in place"
        return 0
    fi

    # The debug package goes in the same transaction: removing paru-bin on its
    # own leaves paru-bin-debug owning /usr/lib/debug/usr/bin/paru.debug, and
    # the source build that follows collides with it.
    doomed=("$owner")
    local dbg
    for dbg in "${AUR_HELPER_DEBUG_PKGS[@]}"; do
        [[ $dbg == "$owner" ]] && continue
        pkg_installed "$dbg" && doomed+=("$dbg")
    done

    log "Removing the broken ${doomed[*]}"
    # -dd: nothing should depend on the AUR helper, and a broken paru must not
    # be kept alive by a dependency check we are about to satisfy again anyway.
    if ! sudo pacman -Rdd --noconfirm "${doomed[@]}"; then
        err "Could not remove ${doomed[*]}"
        return 1
    fi
    paru_health_reset
    return 0
}

# Sweep up debug packages left over from a paru that is already gone.
remove_paru_debug_packages() {
    local pkg stale=()
    for pkg in "${AUR_HELPER_DEBUG_PKGS[@]}"; do
        pkg_installed "$pkg" && stale+=("$pkg")
    done
    (( ${#stale[@]} )) || return 0

    log "Removing leftover debug package(s): ${stale[*]}"
    if ! sudo pacman -Rdd --noconfirm "${stale[@]}"; then
        # Not fatal on its own: say so, and let the build report the conflict
        # if one actually happens.
        warn "Could not remove ${stale[*]} - the build may hit a file conflict"
        return 1
    fi
    return 0
}

# write_makepkg_conf <dest>
# A makepkg config that is the system one plus '!debug'. Building the helper
# without a debug package keeps the build quiet (no gdb-add-index warnings),
# halves what has to be installed, and removes the file that collides with a
# leftover paru-bin-debug in the first place. Sourcing the real configs keeps
# every other setting - CFLAGS, MAKEFLAGS, PACKAGER, the caches.
write_makepkg_conf() {
    local dest=$1 f
    : > "$dest" || return 1
    {
        [[ -r /etc/makepkg.conf ]] && printf 'source %q\n' /etc/makepkg.conf
        for f in /etc/makepkg.conf.d/*.conf; do
            [[ -r $f ]] && printf 'source %q\n' "$f"
        done
        for f in "${XDG_CONFIG_HOME:-$HOME/.config}/pacman/makepkg.conf" \
                 "$HOME/.makepkg.conf"; do
            [[ -r $f ]] && printf 'source %q\n' "$f"
        done
        # Appended last: makepkg reads OPTIONS back to front, so this wins.
        printf 'OPTIONS+=(!debug)\n'
    } >> "$dest"
    return 0
}

build_aur_package() {
    local pkg=$1 build_dir conf rc=0
    local -a mkopts=(-si --noconfirm)

    if ! pacman_install git base-devel; then
        err "Could not install the build prerequisites (git, base-devel)"
        return 1
    fi

    build_dir=$(mktemp -d -t aur-build-XXXXXXXX) || {
        err "Could not create a temporary build directory"
        return 1
    }

    conf="$build_dir/makepkg.conf"
    write_makepkg_conf "$conf" && mkopts+=(--config "$conf")

    if ! git clone --depth 1 "$AUR_BASE_URL/$pkg.git" "$build_dir/$pkg"; then
        err "Failed to clone $AUR_BASE_URL/$pkg.git"
        rc=1
    elif ! ( cd "$build_dir/$pkg" && makepkg "${mkopts[@]}" ); then
        err "makepkg failed while building $pkg"
        rc=1
    fi

    rm -rf "$build_dir"
    return "$rc"
}
