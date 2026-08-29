#!/usr/bin/env bash
# shellcheck shell=bash
[[ -n ${PRYMX_COMMON_SOURCED:-} ]] || \
    source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
#
# 20-github.sh - interactive GitHub CLI, git identity and SSH key setup.
# Provides: setup_github_interactive()

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

setup_github_interactive() {
    if ! have_cmd gh; then
        warn "github-cli (gh) is not installed - skipping GitHub setup"
        return 0
    fi
    if ! have_tty; then
        warn "No interactive terminal - skipping GitHub setup (re-run from a TTY)"
        return 0
    fi

    _gh_authenticate || return 1
    _git_identity
    _ssh_key_setup
}

# bootstrap.sh tees its output to a log file, so stdout is a pipe. gh's
# interactive login needs a real terminal; give it one when we have it.
_run_interactive() {
    if [[ -c /dev/tty ]]; then
        "$@" < /dev/tty > /dev/tty 2>&1
    else
        "$@"
    fi
}

_gh_authenticate() {
    if gh auth status >/dev/null 2>&1; then
        skip "Already authenticated with GitHub"
    else
        log "Not authenticated - starting 'gh auth login'"
        if ! _run_interactive gh auth login; then
            err "gh auth login failed or was cancelled"
            return 1
        fi
        ok "Authenticated with GitHub"
    fi

    if gh auth setup-git; then
        ok "git is configured to use gh as a credential helper"
    else
        warn "gh auth setup-git failed"
    fi
}

_git_identity() {
    local name email

    name=$(git config --global --get user.name || true)
    if [[ -z $name ]]; then
        read -r -p "  git user.name : " name || true
        if [[ -n $name ]]; then
            git config --global user.name "$name"
            ok "Set git user.name to '$name'"
        else
            warn "git user.name left unset"
        fi
    else
        skip "git user.name is already '$name'"
    fi

    email=$(git config --global --get user.email || true)
    if [[ -z $email ]]; then
        read -r -p "  git user.email: " email || true
        if [[ -n $email ]]; then
            git config --global user.email "$email"
            ok "Set git user.email to '$email'"
        else
            warn "git user.email left unset"
        fi
    else
        skip "git user.email is already '$email'"
    fi
}

_ssh_key_setup() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    local comment
    comment=$(git config --global --get user.email || true)
    [[ -n $comment ]] || comment="$USER@$(hostname)"

    if [[ -f $SSH_KEY_PATH ]]; then
        skip "SSH key already exists at $SSH_KEY_PATH"
    else
        log "Generating an ed25519 SSH key at $SSH_KEY_PATH"
        if ! ssh-keygen -t ed25519 -C "$comment" -f "$SSH_KEY_PATH" -N ""; then
            err "ssh-keygen failed"
            return 1
        fi
        chmod 600 "$SSH_KEY_PATH"
        chmod 644 "$SSH_KEY_PATH.pub"
        ok "SSH key generated"
    fi

    _ssh_key_upload
}

_ssh_key_upload() {
    local pub_file="$SSH_KEY_PATH.pub"
    [[ -f $pub_file ]] || { warn "No public key at $pub_file - nothing to upload"; return 0; }

    # The key body (field 2) is what GitHub stores; compare against it so a
    # re-run does not upload the same key under a new title.
    local key_body
    key_body=$(awk '{print $2}' "$pub_file")

    if gh ssh-key list 2>/dev/null | grep -qF "$key_body"; then
        skip "This SSH key is already on the GitHub account"
        return 0
    fi

    local title
    title="$(hostname)-$(date +%Y-%m-%d)"
    log "Uploading the public key to GitHub as '$title'"
    if gh ssh-key add "$pub_file" --title "$title"; then
        ok "SSH key uploaded"
    else
        warn "Could not upload the SSH key (missing scope? try: gh auth refresh -h github.com -s admin:public_key)"
    fi
}
