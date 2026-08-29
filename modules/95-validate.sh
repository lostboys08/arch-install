#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 95-validate.sh - parse the configs we just linked, before the user reboots
# into them. A broken niri config means a login with no session, which is a
# miserable thing to discover from a greeter.
# Provides: validate_configs()

validate_configs() {
    local failures_before=${#PRYMX_FAILURES[@]}

    _validate_niri
    _validate_fish
    _validate_tmux
    _validate_ghostty
    _validate_nvim
    _validate_json

    if (( ${#PRYMX_FAILURES[@]} == failures_before )); then
        ok "Every config that could be checked parses"
    fi
}

# A bad compositor config is the only one that costs you a session.
_validate_niri() {
    local conf="$HOME/.config/niri/config.kdl"
    have_cmd niri || { skip "niri is not installed - not validating its config"; return 0; }
    [[ -f $conf ]] || { warn "No $conf to validate"; return 0; }

    local out
    if out=$(niri validate --config "$conf" 2>&1); then
        ok "niri config is valid"
    else
        record_failure "niri config does not parse - fix it before rebooting"
        printf '%s\n' "$out" | sed 's/^/       /' >&2
    fi
}

_validate_fish() {
    local conf="$HOME/.config/fish/config.fish"
    have_cmd fish || { skip "fish is not installed - not validating its config"; return 0; }
    [[ -f $conf ]] || return 0

    local out
    if out=$(fish --no-execute "$conf" 2>&1); then
        ok "fish config parses"
    else
        record_failure "fish config does not parse (it is your login shell)"
        printf '%s\n' "$out" | sed 's/^/       /' >&2
    fi
}

# Sourced on a throwaway server so the user's running tmux is untouched.
_validate_tmux() {
    local conf="$HOME/.config/tmux/tmux.conf"
    have_cmd tmux || { skip "tmux is not installed - not validating its config"; return 0; }
    [[ -f $conf ]] || return 0

    local out
    if out=$(tmux -L prymx-validate -f "$conf" start-server \; kill-server 2>&1); then
        ok "tmux config parses"
    else
        # TPM's plugin lines fail before the plugins are cloned; not fatal.
        warn "tmux reported: $(head -n1 <<<"$out")"
    fi
}

# ghostty logs configuration errors but still starts, so this is advisory.
_validate_ghostty() {
    have_cmd ghostty || { skip "ghostty is not installed - not validating its config"; return 0; }

    local out
    if out=$(ghostty +validate-config 2>&1); then
        ok "ghostty config parses"
    else
        warn "ghostty could not validate its config: $(head -n1 <<<"$out")"
    fi
}

_validate_nvim() {
    have_cmd nvim || { skip "neovim is not installed - not validating its config"; return 0; }

    local out
    out=$(nvim --headless "+qall" 2>&1)
    if grep -qiE '^(E[0-9]+:|Error)' <<<"$out"; then
        record_failure "neovim reported errors while loading its config"
        printf '%s\n' "$out" | head -5 | sed 's/^/       /' >&2
    else
        ok "neovim config loads"
    fi
}

# waybar and swaync fail silently on malformed JSON, which reads as "the bar
# just did not start".
_validate_json() {
    have_cmd python3 || { skip "python3 is not installed - not validating the JSON configs"; return 0; }

    local f
    for f in "$HOME/.config/waybar/config.jsonc" "$HOME/.config/swaync/config.json"; do
        [[ -f $f ]] || continue
        if _json_parses "$f"; then
            ok "$(basename "$f") parses"
        else
            record_failure "$f is not valid JSON"
        fi
    done
}

# waybar accepts // comments, which json.tool does not; strip them first.
_json_parses() {
    python3 - "$1" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
stripped = re.sub(r'(?m)^\s*//.*$', '', raw)
try:
    json.loads(stripped)
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
PY
}
