#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 40-gpu.sh - graphics drivers and Vulkan, detected from the hardware.
# Provides: setup_gpu_drivers()
#
# Everything here goes through pacman --needed, so a machine that already has
# its drivers (e.g. installed by archinstall) is left alone.

# Turing (GTX 16xx / RTX 20xx) and newer. Older cards need nvidia-dkms;
# override with PRYMX_NVIDIA_PKG=nvidia-dkms.
PRYMX_NVIDIA_PKG="${PRYMX_NVIDIA_PKG:-nvidia-open-dkms}"

setup_gpu_drivers() {
    have_cmd lspci || pacman_install pciutils || {
        err "pciutils is required to detect the GPU"
        return 1
    }

    local vendors
    vendors=$(_gpu_vendors)

    if [[ -z $vendors ]]; then
        warn "No GPU detected by lspci - skipping driver setup"
        return 0
    fi
    log "Detected GPU vendor(s): $(tr '\n' ' ' <<<"$vendors")"

    # The loader and the 32-bit loader are what Steam and Proton look for.
    pacman_install vulkan-icd-loader lib32-vulkan-icd-loader mesa lib32-mesa \
        || record_failure "Could not install the common Vulkan/mesa packages"

    local vendor
    while IFS= read -r vendor; do
        [[ -n $vendor ]] || continue
        case $vendor in
            amd)    _gpu_setup_amd ;;
            intel)  _gpu_setup_intel ;;
            nvidia) _gpu_setup_nvidia ;;
        esac
    done <<<"$vendors"
}

# Matching is on PCI vendor IDs first (10de NVIDIA, 1002/1022 AMD, 8086
# Intel), with a word-boundary name match as a fallback. Plain substring
# matching is unsafe here: every "VGA compatible controller" line contains
# "ati", which made every machine look like it had an AMD card.
_gpu_vendors() {
    local devices
    devices=$(lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
    grep -Eqi '\[10de:|\bnvidia\b'                        <<<"$devices" && echo nvidia
    grep -Eqi '\[1002:|\[1022:|\bamd\b|\bati\b|\bradeon\b' <<<"$devices" && echo amd
    grep -Eqi '\[8086:|\bintel\b'                         <<<"$devices" && echo intel
    return 0
}

_gpu_setup_amd() {
    log "AMD graphics"
    pacman_install vulkan-radeon lib32-vulkan-radeon vulkan-mesa-layers \
        lib32-vulkan-mesa-layers libva-utils \
        || record_failure "Could not install the AMD graphics packages"
}

_gpu_setup_intel() {
    log "Intel graphics"
    pacman_install vulkan-intel lib32-vulkan-intel intel-media-driver \
        || record_failure "Could not install the Intel graphics packages"
}

_gpu_setup_nvidia() {
    log "NVIDIA graphics ($PRYMX_NVIDIA_PKG)"

    local pkgs=("$PRYMX_NVIDIA_PKG" nvidia-utils lib32-nvidia-utils nvidia-settings)

    # DKMS needs headers for every installed kernel.
    local kernel
    for kernel in linux linux-lts linux-zen linux-hardened; do
        pkg_installed "$kernel" && pkgs+=("$kernel-headers")
    done

    pacman_install "${pkgs[@]}" || {
        record_failure "Could not install the NVIDIA driver packages"
        return 0
    }

    # Wayland compositors (niri included) need DRM kernel mode setting.
    install_system_file /etc/modprobe.d/prymx-nvidia.conf 644 <<'CONF'
# Managed by PrymX (modules/40-gpu.sh)
# DRM kernel mode setting is required for Wayland compositors.
options nvidia_drm modeset=1 fbdev=1
CONF

    _gpu_nvidia_initramfs
}

# Put the nvidia modules in the initramfs so KMS happens early; skipped when
# they are already listed.
_gpu_nvidia_initramfs() {
    local conf=/etc/mkinitcpio.conf
    [[ -f $conf ]] || { skip "No $conf - not touching the initramfs"; return 0; }

    if grep -Eq '^MODULES=.*nvidia_drm' "$conf"; then
        skip "nvidia modules are already in the initramfs"
        return 0
    fi

    log "Adding the nvidia modules to $conf"
    sudo cp -a "$conf" "$conf.prymx.bak"

    # Append inside the existing MODULES=(...) array, whatever it holds.
    if ! sudo sed -i -E 's/^(MODULES=\()(.*)(\))$/\1\2 nvidia nvidia_modeset nvidia_uvm nvidia_drm\3/; s/^MODULES=\( +/MODULES=(/' "$conf"; then
        record_failure "Could not edit $conf (a backup is at $conf.prymx.bak)"
        return 0
    fi

    if ! grep -Eq '^MODULES=.*nvidia_drm' "$conf"; then
        record_failure "MODULES= line in $conf was not in the expected form; edit it by hand"
        return 0
    fi

    log "Regenerating the initramfs (this takes a moment)"
    sudo mkinitcpio -P >/dev/null 2>&1 \
        && ok "initramfs regenerated" \
        || record_failure "mkinitcpio failed; the previous $conf is at $conf.prymx.bak"
}
