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

install_aur_helper() {
    if have_cmd paru; then
        if paru_usable; then
            skip "paru is already installed ($(paru --version 2>/dev/null | head -n1))"
            return 0
        fi
        warn "paru is installed but unusable: $(paru_problem)"
        log "Rebuilding it against the libalpm this system actually has"
    else
        log "paru not found - building it from the AUR"
    fi

    build_aur_helper
}

build_aur_helper() {
    local pkg
    for pkg in "${AUR_HELPER_PKGS[@]}"; do
        # Before each attempt, not just after a failed one: a previous run can
        # leave a -debug package behind with no paru on PATH at all, and that
        # is enough to make pacman refuse the install.
        remove_paru || return 1

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
    done

    err "Could not install a working paru (tried: ${AUR_HELPER_PKGS[*]})"
    return 1
}

# Everything a rebuild would collide with. Two things make this more than
# "the package that owns /usr/bin/paru":
#
#   - paru and paru-bin conflict, and --noconfirm answers 'no' to pacman's
#     conflict prompt, so a leftover helper fails the install on its own.
#   - each ships a -debug companion. paru-bin-debug owns
#     /usr/lib/debug/usr/bin/paru.debug, which paru-debug also wants, so the
#     transaction dies with "exists in filesystem" - and that companion is
#     invisible to `pacman -Qqo /usr/bin/paru`, and outlives a paru that has
#     already been removed.
paru_conflicting_packages() {
    local bin owner name candidates=() found=() seen=" "

    bin=$(command -v paru 2>/dev/null) || bin=""
    if [[ -n $bin ]]; then
        owner=$(pacman -Qqo "$bin" 2>/dev/null | head -n1 | awk '{print $1}')
        # A package name, and nothing that could be read as a pacman option:
        # this feeds a removal.
        if [[ $owner =~ ^[A-Za-z0-9][A-Za-z0-9@._+-]*$ ]]; then
            candidates+=("$owner")
        elif [[ -n $owner ]]; then
            warn "Ignoring an implausible package name for $bin: $owner"
        fi
    fi
    candidates+=("${AUR_HELPER_PKGS[@]}")

    local pkg
    for pkg in "${candidates[@]}"; do
        for name in "$pkg" "$pkg-debug"; do
            [[ $seen == *" $name "* ]] && continue
            seen+="$name "
            pkg_installed "$name" && found+=("$name")
        done
    done

    (( ${#found[@]} )) && printf '%s\n' "${found[@]}"
    return 0
}

remove_paru() {
    local pkgs=()
    mapfile -t pkgs < <(paru_conflicting_packages)
    (( ${#pkgs[@]} )) || return 0

    log "Removing so the rebuild can install: ${pkgs[*]}"
    # -dd: nothing should depend on the AUR helper, and a broken paru must not
    # be kept alive by a dependency check we are about to satisfy again anyway.
    if ! sudo pacman -Rdd --noconfirm "${pkgs[@]}"; then
        err "Could not remove: ${pkgs[*]}"
        return 1
    fi
    paru_health_reset
    return 0
}

# makepkg itself ships with pacman, so it is only missing on a broken system -
# but everything it shells out to comes from base-devel. Naming the missing
# piece beats letting makepkg fail 200 lines later with its own wording.
check_build_prereqs() {
    if ! pacman_install git base-devel; then
        err "Could not install the build prerequisites (git, base-devel)"
        return 1
    fi

    local tool missing=()
    for tool in makepkg fakeroot gcc make patch git; do
        have_cmd "$tool" || missing+=("$tool")
    done
    (( ${#missing[@]} == 0 )) && return 0

    err "Cannot build from the AUR - missing: ${missing[*]}"
    err "makepkg comes with pacman; the rest come from base-devel:"
    err "    sudo pacman -S --needed base-devel git"
    return 1
}

build_aur_package() {
    local pkg=$1 build_dir logfile rc=0

    check_build_prereqs || return 1

    build_dir=$(mktemp -d -t aur-build-XXXXXXXX) || {
        err "Could not create a temporary build directory"
        return 1
    }

    mkdir -p "$PRYMX_STATE_DIR" 2>/dev/null || true
    logfile="$PRYMX_STATE_DIR/aur-$pkg.log"

    # The build goes to a file rather than the screen. A source build scrolls
    # hundreds of lines past a TTY with no scrollback, which is exactly where
    # this failure gets diagnosed; the tail below is what is worth reading.
    log "Building $pkg - output goes to $logfile"
    log "Watch it live from another TTY with: tail -f $logfile"
    ( git clone --depth 1 "$AUR_BASE_URL/$pkg.git" "$build_dir/$pkg" \
        && cd "$build_dir/$pkg" \
        && makepkg -si --noconfirm ) > "$logfile" 2>&1 || rc=$?

    if (( rc != 0 )); then
        err "Building $pkg failed (exit $rc). The last 20 lines of $logfile:"
        tail -n 20 "$logfile" 2>/dev/null | sed 's/^/       /' >&2 || true
        explain_build_failure "$logfile"
    fi

    rm -rf "$build_dir"
    return "$rc"
}

# The failures worth recognising by name, because their own error text does
# not point at the cause.
explain_build_failure() {
    local logfile=$1

    local owner
    if grep -q 'exists in filesystem' "$logfile" 2>/dev/null; then
        owner=$(sed -n 's/.*exists in filesystem (owned by \([^)]*\)).*/\1/p' "$logfile" | head -n1)
        err "Another package already owns a file this one installs."
        if [[ -n $owner ]]; then
            err "Remove the package that owns it, then re-run:"
            err "    sudo pacman -Rdd $owner"
        fi
    elif grep -q 'upgrades are managed by' "$logfile" 2>/dev/null; then
        err "The PrymX pacman guard aborted makepkg's dependency install."
        err "Run this through ./bootstrap.sh, which holds the guard lock, or"
        err "opt out for one command with PRYMX_ALLOW_PACMAN=1."
    elif grep -qi 'Could not resolve host\|Failed to connect\|Network is unreachable' "$logfile" 2>/dev/null; then
        err "The AUR could not be reached - check the network, then re-run."
    elif grep -qi 'signature from .* is invalid\|unknown public key\|PGP' "$logfile" 2>/dev/null; then
        err "A PGP signature check failed. Import the key makepkg names above,"
        err "or refresh the keyring: sudo pacman -S archlinux-keyring"
    elif grep -qi 'no space left on device' "$logfile" 2>/dev/null; then
        err "The build ran out of disk space."
    elif grep -qi 'a password is required\|sudo:.*no tty' "$logfile" 2>/dev/null; then
        err "makepkg could not get sudo non-interactively. Run 'sudo -v' first."
    fi
}
