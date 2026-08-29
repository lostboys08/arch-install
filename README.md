<h1 align="center">PrymX</h1>

<p align="center">
  An unbloated, high-performance workstation layer for vanilla Arch Linux.<br>
  Btrfs snapshots, Wayland/niri, and one command that keeps it all in step.
</p>

---

## The name

**PrymX** comes from the Latin *primus* — *the first*. A primary foundation, a
baseline primitive: the layer everything else is built on top of, and nothing
more than that.

That is the whole ethos:

- **Vanilla Arch underneath.** PrymX is not a distribution and not a fork. It
  is a repository of scripts that configures a stock Arch install. Everything
  it does, you could do by hand from the wiki — it just does it the same way
  every time, on every machine.
- **Unbloated.** Nothing is installed to be impressive. Package lists are
  short, plain-text, and yours to edit. The neovim config ships six plugins,
  not sixty.
- **High performance.** Wayland with niri, PipeWire, drivers matched to the
  hardware, gaming sysctl tunables, and an OOM killer so a runaway build never
  takes the desktop down with it.
- **Reversible.** Every upgrade is preceded by a Btrfs snapshot. That is
  enforced by a pacman hook, not by discipline.
- **Idempotent.** Every step checks before it acts. Run `./bootstrap.sh` on a
  fresh install or on a machine that is already configured — the result is the
  same, and the second run is nearly silent.

## Install

Run as your normal user (not root); the user needs sudo rights.

```sh
git clone https://github.com/lostboys08/arch-install.git ~/prymx
cd ~/prymx
./bootstrap.sh
```

Then reboot: the hostname, login shell, `docker` group membership and the ly
greeter all take effect at the next login.

Useful variations:

```sh
./bootstrap.sh --list                    # the steps, in order
./bootstrap.sh --dry-run                 # print the plan, touch nothing
./bootstrap.sh --only gpu,dotfiles       # just those two
./bootstrap.sh --skip github,plugins     # everything else
./bootstrap.sh --profile laptop          # laptop package list + power management
./bootstrap.sh --hostname prymx-air      # default is 'prymx'
```

Each run writes a full log to `~/.local/state/prymx/bootstrap-<timestamp>.log`
(`--no-log` turns that off).

## `prym`

`bootstrap.sh` installs `/usr/local/bin/prym` as a symlink into this
repository, so `git pull` updates the CLI too.

| Command | What it does |
| --- | --- |
| `prym update` | Snapshots `/` (`prym-pre-update-<timestamp>`), runs a full `paru -Syu`, refreshes the GRUB snapshot entries, and reports any `.pacnew` files left behind. |
| `prym snapshot [desc]` | An immediate manual snapshot of the root subvolume. |
| `prym rollback [id]` | With no id, lists the snapshots and explains the options. With an id, confirms and hands the rollback to snapper. |
| `prym sync` | Re-applies the repository: installs anything missing from `packages/*.txt` and re-links the dotfiles with GNU Stow. |
| `prym clean` | Orphaned packages, package cache trimmed to two versions, paru build cache, snapper cleanup algorithms, journals older than two weeks. |
| `prym status` | Profile, hostname, root filesystem, guard state, snapshot count, and any packages the lists say should be installed but are not. |
| `prym help` | The same table, from the terminal. |

`-y` / `--yes` skips the confirmations.

### Upgrades are guarded

A `PreTransaction` pacman hook (`/etc/pacman.d/hooks/00-prymx-guard.hook`)
aborts any transaction that would **upgrade** installed packages unless PrymX
started it:

```
$ sudo pacman -Syu
  PrymX: upgrades are managed by `prym`
      prym update            full system upgrade, snapshot taken first
```

That way no upgrade ever happens without a snapshot to fall back to.
Installing and removing packages is unaffected. To bypass it once:

```sh
sudo PRYMX_ALLOW_PACMAN=1 pacman -Syu
```

The hook allows a transaction while `/run/prymx/pacman.lock` names a live
process — `prym update`, `prym sync` and `bootstrap.sh` all take that lock for
the duration of their run. The lock lives on tmpfs, so a crashed run cannot
leave the guard disabled.

## Layout

```
.
├── bootstrap.sh              # entrypoint: step runner, flags, logging
├── bin/prym                  # the CLI, symlinked to /usr/local/bin/prym
├── lib/common.sh             # shared helpers (logging, idempotent writes, stow, snapper)
├── packages/                 # plain package lists, one name per line
│   ├── core.txt              # shell, editor, CLI tooling
│   ├── dev.txt               # git tooling, docker, go
│   ├── gui-niri.txt          # niri compositor, ghostty, and the desktop bits
│   ├── audio.txt             # pipewire stack
│   ├── fonts.txt             # noto + a nerd font, so nothing renders as tofu
│   ├── gaming.txt            # steam, wine, gamemode, mangohud (needs multilib)
│   └── profiles/             # extra lists per --profile
│       ├── desktop.txt
│       └── laptop.txt        # brightnessctl, acpi, powertop, upower
├── modules/                  # sourced bash modules, one subsystem each
│   ├── 00-aur.sh             # install_aur_helper()       - paru
│   ├── 10-snapper.sh         # setup_snapper()            - btrfs snapshots
│   ├── 20-github.sh          # setup_github_interactive() - gh, git identity, ssh key
│   ├── 30-sysctl.sh          # apply_sysctl_tweaks()      - 99-gaming.conf
│   ├── 40-gpu.sh             # setup_gpu_drivers()        - drivers + vulkan
│   ├── 50-greeter.sh         # setup_greeter()            - ly
│   ├── 60-bluetooth.sh       # setup_bluetooth()          - bluez, where there is a radio
│   ├── 70-maintenance.sh     # setup_maintenance()        - cache, TRIM, mirrors, OOM, firewall
│   ├── 80-plugins.sh         # setup_plugin_managers()    - TPM, fisher, lazy.nvim
│   └── 90-prym.sh            # install_prym_cli(), setup_prymx_identity()
├── system/                   # files installed onto the system
│   ├── pacman-guard.sh       # -> /usr/local/lib/prymx/pacman-guard
│   └── prymx-guard.hook      # -> /etc/pacman.d/hooks/00-prymx-guard.hook
├── dotfiles/                 # one GNU Stow package per directory
│   ├── fish/  ghostty/  niri/  tmux/  nvim/
├── tests/run-tests.sh        # the test suite (no Arch or root required)
└── .github/workflows/ci.yml  # shellcheck + tests + an Arch smoke test
```

## The steps

| Step | What it does |
| --- | --- |
| `multilib` | Enables `[multilib]` in `/etc/pacman.conf` (backing up the original), leaving `[multilib-testing]` commented. |
| `identity` | Writes `/etc/prymx/prymx.conf` and sets the hostname (default `prymx`) plus the matching `/etc/hosts` entry. |
| `prym` | Symlinks the CLI and installs the upgrade guard. |
| `update` | `pacman -Syu`. |
| `snapper` | On a Btrfs root: snapper, snap-pac, grub-btrfs, the `root` config, the timers, and grub-btrfsd when GRUB is the bootloader. |
| `snapshot` | A `prymx-pre-bootstrap` snapshot before the bulk of the changes. |
| `aur` | Builds `paru` from `paru-bin` if no AUR helper is present. |
| `packages` | Every `packages/*.txt`, then the profile list. |
| `gpu` | Reads `lspci` and installs the matching driver and Vulkan stack. NVIDIA also gets `nvidia_drm.modeset=1` and the initramfs modules. |
| `greeter` | ly, configured and enabled; it lists the niri session on its own. |
| `bluetooth` | Only where an adapter exists (`PRYMX_FORCE_BLUETOOTH=1` overrides). |
| `sysctl` | `vm.max_map_count` and `vm.swappiness` for games. |
| `maintenance` | paccache, fstrim, earlyoom, reflector, ufw, and tlp on the laptop profile. |
| `services` | `docker.service`, the `docker` group, the PipeWire user units. |
| `dotfiles` | GNU Stow, `--restow --no-folding`. |
| `plugins` | TPM, fisher and lazy.nvim, so the configs are a starting point rather than a fixture. |
| `shell` | fish becomes the login shell. |
| `github` | Interactive: `gh auth login`, git identity, an ed25519 key uploaded with `gh ssh-key add`. Last, so the unattended work finishes first. |

Failures in individual steps are collected and printed in a summary; only
genuinely fatal problems (not Arch, no sudo, a failed `pacman -Syu`) stop the
run.

### Hardware and existing setup

The GPU, bluetooth and firewall steps all detect what is already there:

- Drivers you installed during `archinstall` are left alone — everything goes
  through `pacman --needed`, and the NVIDIA initramfs edit is skipped when the
  modules are already listed.
- No bluetooth adapter means the bluetooth step no-ops, so the same repository
  configures the desktop and the laptop.
- An already-active `ufw` is not reconfigured; an inactive one gets a
  deny-incoming/allow-outgoing policy, plus a rate-limited SSH rule if `sshd`
  is enabled.

## Dotfiles

Each directory under `dotfiles/` is a Stow package whose contents mirror
`$HOME`, so `dotfiles/fish/.config/fish/config.fish` becomes
`~/.config/fish/config.fish`. Linking uses `--restow --no-folding`, which links
individual files rather than whole directories — plugin managers writing into
`~/.config/nvim` cannot leak files back into the repository.

Every config has a machine-local escape hatch that is git-ignored:

| Config | Local override |
| --- | --- |
| fish | `~/.config/fish/local.fish` |
| tmux | `~/.config/tmux/local.conf` |
| ghostty | `~/.config/ghostty/local` |
| neovim | `~/.config/nvim/lua/local.lua` |

`fish_plugins`, on the other hand, is deliberately *inside* the repository: run
`fisher install <plugin>` and the change shows up as a diff to commit.

If Stow reports a conflict, an unmanaged file is in the way. Move it aside, or
adopt it:

```sh
stow --dir dotfiles --target "$HOME" --adopt nvim
git diff        # review what --adopt pulled in
```

### ghostty and terminfo

ghostty sets `TERM=xterm-ghostty`, and that terminfo entry only exists where
ghostty is installed. When SSHing into a host that lacks it, copy the entry
once with `infocmp -x | ssh host -- tic -x -`, or prefix the command with
`TERM=xterm-256color`.

## Snapshots and rollback

With a Btrfs root, `snap-pac` snapshots around every pacman transaction,
`prym update` adds one before each upgrade, and `snapper-timeline.timer` keeps
a rolling window (5 hourly, 7 daily by default).

```sh
prym rollback              # list snapshots and the options
prym rollback 42           # make #42 the default subvolume, then reboot
```

If the system will not boot, pick a snapshot from the GRUB *Arch Linux
snapshots* submenu that grub-btrfsd maintains, then run `sudo snapper rollback`
from inside it.

## Tests

```sh
./tests/run-tests.sh              # everything
./tests/run-tests.sh stow         # just the tests matching 'stow'
```

The suite needs neither Arch nor root: sudo, pacman, paru, systemctl and
`findmnt` are stubbed on `PATH`, and nothing outside a scratch directory is
touched. It covers argument handling, the multilib edit, package-list ordering
and failure handling, idempotent file writes, stow linking/idempotency/conflicts,
all four states of the upgrade guard, and the `prym` CLI surface. CI runs the
same suite plus `shellcheck` and a smoke test on an `archlinux` image.
