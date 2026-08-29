#!/usr/bin/env bash
#
# PrymX pacman guard - installed to /usr/local/lib/prymx/pacman-guard and run
# as a PreTransaction alpm hook. Exiting non-zero aborts the transaction.
#
# An upgrade is allowed when PrymX started it (it holds the lock below), or
# when the caller opts out explicitly with PRYMX_ALLOW_PACMAN=1.
set -euo pipefail

# The path is overridable so the test suite can exercise this without /run.
LOCK="${PRYMX_LOCK_FILE:-/run/prymx/pacman.lock}"

if [[ ${PRYMX_ALLOW_PACMAN:-0} == 1 ]]; then
    exit 0
fi

if [[ -f $LOCK ]]; then
    pid=$(cat "$LOCK" 2>/dev/null || true)
    # A lock whose owner is gone is stale (a crashed run); ignore it.
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        exit 0
    fi
fi

cat >&2 <<'MSG'

  ┌────────────────────────────────────────────────────────────────────┐
  │  PrymX: upgrades are managed by `prym`                             │
  └────────────────────────────────────────────────────────────────────┘

  This transaction would upgrade installed packages without taking a
  Btrfs snapshot first. Use:

      prym update            full system upgrade, snapshot taken first
      prym sync              re-apply packages and dotfiles from the repo

  If you really need to run pacman or paru directly this once:

      sudo PRYMX_ALLOW_PACMAN=1 pacman -Syu

  Removing packages and installing new ones is not affected by this guard.

MSG
exit 1
