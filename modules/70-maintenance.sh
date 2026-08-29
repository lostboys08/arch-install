#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 70-maintenance.sh - the housekeeping a workstation should not have to think
# about: cache trimming, TRIM, mirror ranking, OOM protection, a firewall and
# laptop power management.
# Provides: setup_maintenance()

setup_maintenance() {
    _maintenance_pacman_cache
    _maintenance_fstrim
    _maintenance_oom
    _maintenance_mirrors
    _maintenance_firewall
    _maintenance_power
}

# Keep the last 2 versions of every package instead of an unbounded cache.
_maintenance_pacman_cache() {
    pacman_install pacman-contrib || { record_failure "Could not install pacman-contrib"; return 0; }
    enable_unit paccache.timer
}

_maintenance_fstrim() {
    enable_unit fstrim.timer
}

# A runaway build should not take the desktop down with it.
_maintenance_oom() {
    pacman_install earlyoom || { record_failure "Could not install earlyoom"; return 0; }

    install_system_file /etc/systemd/system/earlyoom.service.d/prymx.conf 644 <<'CONF'
# Managed by PrymX (modules/70-maintenance.sh)
[Service]
Environment=EARLYOOM_ARGS=-r 3600 -m 4 -s 10 --avoid '(^|/)(init|systemd|Xorg|niri|sshd)$' --prefer '(^|/)(chromium|firefox|electron|cargo|rustc|cc1plus|ld)$'
CONF

    enable_unit earlyoom.service
}

_maintenance_mirrors() {
    pacman_install reflector || { record_failure "Could not install reflector"; return 0; }

    install_system_file /etc/xdg/reflector/reflector.conf 644 <<'CONF'
# Managed by PrymX (modules/70-maintenance.sh)
--save /etc/pacman.d/mirrorlist
--protocol https
--latest 20
--sort rate
CONF

    enable_unit reflector.timer
}

# The user may well have set this up already; only fill in what is missing.
_maintenance_firewall() {
    pacman_install ufw || { record_failure "Could not install ufw"; return 0; }

    local status
    status=$(sudo ufw status 2>/dev/null | head -n1 || true)

    if [[ $status == *active* ]]; then
        skip "ufw is already active"
    else
        log "Setting the default ufw policy (deny incoming, allow outgoing)"
        sudo ufw --force default deny incoming >/dev/null 2>&1 || warn "Could not set the incoming policy"
        sudo ufw --force default allow outgoing >/dev/null 2>&1 || warn "Could not set the outgoing policy"

        # Do not lock the machine out of its own sshd.
        if unit_exists sshd.service && [[ $(systemctl is-enabled sshd.service 2>/dev/null) == enabled ]]; then
            log "sshd is enabled - allowing (rate-limited) SSH"
            sudo ufw limit ssh >/dev/null 2>&1 || warn "Could not add the SSH rule"
        fi

        sudo ufw --force enable >/dev/null 2>&1 \
            && ok "ufw enabled" \
            || record_failure "Could not enable ufw"
    fi

    enable_unit ufw.service
}

# Laptop profile only: tlp conflicts with power-profiles-daemon, so pick one.
_maintenance_power() {
    [[ ${PRYMX_PROFILE:-desktop} == laptop ]] || return 0

    if pkg_installed power-profiles-daemon; then
        skip "power-profiles-daemon is installed - not adding tlp"
        enable_unit power-profiles-daemon.service
        return 0
    fi

    pacman_install tlp tlp-rdw || { record_failure "Could not install tlp"; return 0; }
    enable_unit tlp.service
    enable_unit NetworkManager-dispatcher.service
}
