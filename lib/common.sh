#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/common.sh - shared helpers for PrymX (bootstrap.sh, bin/prym, modules/*).
#
# Sourced, never executed. Everything here is written to be safe to run twice.

[[ -n ${PRYMX_COMMON_SOURCED:-} ]] && return 0
PRYMX_COMMON_SOURCED=1

# These are consumed by bootstrap.sh, bin/prym and modules/, not here.
# shellcheck disable=SC2034
PRYMX_NAME="PrymX"
# shellcheck disable=SC2034
PRYMX_VERSION="1.0.0"
PRYMX_CONF_DIR="/etc/prymx"
PRYMX_CONF="$PRYMX_CONF_DIR/prymx.conf"
PRYMX_LOCK_DIR="/run/prymx"
PRYMX_PACMAN_LOCK="$PRYMX_LOCK_DIR/pacman.lock"
# shellcheck disable=SC2034
PRYMX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/prymx"

# $USER is not exported by every shell; several helpers depend on it.
USER="${USER:-$(id -un)}"
export USER

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_RED=$'\033[0;31m';  C_DIM=$'\033[2m';      C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_DIM=''; C_BOLD=''; C_RESET=''
fi

section() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
log()     { printf '%s  ->%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip()    { printf '%s   =%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn()    { printf '%s   !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf '%s   x%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }

# Problems that should not abort the run; reported together at the end.
PRYMX_FAILURES=()
record_failure() { PRYMX_FAILURES+=("$1"); err "$1"; }

print_failures() {
    if (( ${#PRYMX_FAILURES[@]} == 0 )); then
        ok "Completed without errors."
        return 0
    fi
    warn "Completed with ${#PRYMX_FAILURES[@]} problem(s):"
    local f
    for f in "${PRYMX_FAILURES[@]}"; do
        printf '     - %s\n' "$f" >&2
    done
    return 0
}

# ---------------------------------------------------------------------------
# Small predicates
# ---------------------------------------------------------------------------

have_cmd()     { command -v "$1" >/dev/null 2>&1; }
have_systemd() { have_cmd systemctl && [[ -d /run/systemd/system ]]; }
is_root()      { [[ $EUID -eq 0 ]]; }
is_arch()      { [[ -r /etc/arch-release ]] && have_cmd pacman; }
is_btrfs_root() { [[ $(findmnt -no FSTYPE / 2>/dev/null || true) == btrfs ]]; }
have_tty()     { [[ -t 0 ]] || [[ -c /dev/tty ]]; }

pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

unit_exists() {
    [[ -n $(systemctl list-unit-files --no-legend "$1" 2>/dev/null) ]]
}

user_unit_exists() {
    [[ -n $(systemctl --user list-unit-files --no-legend "$1" 2>/dev/null) ]]
}

# Ask a yes/no question; defaults to no. Returns 1 when there is no terminal.
confirm() {
    local prompt=$1 reply=""
    if [[ ! -t 0 ]] && [[ ! -c /dev/tty ]]; then
        warn "No terminal available to confirm: $prompt"
        return 1
    fi
    if [[ -t 0 ]]; then
        read -r -p "  $prompt [y/N] " reply || return 1
    else
        read -r -p "  $prompt [y/N] " reply < /dev/tty || return 1
    fi
    [[ ${reply,,} == y || ${reply,,} == yes ]]
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Precedence: environment > $PRYMX_CONF > the defaults below. Capture what
# the environment asked for before the defaults overwrite it.
_PRYMX_ENV_REPO="${PRYMX_REPO:-}"
_PRYMX_ENV_PROFILE="${PRYMX_PROFILE:-}"
_PRYMX_ENV_HOSTNAME="${PRYMX_HOSTNAME:-}"

PRYMX_REPO="${PRYMX_REPO:-}"
PRYMX_PROFILE="${PRYMX_PROFILE:-desktop}"
PRYMX_HOSTNAME="${PRYMX_HOSTNAME:-prymx}"

prymx_load_config() {
    if [[ -r $PRYMX_CONF ]]; then
        # The file only ever holds KEY="value" lines written by bootstrap.sh.
        # shellcheck source=/dev/null
        source "$PRYMX_CONF"
    fi

    [[ -n $_PRYMX_ENV_REPO ]]     && PRYMX_REPO=$_PRYMX_ENV_REPO
    [[ -n $_PRYMX_ENV_PROFILE ]]  && PRYMX_PROFILE=$_PRYMX_ENV_PROFILE
    [[ -n $_PRYMX_ENV_HOSTNAME ]] && PRYMX_HOSTNAME=$_PRYMX_ENV_HOSTNAME
    return 0
}

prymx_write_config() {
    local repo=$1 profile=$2 host=$3
    install_system_file "$PRYMX_CONF" 644 <<CONF
# $PRYMX_NAME - written by bootstrap.sh; edit and re-run bootstrap to change.
PRYMX_REPO="$repo"
PRYMX_PROFILE="$profile"
PRYMX_HOSTNAME="$host"
PRYMX_USER="$USER"
CONF
}

# ---------------------------------------------------------------------------
# Idempotent file writes
# ---------------------------------------------------------------------------

# install_system_file <dest> [mode] < content
# Writes only when the content differs, so re-runs stay quiet and mtimes stable.
install_system_file() {
    local dest=$1 mode=${2:-644} tmp rc=0
    tmp=$(mktemp) || { err "mktemp failed"; return 1; }
    cat > "$tmp"

    if sudo test -f "$dest" && sudo cmp -s "$tmp" "$dest"; then
        skip "$dest already up to date"
        rm -f "$tmp"
        return 0
    fi

    if sudo install -Dm"$mode" "$tmp" "$dest"; then
        ok "Wrote $dest"
    else
        err "Could not write $dest"
        rc=1
    fi
    rm -f "$tmp"
    return "$rc"
}

# Append a line to a root-owned file unless it is already there.
ensure_line_in_file() {
    local line=$1 file=$2
    if sudo test -f "$file" && sudo grep -qxF "$line" "$file"; then
        return 0
    fi
    printf '%s\n' "$line" | sudo tee -a "$file" >/dev/null
}

# Update key=value in an INI-style file, but only if the key already exists.
# ly's config keys move between releases; this never invents new ones.
set_ini_key_if_present() {
    local file=$1 key=$2 value=$3
    sudo test -f "$file" || return 0
    sudo grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file" || return 0
    sudo sed -i -E "s|^[[:space:]]*#?[[:space:]]*(${key})[[:space:]]*=.*|\1 = ${value}|" "$file"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# Repository packages, via pacman. Safe to call with an already-installed set.
pacman_install() {
    (( $# )) || return 0
    local missing=() pkg
    for pkg in "$@"; do
        pkg_installed "$pkg" || missing+=("$pkg")
    done
    if (( ${#missing[@]} == 0 )); then
        skip "Already installed: $*"
        return 0
    fi
    log "Installing: ${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
}

# ---------------------------------------------------------------------------
# AUR helper health
#
# paru links against libalpm, and libalpm bumps its soname on most pacman
# releases (libalpm.so.15 -> libalpm.so.16). A paru built against the previous
# soname stops working the instant pacman is upgraded past it: it dies before
# it can install anything, so every package list fails at once and the only
# clue is a version mismatch. paru-bin is the usual casualty - it is prebuilt
# by its maintainer, so it lags a soname bump by hours or days - but a
# source-built paru breaks the same way once pacman moves underneath it.
#
# Nothing here repairs paru; install_aur_helper() in modules/00-aur.sh does
# that. These helpers only let the rest of the run notice and say so once.
# ---------------------------------------------------------------------------

# Overridable so the tests can point at a fake lib directory.
PRYMX_LIBDIR="${PRYMX_LIBDIR:-/usr/lib}"

PRYMX_PARU_REPAIR_HINT="rebuild it with './bootstrap.sh --only aur'"

# The libalpm soname this system provides, e.g. '16' for libalpm.so.16.
system_alpm_soname() {
    local f v best=""
    for f in "$PRYMX_LIBDIR"/libalpm.so.*; do
        [[ -e $f ]] || continue
        v=${f##*/libalpm.so.}
        [[ $v =~ ^[0-9]+$ ]] || continue
        (( v > ${best:-0} )) && best=$v
    done
    printf '%s' "$best"
}

# The libalpm soname paru was linked against, e.g. '15'.
paru_alpm_soname() {
    local bin out v
    bin=$(command -v paru 2>/dev/null) || return 0
    out=$(ldd "$bin" 2>/dev/null) || return 0
    v=$(sed -n 's/.*libalpm\.so\.\([0-9][0-9]*\).*/\1/p' <<<"$out")
    printf '%s' "${v%%$'\n'*}"
}

# Empty output means paru works. Anything else is why it does not.
_paru_probe() {
    have_cmd paru || { printf 'paru is not installed'; return 0; }

    local out rc=0
    out=$(paru --version 2>&1) || rc=$?
    if (( rc != 0 )); then
        printf 'paru --version exited %s: %s' "$rc" "$(head -n1 <<<"$out")"
        return 0
    fi

    local built system
    built=$(paru_alpm_soname)
    system=$(system_alpm_soname)
    if [[ -n $built && -n $system && $built != "$system" ]]; then
        printf 'paru was built against libalpm.so.%s but this system has libalpm.so.%s' \
            "$built" "$system"
    fi
}

# Cached: several steps ask, and the probe forks.
paru_problem() {
    [[ -n ${PRYMX_PARU_PROBLEM+x} ]] || PRYMX_PARU_PROBLEM=$(_paru_probe)
    printf '%s' "$PRYMX_PARU_PROBLEM"
}
paru_usable()       { [[ -z $(paru_problem) ]]; }
paru_health_reset() { unset PRYMX_PARU_PROBLEM; }

# Anything that may live in the AUR, via paru when it is available.
aur_install() {
    (( $# )) || return 0
    if paru_usable; then
        paru -S --needed --noconfirm "$@"
    else
        if have_cmd paru; then
            warn "paru is unusable: $(paru_problem)"
            warn "Falling back to pacman; $PRYMX_PARU_REPAIR_HINT"
        fi
        pacman_install "$@"
    fi
}

# Print every packages/*.txt path, the ordered ones first.
PRYMX_PKG_ORDER=(core dev gui-niri audio fonts gaming)

package_lists() {
    local dir=$1 name file seen=()
    for name in "${PRYMX_PKG_ORDER[@]}"; do
        file="$dir/$name.txt"
        [[ -f $file ]] || continue
        seen+=("$file")
        printf '%s\n' "$file"
    done
    for file in "$dir"/*.txt; do
        [[ -f $file ]] || continue
        local known=0 s
        for s in "${seen[@]:-}"; do [[ $s == "$file" ]] && known=1 && break; done
        (( known )) || printf '%s\n' "$file"
    done
}

# Install every list in packages/, plus the profile list when one exists.
install_package_lists() {
    local dir=$1 profile=${2:-} file name

    if ! paru_usable; then
        record_failure "Cannot install package lists: $(paru_problem) - $PRYMX_PARU_REPAIR_HINT"
        return 1
    fi

    while IFS= read -r file; do
        name=$(basename "$file" .txt)
        if [[ ! -s $file ]]; then
            warn "$name.txt is empty - skipping"
            continue
        fi
        log "Package list: $name"
        if paru -S --needed --noconfirm - < "$file"; then
            ok "$name up to date"
        else
            record_failure "Package list '$name' did not install cleanly"
        fi
    done < <(package_lists "$dir")

    if [[ -n $profile ]]; then
        local pfile="$dir/profiles/$profile.txt"
        if [[ -s $pfile ]]; then
            log "Profile list: $profile"
            if paru -S --needed --noconfirm - < "$pfile"; then
                ok "profile:$profile up to date"
            else
                record_failure "Profile list '$profile' did not install cleanly"
            fi
        elif [[ -e $pfile ]]; then
            warn "Profile list '$profile' is empty - skipping"
        fi
    fi
}

# ---------------------------------------------------------------------------
# The pacman guard lock
#
# /etc/pacman.d/hooks refuses upgrades that PrymX did not start, so that every
# upgrade goes through `prym update` and gets a snapshot first. Holding this
# lock is what marks a transaction as ours.
# ---------------------------------------------------------------------------

PRYMX_LOCK_HELD=0

prymx_lock_acquire() {
    (( PRYMX_LOCK_HELD )) && return 0
    sudo mkdir -p "$PRYMX_LOCK_DIR" || return 1
    printf '%s\n' "$$" | sudo tee "$PRYMX_PACMAN_LOCK" >/dev/null || return 1
    PRYMX_LOCK_HELD=1
    trap 'prymx_lock_release' EXIT
    return 0
}

prymx_lock_release() {
    (( PRYMX_LOCK_HELD )) || return 0
    sudo rm -f "$PRYMX_PACMAN_LOCK" 2>/dev/null || true
    PRYMX_LOCK_HELD=0
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

enable_unit() {
    local unit=$1
    if ! have_systemd; then
        skip "systemd not running - not enabling $unit"
        return 0
    fi
    if ! unit_exists "$unit"; then
        warn "Unit $unit not found - skipping"
        return 0
    fi
    if [[ $(systemctl is-enabled "$unit" 2>/dev/null) == enabled ]] \
        && [[ $(systemctl is-active "$unit" 2>/dev/null) == active ]]; then
        skip "$unit already enabled and running"
        return 0
    fi
    if sudo systemctl enable --now "$unit" >/dev/null 2>&1; then
        ok "Enabled $unit"
    else
        record_failure "Could not enable $unit"
    fi
}

enable_user_unit() {
    local unit=$1
    have_systemd || return 0
    user_unit_exists "$unit" || return 0
    if [[ $(systemctl --user is-enabled "$unit" 2>/dev/null) == enabled ]]; then
        skip "$unit (user) already enabled"
        return 0
    fi
    systemctl --user enable "$unit" >/dev/null 2>&1 \
        && ok "Enabled user unit $unit" \
        || warn "Could not enable user unit $unit"
}

# ---------------------------------------------------------------------------
# Snapper
# ---------------------------------------------------------------------------

# snapper_snapshot <description>
# Reports the snapshot it took on stdout; callers only care that it succeeded.
snapper_snapshot() {
    local desc=$1 num

    if ! is_btrfs_root; then
        skip "Root is not btrfs - no snapshot taken"
        return 0
    fi
    if ! have_cmd snapper; then
        warn "snapper is not installed - no snapshot taken"
        return 0
    fi
    if ! sudo snapper list-configs 2>/dev/null | awk 'NR>2 {print $1}' | grep -qx root; then
        warn "No snapper config 'root' - no snapshot taken"
        return 0
    fi

    if num=$(sudo snapper -c root create --type single --cleanup-algorithm number \
                --description "$desc" --print-number 2>/dev/null); then
        ok "Snapshot #$num: $desc"
        return 0
    fi

    record_failure "Could not create snapper snapshot: $desc"
    return 1
}

# ---------------------------------------------------------------------------
# Dotfiles
# ---------------------------------------------------------------------------

stow_dotfiles() {
    local dotfiles_dir=$1 target=${2:-$HOME}

    if [[ ! -d $dotfiles_dir ]]; then
        warn "No dotfiles directory at $dotfiles_dir - skipping"
        return 0
    fi
    if ! have_cmd stow; then
        record_failure "stow is not installed - dotfiles were not linked"
        return 0
    fi

    mkdir -p "$target/.config"

    local dir pkg found=0
    for dir in "$dotfiles_dir"/*/; do
        [[ -d $dir ]] || continue
        found=1
        pkg=$(basename "$dir")
        if stow --dir "$dotfiles_dir" --target "$target" --restow --no-folding "$pkg" 2>&1; then
            ok "Linked $pkg"
        else
            record_failure "stow failed for '$pkg' (a real file is in the way; move it aside or re-run with --adopt)"
        fi
    done

    (( found )) || warn "No stow packages found in $dotfiles_dir"
}
