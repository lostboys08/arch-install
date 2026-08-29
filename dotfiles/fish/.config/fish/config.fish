# ~/.config/fish/config.fish

if status is-interactive
    set -g fish_greeting

    # Editor
    set -gx EDITOR nvim
    set -gx VISUAL nvim

    # ~/.local/bin and the Go toolchain
    fish_add_path -g $HOME/.local/bin
    fish_add_path -g $HOME/go/bin

    # Modern replacements for the classics
    if type -q eza
        alias ls 'eza --group-directories-first'
        alias ll 'eza -l --git --group-directories-first'
        alias la 'eza -la --git --group-directories-first'
        alias lt 'eza --tree --level=2'
    end

    if type -q bat
        alias cat 'bat --paging=never'
    end

    type -q nvim; and alias vim nvim
    type -q lazygit; and alias lg lazygit
    type -q btop; and alias top btop

    alias g git
    alias gs 'git status --short --branch'
    alias ga 'git add'
    alias gc 'git commit'
    alias gp 'git push'
    alias gl 'git log --oneline --graph --decorate -20'

    alias pac 'sudo pacman'
    alias update 'paru -Syu'

    # fzf shell integration (fzf >= 0.48 ships `fzf --fish`)
    if type -q fzf
        fzf --fish | source
    end
end
