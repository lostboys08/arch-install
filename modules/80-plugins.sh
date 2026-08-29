#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 80-plugins.sh - bootstrap the plugin managers the dotfiles expect, so the
# editor/shell/multiplexer configs are a starting point rather than a
# frozen baseline.
# Provides: setup_plugin_managers()
#
# Everything here needs the network and is therefore best-effort: a failure
# warns and moves on, and every step is a no-op once it has run.

TPM_DIR="$HOME/.config/tmux/plugins/tpm"
TPM_URL="https://github.com/tmux-plugins/tpm"

setup_plugin_managers() {
    _plugins_tmux
    _plugins_fish
    _plugins_nvim
}

_plugins_tmux() {
    have_cmd tmux || { skip "tmux is not installed - skipping TPM"; return 0; }
    have_cmd git  || return 0

    if [[ -d $TPM_DIR/.git ]]; then
        skip "TPM is already installed"
    else
        log "Installing TPM (tmux plugin manager)"
        if ! git clone --depth 1 "$TPM_URL" "$TPM_DIR" >/dev/null 2>&1; then
            warn "Could not clone TPM from $TPM_URL"
            return 0
        fi
        ok "TPM installed"
    fi

    if [[ -x $TPM_DIR/bin/install_plugins ]]; then
        log "Installing tmux plugins"
        "$TPM_DIR/bin/install_plugins" >/dev/null 2>&1 \
            && ok "tmux plugins installed" \
            || warn "TPM could not install every plugin (run prefix + I inside tmux)"
    fi
}

_plugins_fish() {
    have_cmd fish || { skip "fish is not installed - skipping fisher"; return 0; }

    if fish -c 'functions -q fisher' >/dev/null 2>&1; then
        skip "fisher is already installed"
    else
        log "Installing fisher (fish plugin manager)"
        if ! fish -c 'curl -sSL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher install jorgebucaran/fisher' >/dev/null 2>&1; then
            warn "Could not install fisher"
            return 0
        fi
        ok "fisher installed"
    fi

    # fisher update with no arguments installs everything in fish_plugins.
    if [[ -f $HOME/.config/fish/fish_plugins ]]; then
        log "Installing fish plugins"
        fish -c 'fisher update' >/dev/null 2>&1 \
            && ok "fish plugins installed" \
            || warn "fisher could not install every plugin"
    fi
}

_plugins_nvim() {
    have_cmd nvim || { skip "neovim is not installed - skipping lazy.nvim"; return 0; }

    # init.lua bootstraps lazy.nvim itself; this just does the first sync
    # up front instead of on the user's first launch.
    log "Syncing neovim plugins (lazy.nvim)"
    if nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
        ok "neovim plugins installed"
    else
        warn "lazy.nvim could not sync (it will retry on the next nvim launch)"
    fi
}
