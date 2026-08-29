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
    _maintenance_microcode
    _maintenance_pacman_cache
    _maintenance_fstrim
    _maintenance_oom
    _maintenance_mirrors
    _maintenance_firewall
    _maintenance_docker_ports
    _maintenance_power
}

# Microcode updates are applied by the bootloader at boot; without the package
# the CPU runs with whatever errata shipped in silicon.
_maintenance_microcode() {
    local vendor pkg
    vendor=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)

    case $vendor in
        GenuineIntel) pkg=intel-ucode ;;
        AuthenticAMD) pkg=amd-ucode ;;
        *) skip "Unknown CPU vendor '${vendor:-unknown}' - skipping microcode"; return 0 ;;
    esac

    if pkg_installed "$pkg"; then
        skip "$pkg is already installed"
        return 0
    fi

    pacman_install "$pkg" || { record_failure "Could not install $pkg"; return 0; }

    # The package alone is not enough: the bootloader has to load the image.
    if have_cmd grub-mkconfig && [[ -d /boot/grub ]]; then
        sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 \
            && ok "GRUB regenerated with $pkg" \
            || record_failure "Installed $pkg but could not regenerate the GRUB config"
    elif [[ -d /boot/loader/entries ]]; then
        warn "Installed $pkg - add 'initrd /$pkg.img' above the main initrd in your systemd-boot entry"
    else
        warn "Installed $pkg - make sure your bootloader loads /boot/$pkg.img"
    fi
}

# docker inserts its own iptables rules ahead of ufw's, so a published port
# is reachable from the LAN whatever `ufw status` says. Binding published
# ports to loopback by default closes that without breaking containers;
# anything that genuinely needs to listen wider says so explicitly with
# `-p 0.0.0.0:8080:80`.
_maintenance_docker_ports() {
    have_cmd docker || { skip "docker is not installed - no port hardening needed"; return 0; }

    local conf=/etc/docker/daemon.json

    if sudo test -f "$conf"; then
        if sudo grep -q '"ip"' "$conf"; then
            skip "$conf already sets a default publish address"
        else
            warn "$conf exists and is not managed by PrymX - not overwriting it"
            log  'Add   "ip": "127.0.0.1"   to it so published ports do not bypass ufw'
        fi
        return 0
    fi

    install_system_file "$conf" 644 <<'CONF' || { record_failure "Could not write $conf"; return 0; }
{
  "ip": "127.0.0.1"
}
CONF

    if have_systemd && [[ $(systemctl is-active docker.service 2>/dev/null) == active ]]; then
        sudo systemctl restart docker.service >/dev/null 2>&1 \
            && ok "Restarted docker to apply the publish address" \
            || warn "Could not restart docker; the setting applies at the next restart"
    fi
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
