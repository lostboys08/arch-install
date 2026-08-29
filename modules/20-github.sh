#!/usr/bin/env bash
# shellcheck shell=bash
#
# 20-github.sh - interactive GitHub CLI, git identity and SSH key setup.
# Sourced by bootstrap.sh. Provides: setup_github_interactive()

if ! declare -F log >/dev/null 2>&1; then
    log()  { printf '  -> %s\n' "$*"; }
    ok()   { printf '  ok %s\n' "$*"; }
    warn() { printf '   ! %s\n' "$*" >&2; }
    err()  { printf '   x %s\n' "$*" >&2; }
fi

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

setup_github_interactive() {
    if ! command -v gh >/dev/null 2>&1; then
        warn "github-cli (gh) is not installed - skipping GitHub setup"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        warn "No interactive terminal - skipping GitHub setup (re-run bootstrap.sh from a TTY)"
        return 0
    fi

    _gh_authenticate || return 1
    _git_identity
    _ssh_key_setup
}

_gh_authenticate() {
    if gh auth status >/dev/null 2>&1; then
        ok "Already authenticated with GitHub"
    else
        log "Not authenticated - starting 'gh auth login'"
        if ! gh auth login; then
            err "gh auth login failed or was cancelled"
            return 1
        fi
        ok "Authenticated with GitHub"
    fi

    if gh auth setup-git; then
        ok "Configured git to use gh as a credential helper"
    else
        warn "gh auth setup-git failed"
    fi
}

_git_identity() {
    local name email

    name=$(git config --global --get user.name || true)
    if [[ -z $name ]]; then
        read -r -p "  git user.name : " name
        if [[ -n $name ]]; then
            git config --global user.name "$name"
            ok "Set git user.name to '$name'"
        else
            warn "git user.name left unset"
        fi
    else
        ok "git user.name is already set to '$name'"
    fi

    email=$(git config --global --get user.email || true)
    if [[ -z $email ]]; then
        read -r -p "  git user.email: " email
        if [[ -n $email ]]; then
            git config --global user.email "$email"
            ok "Set git user.email to '$email'"
        else
            warn "git user.email left unset"
        fi
    else
        ok "git user.email is already set to '$email'"
    fi
}

_ssh_key_setup() {
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    local comment
    comment=$(git config --global --get user.email || true)
    [[ -n $comment ]] || comment="${USER:-$(id -un)}@$(hostname)"

    if [[ -f $SSH_KEY_PATH ]]; then
        ok "SSH key already exists at $SSH_KEY_PATH"
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

    # The key body (field 2) is what GitHub stores; compare against it so the
    # key is not uploaded twice under a different title.
    local key_body
    key_body=$(awk '{print $2}' "$pub_file")

    if gh ssh-key list 2>/dev/null | grep -qF "$key_body"; then
        ok "This SSH key is already on the GitHub account"
        return 0
    fi

    local title
    title="$(hostname)-$(date +%Y-%m-%d)"
    log "Uploading the public key to GitHub as '$title'"
    if gh ssh-key add "$pub_file" --title "$title"; then
        ok "SSH key uploaded"
    else
        warn "Could not upload the SSH key (the 'admin:public_key' scope may be missing; try: gh auth refresh -h github.com -s admin:public_key)"
    fi
}
