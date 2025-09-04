#!/bin/sh -e

# Define color codes using tput for better compatibility
RC=$(tput sgr0)
RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
GREEN=$(tput setaf 2)

LINUXTOOLBOXDIR="$HOME/linuxtoolbox"
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

# Setup functions
setup_directories() {
    GITPATH=$(dirname "$(realpath "$0")")

    # Keep a stable home-owned path
    TREW_HOME="$HOME/.trew"
    MYBASH_SRC="$GITPATH/vendor/mybash" 
    MYBASH_DST="$TREW_HOME/mybash"

    mkdir -p "$TREW_HOME"

    if [ ! -d "$MYBASH_SRC" ]; then
        print_colored "$RED" "vendor/mybash not found in repo. Copy your mybash here first."
        exit 1
    fi

    ln -sfn "$MYBASH_SRC" "$MYBASH_DST"
    print_colored "$GREEN" "mybash linked: $MYBASH_DST"
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
    if command -v fastfetch >/dev/null 2>&1; then return 0; fi
    print_colored "$YELLOW" "Installing fastfetch from source…"

    if command -v apt >/dev/null 2>&1; then
        ${SUDO_CMD} apt update -y
        ${SUDO_CMD} apt install -y git cmake gcc g++ pkg-config \
            libdrm-dev libwayland-dev libx11-dev libxcb1-dev \
            libxcb-randr0-dev libxcb-xinerama0-dev libpci-dev \
            libgl1-mesa-dev
    fi

    cache="$HOME/.trew/cache/fastfetch"
    mkdir -p "$cache"
    if [ -d "$cache/.git" ]; then
        git -C "$cache" fetch --depth=1 origin
        git -C "$cache" reset --hard origin/master 2>/dev/null || git -C "$cache" reset --hard origin/main
    else
        git clone --depth=1 https://github.com/fastfetch-cli/fastfetch.git "$cache"
    fi

    cmake -S "$cache" -B "$cache/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$cache/build" -j"$(nproc)"
    ${SUDO_CMD} cmake --install "$cache/build" || return 1

    case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH";; esac
    print_colored "$GREEN" "fastfetch installed."
}


create_fastfetch_config() {
    USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    CONFIG_DIR="$USER_HOME/.config/fastfetch"
    CONFIG_FILE="$CONFIG_DIR/config.jsonc"
    SRC="$GITPATH/config/fastfetch/config.jsonc"   # <- keep it here in repo

    mkdir -p "$CONFIG_DIR"
    ln -sfn "$SRC" "$CONFIG_FILE" || {
        print_colored "$RED" "Failed to link fastfetch config"
        exit 1
    }
    print_colored "$GREEN" "Linked fastfetch config -> $SRC"
}


install_dependencies() {
    DEPENDENCIES='bash bash-completion tar bat tree multitail wget unzip fontconfig trash-cli'
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

        if grep -qi microsoft /proc/version 2>/dev/null && [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
            print_colored "$YELLOW" "WSL detected. Install a Nerd Font on WINDOWS and select it in Windows Terminal > Profile > Appearance."
        fi
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


link_config() {
    USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    mkdir -p "$USER_HOME/.config"

    # Source block
    BRC="$USER_HOME/.bashrc"
    MARK_BEGIN="# >>> .trew init >>>"
    MARK_END="# <<< .trew init <<<"
    SNIPPET=$'# >>> .trew init >>>\n[ -f "$HOME/.trew/mybash/.bashrc" ] && . "$HOME/.trew/mybash/.bashrc"\n# <<< .trew init <<<\n'

    touch "$BRC"
    if ! grep -qF "$MARK_BEGIN" "$BRC"; then
        printf '\n%s' "$SNIPPET" >> "$BRC"
        print_colored "$GREEN" "Injected .trew source block into ~/.bashrc"
    else
        print_colored "$YELLOW" "~/.bashrc already includes .trew block"
    fi

    # Starship config from this repo
    ln -sfn "$GITPATH/starship.toml" "$USER_HOME/.config/starship.toml"
    print_colored "$GREEN" "Linked starship.toml"
}

# Main execution
setup_directories
check_environment
ensure_fastfetch || print_colored "$YELLOW" "fastfetch not installed; config still linked."create_fastfetch_config
create_fastfetch_config
install_dependencies
install_starship_and_fzf
install_zoxide

if link_config; then
    print_colored "$GREEN" "Done!\nrestart your shell to see the changes."
else
    print_colored "$RED" "Something went wrong!"
fi
