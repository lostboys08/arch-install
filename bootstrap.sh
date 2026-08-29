#!/usr/bin/env bash
#
# bootstrap.sh - post-install bootstrap for a vanilla Arch Linux desktop.
#
# Run as a normal (non-root) user that has sudo rights:
#
#   ./bootstrap.sh
#
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR
readonly PKG_DIR="$REPO_DIR/packages"
readonly MODULE_DIR="$REPO_DIR/modules"
readonly DOTFILES_DIR="$REPO_DIR/dotfiles"

# Package lists are installed in this order; any additional packages/*.txt
# file is picked up afterwards automatically.
readonly PKG_ORDER=(core dev gui-niri audio gaming)

# Non-fatal problems collected during the run and printed in the summary.
FAILURES=()

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BLUE=$'\033[0;34m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_RED=$'\033[0;31m';  C_BOLD=$'\033[1m';     C_RESET=$'\033[0m'
else
    C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BOLD=''; C_RESET=''
fi
readonly C_BLUE C_GREEN C_YELLOW C_RED C_BOLD C_RESET

section() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
log()     { printf '%s  ->%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s   !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()     { printf '%s   x%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()     { err "$*"; exit 1; }

# Record a step that failed without aborting the whole bootstrap.
record_failure() { FAILURES+=("$1"); err "$1"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

preflight() {
    section "Pre-flight checks"

    if [[ $EUID -eq 0 ]]; then
        die "Do not run this script as root. Run it as your normal user; it calls sudo when needed."
    fi

    [[ -r /etc/arch-release ]] || die "This script targets Arch Linux (/etc/arch-release not found)."
    command -v pacman >/dev/null 2>&1 || die "pacman not found; this is not an Arch system."
    command -v sudo   >/dev/null 2>&1 || die "sudo is not installed."

    # $USER is not always exported (cron, some non-login shells).
    USER="${USER:-$(id -un)}"
    export USER

    [[ -d $PKG_DIR ]]      || die "Missing package directory: $PKG_DIR"
    [[ -d $MODULE_DIR ]]   || die "Missing module directory: $MODULE_DIR"

    log "User: $USER   Home: $HOME"
    log "Repository: $REPO_DIR"

    log "Requesting sudo credentials up front..."
    sudo -v || die "Unable to obtain sudo privileges."

    # Keep the sudo timestamp alive for the duration of the run.
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

    ok "Pre-flight checks passed"
}

# ---------------------------------------------------------------------------
# Pacman: multilib + full system upgrade
# ---------------------------------------------------------------------------

enable_multilib() {
    section "Enabling [multilib] repository"

    if grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
        ok "[multilib] is already enabled"
        return 0
    fi

    sudo cp -a /etc/pacman.conf "/etc/pacman.conf.bak.$(date +%Y%m%d%H%M%S)"

    # Preferred path: uncomment the stock commented-out block.
    sudo sed -i '/^#\[multilib\]$/,/^#Include = \/etc\/pacman.d\/mirrorlist$/ s/^#//' /etc/pacman.conf

    if ! grep -Eq '^\s*\[multilib\]' /etc/pacman.conf; then
        # Fallback: append the section ourselves.
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' \
            | sudo tee -a /etc/pacman.conf >/dev/null
    fi

    grep -Eq '^\s*\[multilib\]' /etc/pacman.conf \
        || die "Failed to enable [multilib] in /etc/pacman.conf"

    ok "[multilib] enabled (backup of the original written next to /etc/pacman.conf)"
}

system_update() {
    section "Synchronising databases and upgrading the system"
    sudo pacman -Syu --noconfirm || die "pacman -Syu failed; resolve the issue and re-run."
    ok "System is up to date"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# Print every packages/*.txt path, ordered lists first.
package_lists() {
    local name file seen=()
    for name in "${PKG_ORDER[@]}"; do
        file="$PKG_DIR/$name.txt"
        [[ -f $file ]] || continue
        seen+=("$file")
        printf '%s\n' "$file"
    done
    for file in "$PKG_DIR"/*.txt; do
        [[ -f $file ]] || continue
        local known=0 s
        for s in "${seen[@]:-}"; do [[ $s == "$file" ]] && known=1 && break; done
        (( known )) || printf '%s\n' "$file"
    done
}

install_packages() {
    section "Installing packages"

    command -v paru >/dev/null 2>&1 || die "paru is not available; AUR helper installation must run first."

    local file name
    while IFS= read -r file; do
        name=$(basename "$file" .txt)

        if [[ ! -s $file ]]; then
            warn "$name.txt is empty - skipping"
            continue
        fi

        log "Installing package list: $name"
        if paru -S --needed --noconfirm - < "$file"; then
            ok "$name installed"
        else
            record_failure "Package list '$name' did not install cleanly"
        fi
    done < <(package_lists)
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

have_systemd() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

enable_unit() {
    local unit=$1
    if [[ -z $(systemctl list-unit-files --no-legend "$unit" 2>/dev/null) ]]; then
        warn "Unit $unit not found - skipping"
        return 0
    fi
    if sudo systemctl enable --now "$unit" >/dev/null 2>&1; then
        ok "Enabled $unit"
    else
        record_failure "Could not enable $unit"
    fi
}

enable_services() {
    section "Enabling system services"

    if ! have_systemd; then
        warn "systemd is not running - skipping service configuration"
        return 0
    fi

    if command -v docker >/dev/null 2>&1; then
        enable_unit docker.service

        if getent group docker >/dev/null 2>&1; then
            if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
                ok "$USER is already in the 'docker' group"
            elif sudo usermod -aG docker "$USER"; then
                ok "Added $USER to the 'docker' group (log out and back in to apply)"
            else
                record_failure "Could not add $USER to the 'docker' group"
            fi
        else
            warn "Group 'docker' does not exist - skipping group membership"
        fi
    else
        warn "docker is not installed - skipping docker service setup"
    fi

    # PipeWire runs as a user service; systemd sockets normally start it on demand.
    local unit
    for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
        if [[ -n $(systemctl --user list-unit-files --no-legend "$unit" 2>/dev/null) ]]; then
            systemctl --user enable "$unit" >/dev/null 2>&1 \
                && ok "Enabled user unit $unit" \
                || warn "Could not enable user unit $unit"
        fi
    done
}

# ---------------------------------------------------------------------------
# Dotfiles (GNU Stow)
# ---------------------------------------------------------------------------

stow_dotfiles() {
    section "Linking dotfiles with GNU Stow"

    if [[ ! -d $DOTFILES_DIR ]]; then
        warn "No dotfiles directory at $DOTFILES_DIR - skipping"
        return 0
    fi
    if ! command -v stow >/dev/null 2>&1; then
        record_failure "stow is not installed - dotfiles were not linked"
        return 0
    fi

    mkdir -p "$HOME/.config"

    local dir pkg found=0
    for dir in "$DOTFILES_DIR"/*/; do
        [[ -d $dir ]] || continue
        found=1
        pkg=$(basename "$dir")
        log "Stowing $pkg -> $HOME"
        if stow --dir "$DOTFILES_DIR" --target "$HOME" --restow --no-folding "$pkg"; then
            ok "$pkg linked"
        else
            record_failure "stow failed for '$pkg' (conflicting files exist; move them aside or re-run stow with --adopt)"
        fi
    done

    (( found )) || warn "No stow packages found in $DOTFILES_DIR"
}

# ---------------------------------------------------------------------------
# Default shell
# ---------------------------------------------------------------------------

set_default_shell() {
    section "Setting the default shell"

    local fish_bin
    if ! fish_bin=$(command -v fish 2>/dev/null); then
        warn "fish is not installed - leaving the shell unchanged"
        return 0
    fi

    local current
    current=$(getent passwd "$USER" | cut -d: -f7)
    if [[ $current == "$fish_bin" ]]; then
        ok "fish is already the default shell"
        return 0
    fi

    if ! grep -qx "$fish_bin" /etc/shells 2>/dev/null; then
        printf '%s\n' "$fish_bin" | sudo tee -a /etc/shells >/dev/null
    fi

    if sudo chsh -s "$fish_bin" "$USER"; then
        ok "Default shell changed to $fish_bin (was $current)"
    else
        record_failure "Could not change the default shell to fish"
    fi
}

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------

load_modules() {
    section "Loading modules"

    local module
    for module in "$MODULE_DIR"/*.sh; do
        [[ -f $module ]] || continue
        # shellcheck source=/dev/null
        source "$module"
        log "Loaded $(basename "$module")"
    done
}

run_module() {
    local fn=$1 label=$2
    if ! declare -F "$fn" >/dev/null 2>&1; then
        record_failure "Module function '$fn' is not defined"
        return 0
    fi
    if ! "$fn"; then
        record_failure "$label failed"
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

summary() {
    section "Summary"

    if (( ${#FAILURES[@]} == 0 )); then
        ok "Bootstrap completed without errors."
    else
        warn "Bootstrap completed with ${#FAILURES[@]} problem(s):"
        local f
        for f in "${FAILURES[@]}"; do
            printf '     - %s\n' "$f" >&2
        done
    fi

    cat <<'NEXT'

Next steps:
  * Reboot (or log out and back in) so the new group membership, shell and
    session services take effect.
  * Start niri from a TTY with `niri --session`, or pick it from your display
    manager.
NEXT
}

# ---------------------------------------------------------------------------

main() {
    preflight
    load_modules

    enable_multilib
    system_update

    section "Installing the AUR helper"
    run_module install_aur_helper "AUR helper installation"

    install_packages

    section "Configuring Btrfs snapshots"
    run_module setup_snapper "Snapper setup"

    section "Applying sysctl tweaks"
    run_module apply_sysctl_tweaks "sysctl configuration"

    section "GitHub setup"
    run_module setup_github_interactive "GitHub setup"

    enable_services
    stow_dotfiles
    set_default_shell

    summary
}

main "$@"
