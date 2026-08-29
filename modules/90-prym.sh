#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 90-prym.sh - install the `prym` CLI, the pacman upgrade guard, and the
# machine's PrymX identity.
# Provides: install_prym_cli(), setup_prymx_identity()

PRYM_BIN_LINK="/usr/local/bin/prym"
PRYM_GUARD_BIN="/usr/local/lib/prymx/pacman-guard"
PRYM_GUARD_HOOK="/etc/pacman.d/hooks/00-prymx-guard.hook"

install_prym_cli() {
    local repo=${PRYMX_REPO:?PRYMX_REPO is not set}
    local src="$repo/bin/prym"

    [[ -f $src ]] || { record_failure "Missing $src"; return 1; }
    chmod +x "$src" 2>/dev/null || true

    # A symlink means `git pull` in the repo updates the installed CLI too.
    if [[ -L $PRYM_BIN_LINK && $(readlink -f "$PRYM_BIN_LINK") == "$(readlink -f "$src")" ]]; then
        skip "$PRYM_BIN_LINK already points at $src"
    else
        if sudo ln -sfn "$src" "$PRYM_BIN_LINK"; then
            ok "Installed $PRYM_BIN_LINK -> $src"
        else
            record_failure "Could not install $PRYM_BIN_LINK"
            return 1
        fi
    fi

    _prym_install_guard
}

# The guard aborts any pacman transaction that would upgrade packages unless
# `prym` started it, so no upgrade happens without a snapshot first.
_prym_install_guard() {
    local repo=${PRYMX_REPO:?}

    install_system_file "$PRYM_GUARD_BIN" 755 < "$repo/system/pacman-guard.sh" \
        || { record_failure "Could not install the pacman guard"; return 1; }

    install_system_file "$PRYM_GUARD_HOOK" 644 < "$repo/system/prymx-guard.hook" \
        || { record_failure "Could not install the pacman guard hook"; return 1; }

    ok "Upgrades now route through 'prym update'"
}

setup_prymx_identity() {
    local repo=${PRYMX_REPO:?} profile=${PRYMX_PROFILE:-desktop} host=${PRYMX_HOSTNAME:-prymx}

    prymx_write_config "$repo" "$profile" "$host" \
        || record_failure "Could not write $PRYMX_CONF"

    _prym_set_hostname "$host"
}

_prym_set_hostname() {
    local host=$1 current

    if ! have_systemd; then
        skip "systemd is not running - leaving the hostname alone"
        return 0
    fi

    current=$(hostnamectl --static 2>/dev/null || true)
    if [[ $current == "$host" ]]; then
        skip "Hostname is already '$host'"
    else
        if sudo hostnamectl set-hostname "$host"; then
            ok "Hostname set to '$host' (was '${current:-unset}')"
        else
            record_failure "Could not set the hostname to '$host'"
            return 0
        fi
    fi

    _prym_update_hosts "$host"
}

# Keep the 127.0.1.1 entry in step with the hostname.
_prym_update_hosts() {
    local host=$1
    local line="127.0.1.1	$host.localdomain	$host"

    if sudo grep -qxF "$line" /etc/hosts 2>/dev/null; then
        skip "/etc/hosts already has the 127.0.1.1 entry"
        return 0
    fi

    if sudo grep -Eq '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
        sudo cp -a /etc/hosts /etc/hosts.prymx.bak
        sudo sed -i -E "s|^127\\.0\\.1\\.1[[:space:]].*|$line|" /etc/hosts \
            && ok "Updated the 127.0.1.1 entry in /etc/hosts" \
            || record_failure "Could not update /etc/hosts"
    else
        ensure_line_in_file "$line" /etc/hosts \
            && ok "Added the 127.0.1.1 entry to /etc/hosts" \
            || record_failure "Could not update /etc/hosts"
    fi
}
