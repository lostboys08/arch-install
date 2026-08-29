#!/usr/bin/env bash
#
# PrymX test suite.
#
# Runs anywhere bash, git and stow are available - no Arch, no root, and
# nothing outside a scratch directory is touched. Stubs stand in for sudo,
# pacman, paru and friends.
#
#   tests/run-tests.sh            run everything
#   tests/run-tests.sh stow       run tests whose name matches 'stow'
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER=${1:-}

PASS=0
FAIL=0
SKIPPED=0
FAILED_NAMES=()

WORK=$(mktemp -d -t prymx-tests-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then G=$'\033[0;32m'; R=$'\033[0;31m'; D=$'\033[2m'; N=$'\033[0m'
else G=''; R=''; D=''; N=''; fi

CURRENT=""

it() {
    CURRENT=$1
    [[ -z $FILTER || $CURRENT == *"$FILTER"* ]]
}

pass() { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$G" "$N" "$CURRENT"; }
skipped() {
    SKIPPED=$((SKIPPED + 1))
    printf '  %sskip%s %s %s(%s)%s\n' "$D" "$N" "$CURRENT" "$D" "$1" "$N"
}
fail() {
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$CURRENT")
    printf '  %sFAIL%s %s\n       %s\n' "$R" "$N" "$CURRENT" "$1"
}

assert_eq() {
    [[ $1 == "$2" ]] && return 0
    fail "expected '$2', got '$1'"
    return 1
}
assert_contains() {
    [[ $1 == *"$2"* ]] && return 0
    fail "expected output to contain '$2'; got: $(head -c 400 <<<"$1")"
    return 1
}
assert_not_contains() {
    [[ $1 != *"$2"* ]] && return 0
    fail "expected output NOT to contain '$2'"
    return 1
}
assert_ok()   { assert_eq "$1" 0 || return 1; }
assert_fails() { [[ $1 != 0 ]] && return 0; fail "expected a non-zero exit, got 0"; return 1; }

# ---------------------------------------------------------------------------
# Stubs: a PATH shim so nothing real is invoked.
# ---------------------------------------------------------------------------

STUB="$WORK/stub"
mkdir -p "$STUB"

cat > "$STUB/sudo" <<'EOF'
#!/bin/sh
# Drop leading VAR=value arguments, then run the command as-is.
while [ $# -gt 0 ]; do
    case "$1" in
        -n|-E) shift ;;
        -v) exit 0 ;;
        *=*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF

cat > "$STUB/paru" <<'EOF'
#!/bin/sh
# Counts the package list handed to it on stdin; fails for the list whose
# length matches PARU_FAIL, so failure handling can be exercised.
case " $* " in *" - "*) n=$(cat | wc -l) ;; *) n=0 ;; esac
echo "[stub] paru $* <- $n packages"
[ "${PARU_FAIL:-x}" = "$n" ] && exit 1
exit 0
EOF

cat > "$STUB/pacman" <<'EOF'
#!/bin/sh
case "$1" in
    -Qq) [ -n "${PACMAN_INSTALLED:-}" ] && echo "$PACMAN_INSTALLED" | tr ' ' '\n' | grep -qx "$2" ;;
    *) echo "[stub] pacman $*"; exit 0 ;;
esac
EOF

cat > "$STUB/ldd" <<'EOF'
#!/bin/sh
# Reports the libalpm soname the "binary" was linked against, so the health
# probe can be exercised without a real paru.
[ -n "${STUB_PARU_ALPM:-}" ] || { echo "	not a dynamic executable"; exit 1; }
echo "	libalpm.so.$STUB_PARU_ALPM => /usr/lib/libalpm.so.$STUB_PARU_ALPM (0x0)"
EOF

cat > "$STUB/systemctl" <<'EOF'
#!/bin/sh
echo "[stub] systemctl $*" >&2
exit 1
EOF

cat > "$STUB/findmnt" <<'EOF'
#!/bin/sh
echo "${STUB_ROOT_FSTYPE:-ext4}"
EOF

chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

# ---------------------------------------------------------------------------
# bootstrap.sh: arguments and step selection
# ---------------------------------------------------------------------------

printf '\n%s bootstrap.sh: arguments%s\n' "$D" "$N"

if it "--list prints every step"; then
    out=$("$REPO/bootstrap.sh" --list); rc=$?
    assert_ok "$rc" && assert_contains "$out" "multilib" \
        && assert_contains "$out" "github" && pass
fi

if it "--help exits cleanly"; then
    out=$("$REPO/bootstrap.sh" --help); rc=$?
    assert_ok "$rc" && assert_contains "$out" "USAGE" && pass
fi

if it "--dry-run marks only the selected steps"; then
    out=$("$REPO/bootstrap.sh" --dry-run --only gpu,dotfiles 2>&1); rc=$?
    assert_ok "$rc" \
        && assert_contains "$out" " run  gpu" \
        && assert_contains "$out" "skip github" && pass
fi

if it "--skip removes a step from the plan"; then
    out=$("$REPO/bootstrap.sh" --dry-run --skip github 2>&1)
    assert_contains "$out" "skip github" && assert_contains "$out" " run  gpu" && pass
fi

if it "rejects an unknown step name"; then
    out=$("$REPO/bootstrap.sh" --only nope 2>&1); rc=$?
    assert_fails "$rc" && assert_contains "$out" "Unknown step" && pass
fi

if it "rejects an unknown profile"; then
    out=$("$REPO/bootstrap.sh" --dry-run --profile server 2>&1); rc=$?
    assert_fails "$rc" && assert_contains "$out" "Unknown profile" && pass
fi

if it "rejects an option that needs a value"; then
    out=$("$REPO/bootstrap.sh" --only 2>&1); rc=$?
    assert_fails "$rc" && assert_contains "$out" "needs a value" && pass
fi

if it "refuses to run as root"; then
    if [[ $EUID -eq 0 ]]; then
        out=$("$REPO/bootstrap.sh" --no-log 2>&1); rc=$?
        assert_fails "$rc" && assert_contains "$out" "Do not run this as root" && pass
    else
        # Not root: assert the guard exists rather than skipping silently.
        grep -q 'is_root && die' "$REPO/bootstrap.sh" \
            && pass || fail "no root guard found in bootstrap.sh"
    fi
fi

# ---------------------------------------------------------------------------
# Library functions
# ---------------------------------------------------------------------------

printf '\n%s lib/common.sh%s\n' "$D" "$N"

# Source bootstrap.sh for its functions without running it. It sets -e for
# its own execution; the harness needs to keep running past failures.
# shellcheck source=/dev/null
source "$REPO/bootstrap.sh" >/dev/null 2>&1
set +e +o pipefail
set -uo pipefail

if it "package_lists puts core first and unknown lists last"; then
    pkgdir="$WORK/packages"; mkdir -p "$pkgdir"
    for f in core dev gui-niri audio fonts gaming zz-extra; do echo pkg > "$pkgdir/$f.txt"; done
    out=$(package_lists "$pkgdir" | xargs -n1 basename | tr '\n' ' ')
    assert_eq "$out" "core.txt dev.txt gui-niri.txt audio.txt fonts.txt gaming.txt zz-extra.txt " && pass
fi

if it "install_package_lists reports a failing list without aborting"; then
    pkgdir="$WORK/pkg2"; mkdir -p "$pkgdir/profiles"
    printf 'a\nb\nc\n' > "$pkgdir/core.txt"
    printf 'd\ne\n'     > "$pkgdir/dev.txt"
    printf 'f\n'        > "$pkgdir/profiles/laptop.txt"
    PRYMX_FAILURES=()
    out=$(PARU_FAIL=2 install_package_lists "$pkgdir" laptop 2>&1)
    assert_contains "$out" "core up to date" \
        && assert_contains "$out" "Package list 'dev' did not install cleanly" \
        && assert_contains "$out" "profile:laptop up to date" && pass
fi

if it "install_package_lists skips empty lists"; then
    pkgdir="$WORK/pkg3"; mkdir -p "$pkgdir"; : > "$pkgdir/core.txt"
    PRYMX_FAILURES=()
    out=$(install_package_lists "$pkgdir" "" 2>&1)
    assert_contains "$out" "core.txt is empty" && pass
fi

if it "install_system_file writes once and is quiet on re-run"; then
    dest="$WORK/etc/example.conf"
    out1=$(printf 'hello\n' | install_system_file "$dest" 644 2>&1)
    out2=$(printf 'hello\n' | install_system_file "$dest" 644 2>&1)
    out3=$(printf 'goodbye\n' | install_system_file "$dest" 644 2>&1)
    assert_contains "$out1" "Wrote $dest" \
        && assert_contains "$out2" "already up to date" \
        && assert_contains "$out3" "Wrote $dest" \
        && assert_eq "$(cat "$dest")" "goodbye" && pass
fi

if it "ensure_line_in_file does not duplicate a line"; then
    f="$WORK/shells"; printf '/bin/sh\n' > "$f"
    ensure_line_in_file "/usr/bin/fish" "$f"
    ensure_line_in_file "/usr/bin/fish" "$f"
    assert_eq "$(grep -c fish "$f")" "1" && pass
fi

if it "set_ini_key_if_present only touches keys that exist"; then
    f="$WORK/config.ini"; printf 'animation = fun\n# clock = x\n' > "$f"
    set_ini_key_if_present "$f" animation none
    set_ini_key_if_present "$f" clock "%%F"
    set_ini_key_if_present "$f" invented_key value
    out=$(cat "$f")
    assert_contains "$out" "animation = none" \
        && assert_not_contains "$out" "invented_key" && pass
fi

if it "snapper_snapshot is a no-op when root is not btrfs"; then
    PRYMX_FAILURES=()
    out=$(STUB_ROOT_FSTYPE=ext4 snapper_snapshot "test" 2>&1)
    assert_contains "$out" "not btrfs" && assert_eq "${#PRYMX_FAILURES[@]}" "0" && pass
fi

if it "enable_multilib uncomments [multilib] but not [multilib-testing]"; then
    conf="$WORK/pacman.conf"
    cat > "$conf" <<'CONF'
[core]
Include = /etc/pacman.d/mirrorlist

#[multilib-testing]
#Include = /etc/pacman.d/mirrorlist

#[multilib]
#Include = /etc/pacman.d/mirrorlist
CONF
    PACMAN_CONF="$conf" enable_multilib >/dev/null 2>&1
    out=$(cat "$conf")
    assert_contains "$out" $'[multilib]\nInclude' \
        && assert_contains "$out" "#[multilib-testing]" && pass
fi

if it "enable_multilib appends the section when there is nothing to uncomment"; then
    conf="$WORK/pacman2.conf"; printf '[core]\nInclude = /etc/pacman.d/mirrorlist\n' > "$conf"
    PACMAN_CONF="$conf" enable_multilib >/dev/null 2>&1
    assert_contains "$(cat "$conf")" $'[multilib]\nInclude = /etc/pacman.d/mirrorlist' && pass
fi

if it "enable_multilib is a no-op when multilib is already enabled"; then
    conf="$WORK/pacman3.conf"; printf '[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' > "$conf"
    before=$(cat "$conf")
    out=$(PACMAN_CONF="$conf" enable_multilib 2>&1)
    assert_contains "$out" "already enabled" && assert_eq "$(cat "$conf")" "$before" && pass
fi

# ---------------------------------------------------------------------------
# Dotfiles
# ---------------------------------------------------------------------------

printf '\n%s dotfiles (GNU Stow)%s\n' "$D" "$N"

if it "stow links every package into HOME"; then
    if ! command -v stow >/dev/null; then
        fail "stow is not installed"
    else
        home="$WORK/home1"; mkdir -p "$home"
        PRYMX_FAILURES=()
        out=$(stow_dotfiles "$REPO/dotfiles" "$home" 2>&1)
        assert_contains "$out" "Linked ghostty" \
            && [[ -L "$home/.config/nvim/init.lua" ]] \
            && [[ -L "$home/.config/fish/config.fish" ]] \
            && assert_eq "${#PRYMX_FAILURES[@]}" "0" && pass
    fi
fi

if it "stow is idempotent on a second run"; then
    if ! command -v stow >/dev/null; then fail "stow is not installed"; else
        home="$WORK/home2"; mkdir -p "$home"
        PRYMX_FAILURES=()
        stow_dotfiles "$REPO/dotfiles" "$home" >/dev/null 2>&1
        before=$(find "$home" | sort)
        stow_dotfiles "$REPO/dotfiles" "$home" >/dev/null 2>&1
        after=$(find "$home" | sort)
        assert_eq "$after" "$before" && assert_eq "${#PRYMX_FAILURES[@]}" "0" && pass
    fi
fi

if it "stow records a conflict instead of aborting"; then
    if ! command -v stow >/dev/null; then fail "stow is not installed"; else
        home="$WORK/home3"; mkdir -p "$home/.config/tmux"
        echo "mine" > "$home/.config/tmux/tmux.conf"
        PRYMX_FAILURES=()
        out=$(stow_dotfiles "$REPO/dotfiles" "$home" 2>&1)
        assert_contains "$out" "stow failed for 'tmux'" \
            && [[ -L "$home/.config/fish/config.fish" ]] \
            && assert_eq "$(cat "$home/.config/tmux/tmux.conf")" "mine" && pass
    fi
fi

if it "no stow package writes outside HOME"; then
    bad=$(find "$REPO/dotfiles" -mindepth 2 -maxdepth 2 -name '.*' -prune -o -mindepth 2 -maxdepth 2 -print | grep -v '/\.config$' || true)
    assert_eq "$bad" "" && pass
fi

# ---------------------------------------------------------------------------
# The pacman upgrade guard
# ---------------------------------------------------------------------------

printf '\n%s pacman guard%s\n' "$D" "$N"

GUARD="$REPO/system/pacman-guard.sh"
LOCKFILE="$WORK/pacman.lock"

if it "guard blocks an upgrade with no lock"; then
    rm -f "$LOCKFILE"
    out=$(PRYMX_LOCK_FILE="$LOCKFILE" "$GUARD" 2>&1); rc=$?
    assert_fails "$rc" && assert_contains "$out" "prym update" && pass
fi

if it "guard allows an upgrade while PrymX holds the lock"; then
    echo $$ > "$LOCKFILE"
    PRYMX_LOCK_FILE="$LOCKFILE" "$GUARD" >/dev/null 2>&1; rc=$?
    assert_ok "$rc" && pass
fi

if it "guard ignores a stale lock"; then
    echo 999999 > "$LOCKFILE"
    PRYMX_LOCK_FILE="$LOCKFILE" "$GUARD" >/dev/null 2>&1; rc=$?
    assert_fails "$rc" && pass
fi

if it "guard honours PRYMX_ALLOW_PACMAN=1"; then
    rm -f "$LOCKFILE"
    PRYMX_ALLOW_PACMAN=1 PRYMX_LOCK_FILE="$LOCKFILE" "$GUARD" >/dev/null 2>&1; rc=$?
    assert_ok "$rc" && pass
fi

if it "the hook triggers on upgrades and aborts on failure"; then
    hook=$(cat "$REPO/system/prymx-guard.hook")
    assert_contains "$hook" "Operation = Upgrade" \
        && assert_contains "$hook" "When = PreTransaction" \
        && assert_contains "$hook" "AbortOnFail" && pass
fi

# ---------------------------------------------------------------------------
# prym CLI
# ---------------------------------------------------------------------------

printf '\n%s prym%s\n' "$D" "$N"

if it "prym --help lists every documented subcommand"; then
    out=$(PRYMX_REPO="$REPO" "$REPO/bin/prym" --help 2>&1); rc=$?
    assert_ok "$rc" || true
    for sub in update snapshot rollback sync clean help; do
        assert_contains "$out" "$sub" || { break; }
    done
    [[ $out == *update* && $out == *rollback* && $out == *clean* ]] && pass
fi

if it "prym --version prints the version"; then
    out=$(PRYMX_REPO="$REPO" "$REPO/bin/prym" --version 2>&1)
    assert_contains "$out" "PrymX" && pass
fi

if it "prym rejects an unknown subcommand"; then
    out=$(PRYMX_REPO="$REPO" "$REPO/bin/prym" frobnicate 2>&1); rc=$?
    assert_eq "$rc" "2" && assert_contains "$out" "Unknown command" && pass
fi

if it "prym rejects an unknown option"; then
    out=$(PRYMX_REPO="$REPO" "$REPO/bin/prym" --frob 2>&1); rc=$?
    assert_eq "$rc" "2" && assert_contains "$out" "Unknown option" && pass
fi

if it "prym refuses to run as root"; then
    if [[ $EUID -eq 0 ]]; then
        out=$(PRYMX_REPO="$REPO" "$REPO/bin/prym" snapshot 2>&1); rc=$?
        assert_fails "$rc" && assert_contains "$out" "Do not run prym as root" && pass
    else
        grep -q 'require_non_root' "$REPO/bin/prym" && pass || fail "no root guard in prym"
    fi
fi

# ---------------------------------------------------------------------------
# Hardware detection (modules are sourced further down by load_modules; these
# two are pure functions, so source their modules early)
# ---------------------------------------------------------------------------

printf '\n%s hardware detection%s\n' "$D" "$N"

# shellcheck source=/dev/null
source "$REPO/modules/40-gpu.sh"
# shellcheck source=/dev/null
source "$REPO/modules/60-bluetooth.sh"

HWSTUB="$WORK/hwstub"
mkdir -p "$HWSTUB"

if it "GPU detection reads every vendor out of lspci"; then
    cat > "$HWSTUB/lspci" <<'EOF'
#!/bin/sh
cat <<'OUT'
00:02.0 VGA compatible controller [0300]: Intel Corporation UHD Graphics [8086:9bc4]
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation TU117M [10de:1f99]
02:00.0 Audio device [0403]: NVIDIA Corporation Device [10de:10fa]
OUT
EOF
    chmod +x "$HWSTUB/lspci"
    out=$(PATH="$HWSTUB:$PATH" _gpu_vendors | tr '\n' ' ')
    assert_eq "$out" "nvidia intel " && pass
fi

if it "GPU detection sees an AMD card and ignores non-display devices"; then
    cat > "$HWSTUB/lspci" <<'EOF'
#!/bin/sh
cat <<'OUT'
03:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Navi 32 [1002:747e]
04:00.0 Non-VGA unclassified device: NVIDIA Corporation Something
OUT
EOF
    chmod +x "$HWSTUB/lspci"
    out=$(PATH="$HWSTUB:$PATH" _gpu_vendors | tr '\n' ' ')
    assert_eq "$out" "amd " && pass
fi

if it "bluetooth detection finds a bound adapter in sysfs"; then
    mkdir -p "$WORK/sysfs-bt/hci0"
    BLUETOOTH_SYSFS_GLOB="$WORK/sysfs-bt/*" _has_bluetooth_radio
    assert_ok "$?" && pass
fi

if it "bluetooth detection finds an adapter on the USB bus"; then
    cat > "$HWSTUB/lsusb" <<'EOF'
#!/bin/sh
echo "Bus 001 Device 004: ID 8087:0026 Intel Corp. AX201 Bluetooth"
EOF
    chmod +x "$HWSTUB/lsusb"
    PATH="$HWSTUB:$PATH" BLUETOOTH_SYSFS_GLOB="$WORK/none/*" _has_bluetooth_radio
    assert_ok "$?" && pass
fi

if it "bluetooth detection reports nothing on a machine without a radio"; then
    cat > "$HWSTUB/lsusb" <<'EOF'
#!/bin/sh
echo "Bus 001 Device 002: ID 1d6b:0002 Linux Foundation 2.0 root hub"
EOF
    cat > "$HWSTUB/lspci" <<'EOF'
#!/bin/sh
echo "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics"
EOF
    chmod +x "$HWSTUB/lsusb" "$HWSTUB/lspci"
    PATH="$HWSTUB:$PATH" BLUETOOTH_SYSFS_GLOB="$WORK/none/*" _has_bluetooth_radio
    assert_fails "$?" && pass
fi

# ---------------------------------------------------------------------------
# The configs we ship - parsed with the real tools where they are installed
# ---------------------------------------------------------------------------

printf '\n%s shipped configs%s\n' "$D" "$N"

# shellcheck source=/dev/null
source "$REPO/modules/95-validate.sh"

if it "the niri config validates"; then
    if ! command -v niri >/dev/null; then
        skipped "niri is not installed"
    else
        out=$(niri validate --config "$REPO/dotfiles/niri/.config/niri/config.kdl" 2>&1); rc=$?
        assert_ok "$rc" && pass || printf '       %s\n' "$out"
    fi
fi

if it "the fish config parses"; then
    if ! command -v fish >/dev/null; then
        skipped "fish is not installed"
    else
        out=$(fish --no-execute "$REPO/dotfiles/fish/.config/fish/config.fish" 2>&1); rc=$?
        assert_ok "$rc" && pass || printf '       %s\n' "$out"
    fi
fi

if it "the tmux config parses"; then
    if ! command -v tmux >/dev/null; then
        skipped "tmux is not installed"
    else
        out=$(tmux -L prymx-selftest -f "$REPO/dotfiles/tmux/.config/tmux/tmux.conf" \
                start-server \; kill-server 2>&1); rc=$?
        assert_ok "$rc" && pass || printf '       %s\n' "$out"
    fi
fi

if it "the waybar and swaync JSON configs parse"; then
    if ! command -v python3 >/dev/null; then
        skipped "python3 is not installed"
    else
        _json_parses "$REPO/dotfiles/waybar/.config/waybar/config.jsonc" \
            && _json_parses "$REPO/dotfiles/swaync/.config/swaync/config.json" \
            && pass || fail "a shipped JSON config does not parse"
    fi
fi

if it "the JSON validator rejects malformed JSON"; then
    if ! command -v python3 >/dev/null; then
        skipped "python3 is not installed"
    else
        printf '{"a": 1,}\n' > "$WORK/bad.json"
        _json_parses "$WORK/bad.json" 2>/dev/null
        assert_fails "$?" && pass
    fi
fi

if it "every program with a keybinding or autostart ships a config"; then
    missing=""
    for prog in waybar fuzzel swaync hyprlock hypridle; do
        case $prog in
            hyprlock|hypridle) dir="$REPO/dotfiles/hypr/.config/hypr" ;;
            *)                 dir="$REPO/dotfiles/$prog/.config/$prog" ;;
        esac
        [[ -d $dir ]] || missing+="$prog "
    done
    assert_eq "$missing" "" && pass
fi

# ---------------------------------------------------------------------------
# Repository invariants
# ---------------------------------------------------------------------------

printf '\n%s repository%s\n' "$D" "$N"

# Modules only define functions when sourced; bootstrap.sh does that at run
# time via load_modules.
load_modules

if it "every shell script parses"; then
    bad=""
    while IFS= read -r f; do
        bash -n "$f" 2>/dev/null || bad+="$f "
    done < <(find "$REPO" -path "$REPO/.git" -prune -o -type f \( -name '*.sh' -o -name prym \) -print)
    assert_eq "$bad" "" && pass
fi

printf '\n%s AUR helper health%s\n' "$D" "$N"

# A fake /usr/lib holding whichever libalpm soname the test wants.
fake_libdir() {
    local dir="$WORK/lib-$1"
    mkdir -p "$dir"
    : > "$dir/libalpm.so.$1"
    : > "$dir/libalpm.so.$1.0.1"
    ln -sf "libalpm.so.$1" "$dir/libalpm.so"
    printf '%s\n' "$dir"
}

if it "system_alpm_soname reads the soname off the installed libalpm"; then
    out=$(PRYMX_LIBDIR=$(fake_libdir 16) system_alpm_soname)
    assert_eq "$out" "16" && pass
fi

if it "system_alpm_soname is empty when there is no libalpm"; then
    out=$(PRYMX_LIBDIR="$WORK/nothing-here" system_alpm_soname)
    assert_eq "$out" "" && pass
fi

if it "paru_usable accepts a paru built against the installed libalpm"; then
    paru_health_reset
    out=$(STUB_PARU_ALPM=16 PRYMX_LIBDIR=$(fake_libdir 16) paru_problem)
    assert_eq "$out" "" && pass
fi

if it "paru_problem names a libalpm soname mismatch"; then
    paru_health_reset
    out=$(STUB_PARU_ALPM=15 PRYMX_LIBDIR=$(fake_libdir 16) paru_problem)
    assert_contains "$out" "libalpm.so.15" \
        && assert_contains "$out" "libalpm.so.16" && pass
    paru_health_reset
fi

if it "paru_problem reports a paru that will not run at all"; then
    broken="$WORK/broken-bin"; mkdir -p "$broken"
    cat > "$broken/paru" <<'BROKEN'
#!/bin/sh
echo "paru: error while loading shared libraries: libalpm.so.15" >&2
exit 127
BROKEN
    chmod +x "$broken/paru"
    paru_health_reset
    out=$(PATH="$broken:$PATH" paru_problem)
    assert_contains "$out" "libalpm.so.15" && pass
    paru_health_reset
fi

if it "paru_problem is empty for a healthy paru and cached"; then
    paru_health_reset
    paru_usable && assert_eq "$(paru_problem)" "" && pass
fi

if it "install_package_lists refuses to run against a broken paru"; then
    pkgdir="$WORK/pkg-broken"; mkdir -p "$pkgdir"
    printf 'a\nb\n' > "$pkgdir/core.txt"
    PRYMX_FAILURES=()
    paru_health_reset
    out=$(STUB_PARU_ALPM=15 PRYMX_LIBDIR=$(fake_libdir 16) \
          install_package_lists "$pkgdir" 2>&1); rc=$?
    paru_health_reset
    assert_fails "$rc" \
        && assert_contains "$out" "libalpm" \
        && assert_contains "$out" "--only aur" \
        && assert_not_contains "$out" "[stub] paru" && pass
fi

if it "aur_install falls back to pacman when paru is broken"; then
    paru_health_reset
    out=$(STUB_PARU_ALPM=15 PRYMX_LIBDIR=$(fake_libdir 16) \
          PACMAN_INSTALLED="" aur_install ripgrep 2>&1)
    paru_health_reset
    assert_contains "$out" "[stub] pacman" \
        && assert_not_contains "$out" "[stub] paru" && pass
fi

if it "install_aur_helper rebuilds instead of skipping a broken paru"; then
    PRYMX_FAILURES=()
    paru_health_reset
    out=$(STUB_PARU_ALPM=15 PRYMX_LIBDIR=$(fake_libdir 16) \
          install_aur_helper 2>&1); rc=$?
    paru_health_reset
    # The build itself cannot succeed under the stubs; what matters is that the
    # step noticed the mismatch and tried, rather than reporting paru as fine.
    assert_contains "$out" "unusable" \
        && assert_not_contains "$out" "already installed" && pass
fi

if it "install_aur_helper skips a healthy paru"; then
    paru_health_reset
    out=$(install_aur_helper 2>&1); rc=$?
    paru_health_reset
    assert_ok "$rc" && assert_contains "$out" "already installed" && pass
fi

if it "the aur module tries the source package after the binary one"; then
    assert_eq "${AUR_HELPER_PKGS[*]}" "paru-bin paru" && pass
fi

if it "package lists contain bare package names only"; then
    bad=""
    while IFS= read -r f; do
        grep -nE '(^[[:space:]]|[[:space:]]$|^#|^-|[[:space:]])' "$f" >/dev/null 2>&1 && bad+="$f "
    done < <(find "$REPO/packages" -name '*.txt' -size +0)
    assert_eq "$bad" "" && pass
fi

if it "every module defines the function bootstrap.sh calls"; then
    missing=""
    for fn in install_aur_helper setup_snapper snapshot_pre_bootstrap \
              setup_github_interactive apply_sysctl_tweaks setup_gpu_drivers \
              setup_greeter setup_bluetooth setup_maintenance \
              setup_plugin_managers install_prym_cli setup_prymx_identity; do
        declare -F "$fn" >/dev/null 2>&1 || missing+="$fn "
    done
    assert_eq "$missing" "" && pass
fi

if it "every step in bootstrap.sh maps to a defined function"; then
    missing=""
    for fn in "${STEP_FUNCS[@]}"; do
        declare -F "$fn" >/dev/null 2>&1 || missing+="$fn "
    done
    assert_eq "$missing" "" \
        && assert_eq "${#STEP_NAMES[@]}" "${#STEP_FUNCS[@]}" \
        && assert_eq "${#STEP_NAMES[@]}" "${#STEP_DESCS[@]}" && pass
fi

# ---------------------------------------------------------------------------

printf '\n%s%d passed%s, %s%d failed%s, %d skipped\n' "$G" "$PASS" "$N" \
    "$( ((FAIL)) && printf '%s' "$R" )" "$FAIL" "$N" "$SKIPPED"
if (( FAIL )); then
    printf 'Failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
fi
exit 0
