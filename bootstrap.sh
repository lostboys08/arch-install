#!/usr/bin/env bash
#
# PrymX - bootstrap.sh
#
# Post-install bootstrap for a vanilla Arch Linux workstation. Run as a normal
# user with sudo rights:
#
#   ./bootstrap.sh                     everything
#   ./bootstrap.sh --list              show the steps
#   ./bootstrap.sh --only gpu,dotfiles run two of them
#   ./bootstrap.sh --skip github       everything except the interactive bits
#   ./bootstrap.sh --dry-run           print the plan, touch nothing
#
# Every step is idempotent: re-running the script upgrades the machine,
# installs whatever is missing, and re-applies the configuration.
set -euo pipefail

PRYMX_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PRYMX_REPO

# shellcheck source=lib/common.sh
source "$PRYMX_REPO/lib/common.sh"

PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"
PKG_DIR="$PRYMX_REPO/packages"
MODULE_DIR="$PRYMX_REPO/modules"
DOTFILES_DIR="$PRYMX_REPO/dotfiles"

# ---------------------------------------------------------------------------
# Steps. Parallel arrays: name, function, description.
# ---------------------------------------------------------------------------

STEP_NAMES=(
    multilib identity prym update snapper snapshot aur packages gpu greeter
    bluetooth sysctl maintenance services dotfiles plugins shell github
)
STEP_FUNCS=(
    enable_multilib setup_prymx_identity install_prym_cli system_update
    setup_snapper snapshot_pre_bootstrap install_aur_helper install_packages
    setup_gpu_drivers setup_greeter setup_bluetooth apply_sysctl_tweaks
    setup_maintenance enable_services link_dotfiles setup_plugin_managers
    set_default_shell setup_github_interactive
)
STEP_DESCS=(
    "Enable the [multilib] repository"
    "Write /etc/prymx/prymx.conf and set the hostname"
    "Install the prym CLI and the pacman upgrade guard"
    "Refresh databases and upgrade the system"
    "Btrfs snapshots: snapper, snap-pac, grub-btrfs"
    "Take a pre-bootstrap snapshot"
    "Install the paru AUR helper"
    "Install every packages/*.txt list"
    "Graphics drivers and Vulkan, detected from the hardware"
    "ly display manager"
    "Bluetooth, where there is a radio"
    "Gaming sysctl tunables"
    "Cache trimming, TRIM, mirrors, OOM protection, firewall"
    "System services: docker, pipewire"
    "Link the dotfiles with GNU Stow"
    "Bootstrap the tmux/fish/neovim plugin managers"
    "Make fish the login shell"
    "Interactive GitHub: auth, git identity, SSH key"
)

ONLY_STEPS=()
SKIP_STEPS=()
DRY_RUN=0
WRITE_LOG=1

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
${C_BOLD}$PRYMX_NAME bootstrap${C_RESET} (v$PRYMX_VERSION)

${C_BOLD}USAGE${C_RESET}
    ./bootstrap.sh [options]

${C_BOLD}OPTIONS${C_RESET}
    --only <a,b>       Run only these steps.
    --skip <a,b>       Run everything except these steps.
    --list             List the steps in order and exit.
    --dry-run          Print the plan without touching the system.
    --profile <name>   desktop (default) or laptop. Selects
                       packages/profiles/<name>.txt and the power settings.
    --hostname <name>  Hostname to set (default: prymx).
    --no-log           Do not write a log file.
    -h, --help         This message.

${C_BOLD}STEPS${C_RESET}
$(list_steps)
USAGE
}

list_steps() {
    local i
    for i in "${!STEP_NAMES[@]}"; do
        printf '    %-12s %s\n' "${STEP_NAMES[$i]}" "${STEP_DESCS[$i]}"
    done
}

step_index() {
    local name=$1 i
    for i in "${!STEP_NAMES[@]}"; do
        [[ ${STEP_NAMES[$i]} == "$name" ]] && { printf '%s\n' "$i"; return 0; }
    done
    return 1
}

validate_step_names() {
    local name
    for name in "$@"; do
        step_index "$name" >/dev/null || die "Unknown step: '$name' (see --list)"
    done
}

parse_args() {
    while (( $# )); do
        case $1 in
            --only)     [[ ${2:-} ]] || die "--only needs a value"
                        IFS=, read -r -a ONLY_STEPS <<<"$2"; shift ;;
            --skip)     [[ ${2:-} ]] || die "--skip needs a value"
                        IFS=, read -r -a SKIP_STEPS <<<"$2"; shift ;;
            --profile)  [[ ${2:-} ]] || die "--profile needs a value"
                        PRYMX_PROFILE=$2; shift ;;
            --hostname) [[ ${2:-} ]] || die "--hostname needs a value"
                        PRYMX_HOSTNAME=$2; shift ;;
            --dry-run)  DRY_RUN=1 ;;
            --no-log)   WRITE_LOG=0 ;;
            --list)     list_steps; exit 0 ;;
            -h|--help)  usage; exit 0 ;;
            *)          err "Unknown option: $1"; usage >&2; exit 2 ;;
        esac
        shift
    done

    (( ${#ONLY_STEPS[@]} )) && validate_step_names "${ONLY_STEPS[@]}"
    (( ${#SKIP_STEPS[@]} )) && validate_step_names "${SKIP_STEPS[@]}"

    case $PRYMX_PROFILE in
        desktop|laptop) ;;
        *) die "Unknown profile: '$PRYMX_PROFILE' (expected desktop or laptop)" ;;
    esac
}

step_selected() {
    local name=$1 s
    if (( ${#ONLY_STEPS[@]} )); then
        for s in "${ONLY_STEPS[@]}"; do [[ $s == "$name" ]] && return 0; done
        return 1
    fi
    for s in "${SKIP_STEPS[@]:-}"; do [[ $s == "$name" ]] && return 1; done
    return 0
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

start_logging() {
    (( WRITE_LOG )) || return 0
    mkdir -p "$PRYMX_STATE_DIR" 2>/dev/null || return 0
    LOG_FILE="$PRYMX_STATE_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Logging to $LOG_FILE"
}

preflight() {
    section "$PRYMX_NAME pre-flight"

    is_root && die "Do not run this as root. Run it as your normal user; it calls sudo when needed."
    is_arch  || die "This targets Arch Linux (/etc/arch-release and pacman are required)."
    have_cmd sudo || die "sudo is not installed."

    [[ -d $PKG_DIR ]]    || die "Missing package directory: $PKG_DIR"
    [[ -d $MODULE_DIR ]] || die "Missing module directory: $MODULE_DIR"

    log "User:       $USER"
    log "Repository: $PRYMX_REPO"
    log "Profile:    $PRYMX_PROFILE"
    log "Hostname:   $PRYMX_HOSTNAME"

    log "Requesting sudo credentials up front..."
    sudo -v || die "Unable to obtain sudo privileges."

    # Keep the sudo timestamp alive for the whole run.
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    SUDO_KEEPALIVE_PID=$!

    # Hold the PrymX lock so our own upgrades are not blocked by the guard.
    prymx_lock_acquire || warn "Could not take the PrymX pacman lock"

    trap 'cleanup' EXIT
    ok "Pre-flight checks passed"
}

cleanup() {
    [[ -n ${SUDO_KEEPALIVE_PID:-} ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    prymx_lock_release
    return 0
}

load_modules() {
    local module
    for module in "$MODULE_DIR"/*.sh; do
        [[ -f $module ]] || continue
        # shellcheck source=/dev/null
        source "$module"
    done
}

# ---------------------------------------------------------------------------
# Steps implemented here (the rest live in modules/)
# ---------------------------------------------------------------------------

enable_multilib() {
    if grep -Eq '^\s*\[multilib\]' "$PACMAN_CONF"; then
        skip "[multilib] is already enabled"
        return 0
    fi

    sudo cp -a "$PACMAN_CONF" "$PACMAN_CONF.prymx.bak"

    # Preferred path: uncomment the stock commented-out block. The range is
    # anchored so that [multilib-testing] above it is left alone.
    sudo sed -i '/^#\[multilib\]$/,/^#Include = \/etc\/pacman.d\/mirrorlist$/ s/^#//' "$PACMAN_CONF"

    if ! grep -Eq '^\s*\[multilib\]' "$PACMAN_CONF"; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' \
            | sudo tee -a "$PACMAN_CONF" >/dev/null
    fi

    grep -Eq '^\s*\[multilib\]' "$PACMAN_CONF" \
        || die "Failed to enable [multilib] in $PACMAN_CONF"

    ok "[multilib] enabled (original at $PACMAN_CONF.prymx.bak)"
}

system_update() {
    sudo pacman -Syu --noconfirm || die "pacman -Syu failed; resolve it and re-run."
    ok "System is up to date"
}

install_packages() {
    install_package_lists "$PKG_DIR" "$PRYMX_PROFILE"
}

link_dotfiles() {
    stow_dotfiles "$DOTFILES_DIR" "$HOME"
}

enable_services() {
    if have_cmd docker; then
        enable_unit docker.service

        if getent group docker >/dev/null 2>&1; then
            if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
                skip "$USER is already in the 'docker' group"
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

    local unit
    for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
        enable_user_unit "$unit"
    done
}

set_default_shell() {
    local fish_bin
    if ! fish_bin=$(command -v fish 2>/dev/null); then
        warn "fish is not installed - leaving the shell unchanged"
        return 0
    fi

    local current
    current=$(getent passwd "$USER" | cut -d: -f7)
    if [[ $current == "$fish_bin" ]]; then
        skip "fish is already the login shell"
        return 0
    fi

    ensure_line_in_file "$fish_bin" /etc/shells

    if sudo chsh -s "$fish_bin" "$USER"; then
        ok "Login shell changed to $fish_bin (was $current)"
    else
        record_failure "Could not change the login shell to fish"
    fi
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_steps() {
    local i name fn desc
    for i in "${!STEP_NAMES[@]}"; do
        name=${STEP_NAMES[$i]}
        fn=${STEP_FUNCS[$i]}
        desc=${STEP_DESCS[$i]}

        step_selected "$name" || continue

        section "[$name] $desc"

        if ! declare -F "$fn" >/dev/null 2>&1; then
            record_failure "Step '$name': function '$fn' is not defined"
            continue
        fi

        if ! "$fn"; then
            record_failure "Step '$name' failed"
        fi
    done
}

print_plan() {
    section "$PRYMX_NAME plan (dry run - nothing will be changed)"
    local i name
    for i in "${!STEP_NAMES[@]}"; do
        name=${STEP_NAMES[$i]}
        if step_selected "$name"; then
            printf '  %s run %s %-12s %s\n' "$C_GREEN" "$C_RESET" "$name" "${STEP_DESCS[$i]}"
        else
            printf '  %sskip%s %-12s %s\n' "$C_DIM" "$C_RESET" "$name" "${STEP_DESCS[$i]}"
        fi
    done
    printf '\n  profile: %s   hostname: %s   repo: %s\n\n' \
        "$PRYMX_PROFILE" "$PRYMX_HOSTNAME" "$PRYMX_REPO"
}

summary() {
    section "Summary"
    print_failures
    cat <<'NEXT'

Next steps:
  * Reboot so the new group membership, hostname, login shell and greeter
    take effect.
  * ly will offer the niri session at the login prompt.
  * From then on, upgrade with `prym update` - it snapshots first.
NEXT
}

main() {
    # Stored settings first, so a laptop stays a laptop across runs; explicit
    # flags and environment variables still win.
    prymx_load_config
    parse_args "$@"

    if (( DRY_RUN )); then
        load_modules
        print_plan
        exit 0
    fi

    start_logging
    preflight
    load_modules
    run_steps
    summary
}

# Executed, not sourced: the test suite sources this file for its functions.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
