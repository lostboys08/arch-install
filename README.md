# arch-install

Modular post-install bootstrap for a vanilla Arch Linux desktop: niri (Wayland),
PipeWire audio, a small development toolchain, Btrfs snapshots, and gaming
tweaks — plus dotfiles linked into `$HOME` with GNU Stow.

## Usage

Run as your **normal user** (not root); the user must have sudo rights.

```sh
git clone https://github.com/lostboys08/arch-install.git ~/arch-install
cd ~/arch-install
./bootstrap.sh
```

The script is idempotent: re-running it upgrades the system, installs anything
missing, and re-links the dotfiles.

## Layout

```
.
├── bootstrap.sh              # master entrypoint
├── packages/                 # plain package lists, one name per line
│   ├── core.txt              # shell, editor, CLI tooling
│   ├── dev.txt               # git tooling, docker, go
│   ├── gui-niri.txt          # niri compositor and its desktop bits
│   ├── audio.txt             # pipewire stack
│   └── gaming.txt            # steam, wine, gamemode, mangohud (needs multilib)
├── modules/                  # sourced bash modules, one subsystem each
│   ├── 00-aur.sh             # install_aur_helper()        - paru
│   ├── 10-snapper.sh         # setup_snapper()             - btrfs snapshots
│   ├── 20-github.sh          # setup_github_interactive()  - gh, git identity, ssh key
│   └── 30-sysctl.sh          # apply_sysctl_tweaks()       - /etc/sysctl.d/99-gaming.conf
└── dotfiles/                 # one GNU Stow package per directory
    ├── fish/
    ├── niri/
    ├── tmux/
    └── nvim/
```

## What bootstrap.sh does

1. Refuses to run as root and primes the sudo timestamp.
2. Enables `[multilib]` in `/etc/pacman.conf` (backing up the original) and runs
   a full `pacman -Syu`.
3. Builds and installs `paru` from `paru-bin` if no AUR helper is present.
4. Installs every `packages/*.txt` list with
   `paru -S --needed --noconfirm - < list.txt`, in the order
   core → dev → gui-niri → audio → gaming.
5. Configures Snapper when `/` is Btrfs, applies the sysctl tweaks, and runs the
   interactive GitHub setup.
6. Enables `docker.service` and adds you to the `docker` group.
7. Stows every directory under `dotfiles/` into `$HOME`.
8. Changes your login shell to fish.

Failures in individual steps are collected and reported in a summary at the end
instead of aborting the whole run; only genuinely fatal problems (not Arch, no
sudo, failed system upgrade) stop the script.

## Modules

Modules are **sourced**, not executed — each one defines a single entrypoint
function that `bootstrap.sh` calls. They fall back to their own logging helpers,
so a module can also be sourced by hand:

```sh
source modules/30-sysctl.sh && apply_sysctl_tweaks
```

### `10-snapper.sh`

Only acts when `findmnt -no FSTYPE /` reports `btrfs`. It installs `snapper`,
`snap-pac`, `grub-btrfs` and `inotify-tools`, creates the `root` config for `/`,
repairs the `/.snapshots` mount that `create-config` replaces when `/etc/fstab`
carries a `@snapshots` subvolume, tunes the timeline limits, and enables
`snapper-timeline.timer`, `snapper-cleanup.timer` and `grub-btrfsd` (the latter
only if GRUB is installed).

### `20-github.sh`

Interactive, and skipped when there is no TTY. Runs `gh auth login` if needed,
then `gh auth setup-git`, prompts for `user.name`/`user.email` when unset,
generates `~/.ssh/id_ed25519` if missing, and uploads the public key with
`gh ssh-key add` unless GitHub already has it. If the upload fails for want of a
scope: `gh auth refresh -h github.com -s admin:public_key`.

## Dotfiles

Each directory in `dotfiles/` is a Stow package whose contents mirror `$HOME`
(so `dotfiles/fish/.config/fish/config.fish` → `~/.config/fish/config.fish`).
They are linked with `stow --restow --no-folding`, which links individual files
rather than whole directories — new files dropped into `~/.config/nvim` by a
plugin manager will not end up inside this repository.

If Stow reports a conflict, an unmanaged file already exists at that path. Move
it aside, or take it over with:

```sh
stow --dir dotfiles --target "$HOME" --adopt nvim
git diff        # review what --adopt pulled into the repo
```

## After the first run

Reboot (or log out and back in) so the new `docker` group membership, login
shell and session services take effect, then start niri from a TTY with
`niri --session`.
