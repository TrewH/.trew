#!/bin/sh -e

# Define color codes using tput for better compatibility
RC=$(tput sgr0)
RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)

PACKAGER=""
SUDO_CMD=""
SUGROUP=""
GITPATH=""

# Helper functions
print_colored() {
    printf "${1}%s${RC}\n" "$2"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

setup_paths() {
  GITPATH=$(dirname "$(realpath "$0")")
  TREW_HOME="$HOME/.trew"
  mkdir -p "$TREW_HOME" "$TREW_HOME/cache" "$TREW_HOME/bin"
}

check_environment() {
    # Check for required commands
    REQUIREMENTS='curl groups sudo'
    for req in $REQUIREMENTS; do
        if ! command_exists "$req"; then
            print_colored "$RED" "To run me, you need: $REQUIREMENTS"
            exit 1
        fi
    done

    # Determine package manager
    PACKAGEMANAGER='nala apt dnf yum pacman zypper emerge xbps-install nix-env'
    for pgm in $PACKAGEMANAGER; do
        if command_exists "$pgm"; then
            PACKAGER="$pgm"
            printf "Using %s\n" "$pgm"
            break
        fi
    done

    if [ -z "$PACKAGER" ]; then
        print_colored "$RED" "Can't find a supported package manager"
        exit 1
    fi

    # Determine sudo command
    if command_exists sudo; then
        SUDO_CMD="sudo"
    elif command_exists doas && [ -f "/etc/doas.conf" ]; then
        SUDO_CMD="doas"
    else
        SUDO_CMD="su -c"
    fi
    printf "Using %s as privilege escalation software\n" "$SUDO_CMD"

    # Check write permissions
    GITPATH=$(dirname "$(realpath "$0")")
    if [ ! -w "$GITPATH" ]; then
        print_colored "$RED" "Can't write to $GITPATH"
        exit 1
    fi

    # Check superuser group
    SUPERUSERGROUP='wheel sudo root'
    for sug in $SUPERUSERGROUP; do
        if groups | grep -q "$sug"; then
            SUGROUP="$sug"
            printf "Super user group %s\n" "$SUGROUP"
            break
        fi
    done

    if ! groups | grep -q "$SUGROUP"; then
        print_colored "$RED" "You need to be a member of the sudo group to run me!"
        exit 1
    fi
}

ensure_fastfetch() {
  command -v fastfetch >/dev/null 2>&1 && return 0
  echo "Installing fastfetch…"

  # deps (Debian/Ubuntu)
  if command -v apt >/dev/null 2>&1; then
    ${SUDO_CMD:-sudo} apt update -y
    ${SUDO_CMD:-sudo} apt install -y git cmake gcc g++ pkg-config \
      libdrm-dev libwayland-dev libx11-dev libxcb1-dev \
      libxcb-randr0-dev libxcb-xinerama0-dev libpci-dev \
      libgl1-mesa-dev
  fi

  cache="$HOME/.trew/cache/fastfetch"
  if [ -d "$cache/.git" ]; then
    git -C "$cache" fetch --depth=1 origin
    git -C "$cache" reset --hard origin/master 2>/dev/null || git -C "$cache" reset --hard origin/main
  else
    git clone --depth=1 https://github.com/fastfetch-cli/fastfetch.git "$cache"
  fi

  PREFIX="${TREW_PREFIX:-/usr/local}"    # set TREW_PREFIX=$HOME/.local for user install
  build="$cache/build"
  cmake -S "$cache" -B "$build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$build" -j"$(nproc)"

  if [ "$PREFIX" = "/usr/local" ] || [ -w "$(dirname "$PREFIX")" ] && [ ! -w "$PREFIX" ]; then
    ${SUDO_CMD:-sudo} cmake --install "$build"
  else
    cmake --install "$build"
  fi

  # ensure PATH for user installs
  case ":$PATH:" in *:"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
  command -v fastfetch >/dev/null 2>&1 || { echo "fastfetch install failed"; return 1; }
  echo "✓ fastfetch installed to $PREFIX/bin"
}

link_fastfetch_config() {
  USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6); [ -n "$USER_HOME" ] || USER_HOME="$HOME"
  HOST="$(hostname -s 2>/dev/null || hostname)"
  SRC="$GITPATH/config/fastfetch/config.jsonc"
  [ -f "$GITPATH/config/fastfetch/hosts/$HOST.jsonc" ] && SRC="$GITPATH/config/fastfetch/hosts/$HOST.jsonc"
  DEST="$USER_HOME/.config/fastfetch/config.jsonc"
  link_file "$SRC" "$DEST"
}


install_dependencies() {
    DEPENDENCIES='bash bash-completion tar bat tmux tree multitail wget unzip fontconfig trash-cli'
    if ! command_exists nvim; then
        DEPENDENCIES="${DEPENDENCIES} neovim"
    fi

    print_colored "$YELLOW" "Installing dependencies..."
    case "$PACKAGER" in
        pacman)
            install_pacman_dependencies
            ;;
        nala)
            ${SUDO_CMD} ${PACKAGER} install -y ${DEPENDENCIES}
            ;;
        emerge)
            ${SUDO_CMD} ${PACKAGER} -v app-shells/bash app-shells/bash-completion app-arch/tar app-editors/neovim sys-apps/bat app-text/tree app-text/multitail app-misc/fastfetch app-misc/trash-cli
            ;;
        xbps-install)
            ${SUDO_CMD} ${PACKAGER} -v ${DEPENDENCIES}
            ;;
        nix-env)
            ${SUDO_CMD} ${PACKAGER} -iA nixos.bash nixos.bash-completion nixos.gnutar nixos.neovim nixos.bat nixos.tree nixos.multitail nixos.fastfetch nixos.pkgs.starship nixos.trash-cli
            ;;
        dnf)
            ${SUDO_CMD} ${PACKAGER} install -y ${DEPENDENCIES}
            ;;
        zypper)
            ${SUDO_CMD} ${PACKAGER} install -n ${DEPENDENCIES}
            ;;
        *)
            ${SUDO_CMD} ${PACKAGER} install -yq ${DEPENDENCIES}
            ;;
    esac

    install_font
}

install_starship_config_link() {
  USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6); [ -n "$USER_HOME" ] || USER_HOME="$HOME"
  SRC="$GITPATH/config/starship.toml"               # keep starship.toml in repo
  DEST="${XDG_CONFIG_HOME:-$USER_HOME/.config}/starship.toml"
  link_file "$SRC" "$DEST"
}


install_pacman_dependencies() {
    if ! command_exists yay && ! command_exists paru; then
        printf "Installing yay as AUR helper...\n"
        ${SUDO_CMD} ${PACKAGER} --noconfirm -S base-devel
        cd /opt && ${SUDO_CMD} git clone https://aur.archlinux.org/yay-git.git && ${SUDO_CMD} chown -R "${USER}:${USER}" ./yay-git
        cd yay-git && makepkg --noconfirm -si
    else
        printf "AUR helper already installed\n"
    fi
    if command_exists yay; then
        AUR_HELPER="yay"
    elif command_exists paru; then
        AUR_HELPER="paru"
    else
        printf "No AUR helper found. Please install yay or paru.\n"
        exit 1
    fi
    ${AUR_HELPER} --noconfirm -S ${DEPENDENCIES}
}

install_font() {
    FONT_NAME="MesloLGS Nerd Font Mono"
    if fc-list :family | grep -iq "$FONT_NAME"; then
        printf "Font '%s' is installed.\n" "$FONT_NAME"
    else
        printf "Installing font '%s'\n" "$FONT_NAME"
        FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download/Meslo.zip"
        FONT_DIR="$HOME/.local/share/fonts"
        if wget -q --spider "$FONT_URL"; then
            TEMP_DIR=$(mktemp -d)
            wget -q $FONT_URL -O "$TEMP_DIR"/"${FONT_NAME}".zip
            unzip "$TEMP_DIR"/"${FONT_NAME}".zip -d "$TEMP_DIR"
            mkdir -p "$FONT_DIR"/"$FONT_NAME"
            mv "${TEMP_DIR}"/*.ttf "$FONT_DIR"/"$FONT_NAME"
            # Update the font cache
            fc-cache -fv
            rm -rf "${TEMP_DIR}"
            printf "'%s' installed successfully.\n" "$FONT_NAME"
        else
            printf "Font '%s' not installed. Font URL is not accessible.\n" "$FONT_NAME"
        fi
    fi

    if grep -qi microsoft /proc/version 2>/dev/null && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        print_colored "$YELLOW" "WSL detected. Install a Nerd Font on WINDOWS and select it in Windows Terminal > Profile > Appearance."
    fi
}

install_starship_and_fzf() {
    if ! command_exists starship; then
        if ! curl -sS https://starship.rs/install.sh | sh; then
            print_colored "$RED" "Something went wrong during starship install!"
            exit 1
        fi
    else
        printf "Starship already installed\n"
    fi

    if ! command_exists fzf; then
        if [ -d "$HOME/.fzf" ]; then
            print_colored "$YELLOW" "FZF directory already exists. Skipping installation."
        else
            git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
            ~/.fzf/install
        fi
    else
        printf "Fzf already installed\n"
    fi
}

install_zoxide() {
    if ! command_exists zoxide; then
        if ! curl -sS https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh; then
            print_colored "$RED" "Something went wrong during zoxide install!"
            exit 1
        fi
    else
        printf "Zoxide already installed\n"
    fi
}

# --- seed a default rc/ if you haven't added one to the repo yet ---
seed_rc_if_missing() {
    # Put these files in your repo at: $GITPATH/rc/*
    [ -d "$GITPATH/rc" ] || mkdir -p "$GITPATH/rc"

    [ -f "$GITPATH/rc/aliases.sh" ] || cat > "$GITPATH/rc/aliases.sh" <<'EOF'
# ~/.trew/rc/aliases.sh
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias gs='git status -sb'
alias gl='git log --oneline --graph --decorate -n 30'
alias v='code .'
# ROS/robot helpers (edit to taste)
alias roscorelog='journalctl -u roscore -f 2>/dev/null || echo "roscore log unavailable"'
EOF

    [ -f "$GITPATH/rc/exports.sh" ] || cat > "$GITPATH/rc/exports.sh" <<'EOF'
# ~/.trew/rc/exports.sh
export PATH="$HOME/.local/bin:$PATH"
export EDITOR="${EDITOR:-code --wait}"
EOF

    [ -f "$GITPATH/rc/functions.sh" ] || cat > "$GITPATH/rc/functions.sh" <<'EOF'
# ~/.trew/rc/functions.sh
mkcd() { mkdir -p -- "$1" && cd -- "$1" || return; }
EOF
}

# --- link repo rc/ into a stable location under HOME ---
link_rc_dir() {
    TREW_HOME="${TREW_HOME:-$HOME/.trew}"
    mkdir -p "$TREW_HOME"
    ln -sfn "$GITPATH/rc" "$TREW_HOME/rc"
    print_colored "$GREEN" "rc linked: $TREW_HOME/rc"
}

install_shell_rc() {
    USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    mkdir -p "$USER_HOME/.config"

    BRC="$USER_HOME/.bashrc"
    MARK_BEGIN="# >>> .trew init >>>"
    MARK_END="# <<< .trew init <<<"

    touch "$BRC"
    if ! grep -qF "$MARK_BEGIN" "$BRC"; then
        {
            echo "$MARK_BEGIN"
            echo '[ -f "$HOME/.trew/rc/aliases.sh" ]  && . "$HOME/.trew/rc/aliases.sh"'
            echo '[ -f "$HOME/.trew/rc/exports.sh" ]  && . "$HOME/.trew/rc/exports.sh"'
            echo '[ -f "$HOME/.trew/rc/functions.sh" ] && . "$HOME/.trew/rc/functions.sh"'

            # Starship for Bash
            echo 'command -v starship >/dev/null 2>&1 && eval "$(starship init bash)"'

            # Auto-start tmux: create a fresh window each time
            case $- in *i*) :;; *) return;; esac
            [ -n "$TMUX" ] && return
            [ -n "$NO_TMUX" ] && return
            [ -n "$VSCODE_PID" ] && return
            command -v tmux >/dev/null 2>&1 || return

            if tmux has-session -t default 2>/dev/null; then
            # Attach, create a new window in PWD, then switch to it
            tmux attach -t default \; new-window -c "$PWD" \; last-window
            else
            tmux new -s default -c "$PWD"
            fi

            echo "$MARK_END"
        } >> "$BRC"
        print_colored "$GREEN" "Injected .trew init block into ~/.bashrc"
    else
        print_colored "$YELLOW" "~/.bashrc already includes .trew block"
    fi

    # Ensure login shells read .bashrc
    BPROF="$USER_HOME/.bash_profile"
    [ -f "$BPROF" ] || { echo '[ -f ~/.bashrc ] && . ~/.bashrc' > "$BPROF"; print_colored "$GREEN" "Created ~/.bash_profile to source ~/.bashrc"; }

    # zsh (optional)
    if command -v zsh >/dev/null 2>&1; then
        ZRC="$USER_HOME/.zshrc"
        ZMARK_BEGIN="# >>> .trew zsh >>>"; ZMARK_END="# <<< .trew zsh <<<"
        touch "$ZRC"
        if ! grep -qF "$ZMARK_BEGIN" "$ZRC"; then
        {
            echo "$ZMARK_BEGIN"
            echo '[ -f "$HOME/.trew/rc/aliases.sh" ]  && . "$HOME/.trew/rc/aliases.sh"'
            echo '[ -f "$HOME/.trew/rc/exports.sh" ]  && . "$HOME/.trew/rc/exports.sh"'
            echo '[ -f "$HOME/.trew/rc/functions.sh" ] && . "$HOME/.trew/rc/functions.sh"'
            echo 'command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"'
            echo "$ZMARK_END"
        } >> "$ZRC"
        echo "✓ injected .trew block into ~/.zshrc"
        fi
    fi
}

install_tmux_config_copy() {
    USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6); [ -n "$USER_HOME" ] || USER_HOME="$HOME"
    SRC="$GITPATH/config/tmux/tmux.conf"
    DEST="$USER_HOME/.tmux.conf"

    if [ ! -f "$SRC" ]; then
        print_colored "$YELLOW" "tmux config not found at $SRC; skipping"
        return 0
    fi

    if [ -e "$DEST" ] && [ ! -L "$DEST" ] && ! cmp -s "$SRC" "$DEST"; then
        cp -a "$DEST" "${DEST}.bak.$(date +%Y%m%d%H%M%S)"
        print_colored "$YELLOW" "Backed up existing ~/.tmux.conf"
    fi

    install -m 0644 "$SRC" "$DEST" || {
        print_colored "$RED" "Failed to install ~/.tmux.conf"
        return 1
    }
    print_colored "$GREEN" "Installed ~/.tmux.conf"
}

install_tmux_config_link() {
  USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6); [ -n "$USER_HOME" ] || USER_HOME="$HOME"
  SRC="$GITPATH/config/tmux/tmux.conf"
  DEST="$USER_HOME/.tmux.conf"
  [ -f "$SRC" ] && link_file "$SRC" "$DEST" || print_colored "$YELLOW" "tmux.conf not found; skipping"
}

install_inputrc_link() {
  USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6); [ -n "$USER_HOME" ] || USER_HOME="$HOME"
  SRC="$GITPATH/config/inputrc"
  DEST="$USER_HOME/.inputrc"
  [ -f "$SRC" ] && link_file "$SRC" "$DEST" || print_colored "$YELLOW" "inputrc not found; skipping"
}

# Idempotent symlink helper: backs up a real file, then links
link_file() {
  SRC="$1"; DEST="$2"
  [ -f "$SRC" ] || { print_colored "$RED" "Missing source: $SRC"; return 1; }
  mkdir -p "$(dirname "$DEST")"
  if [ -e "$DEST" ] && [ ! -L "$DEST" ]; then
    cp -a "$DEST" "${DEST}.bak.$(date +%Y%m%d%H%M%S)"
    print_colored "$YELLOW" "Backed up $DEST -> ${DEST}.bak.*"
  fi
  ln -sfn "$SRC" "$DEST" || { print_colored "$RED" "Failed link: $SRC -> $DEST"; return 1; }
  print_colored "$GREEN" "Linked: $DEST -> $SRC"
}

setup_directories
check_environment

# === Symlink all configs from repo so changes reflect instantly ===
install_starship_config_link
link_fastfetch_config
install_tmux_config_link          # optional
install_inputrc_link              # optional

# === Binaries / tools ===
ensure_fastfetch || print_colored "$YELLOW" "fastfetch not installed; continuing"
install_dependencies
install_starship_and_fzf
install_zoxide

# === Shell init / aliases (your existing functions) ===
seed_rc_if_missing
link_rc_dir
install_shell_rc

print_colored "$GREEN" "Done! Restart your shell (or 'exec bash') to pick up changes."


