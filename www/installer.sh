#!/usr/bin/env bash
# shellcheck disable=SC1091
. /etc/os-release || {
    log_error "Failed to source /etc/os-release"
    exit 1
}

log_info() {
    local message="$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - \033[32mINFO: $message\033[0m" >&2
}

log_error() {
    local message="$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - \033[31mERROR: $message\033[0m" >&2
}

detect_sudo_tool() {
    if [ "$(id -u)" -eq 0 ]; then
        echo ""
        log_info "Running as root, no sudo tool required."
    else
        if command -v sudo &> /dev/null; then
            echo "sudo"
        elif command -v doas &> /dev/null; then
            echo "doas"
        else
            log_error "No sudo tool found. Please install sudo or doas."
            exit 1
        fi
    fi
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt-get"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        log_error "No supported package manager found."
        exit 1
    fi
}

debian12_install_fastfetch() {
        local arch package_name url sudo_tool
    arch=$(uname -m)

    case "$arch" in
        x86_64)   package_name="fastfetch-linux-amd64.deb" ;;
        aarch64)  package_name="fastfetch-linux-aarch64.deb" ;;
        armv7l)   package_name="fastfetch-linux-armv7l.deb" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac

    log_info "Fetching latest Fastfetch release for $arch..."
    url=$(curl -s https://api.github.com/repos/fastfetch-cli/fastfetch/releases/latest | grep browser_download_url | cut -d\" -f4 | grep "$package_name")

    if [ -z "$url" ]; then
        log_error "Failed to retrieve the download URL for $package_name"
        return 1
    fi

    log_info "Downloading $package_name..."
    if ! curl -LSso "/tmp/$package_name" "$url"; then
        log_error "Download failed for $package_name"
        return 1
    fi

    sudo_tool=$(detect_sudo_tool)
    log_info "Installing $package_name..."
    if ! ${sudo_tool} apt-get install "/tmp/$package_name" -y; then
        log_error "Installation failed for $package_name"
        return 1
    fi

    log_info "Fastfetch installed successfully!"
}

install_packages() {
    log_info "Installing required packages..."

    local sudo_tool
    sudo_tool=$(detect_sudo_tool)

    # Install other common packages
    local packages=("zsh" "git" "curl" "zoxide" "unzip" "jq" "eza")

    case $ID in 
        debian)
            if [ "$VERSION_ID" = "12" ]; then
                debian12_install_fastfetch
            else
                $sudo_tool apt-get install -y fastfetch
            fi
            ;;
        ubuntu)
            if [ "$VERSION_ID" = "24.04" ]; then
                debian12_install_fastfetch
            else
                $sudo_tool apt-get install -y fastfetch
            fi
            ;;
        *)
            packages+=("fastfetch")
            ;;
    esac

    log_info "Installing common packages:\n$(printf "  - %s\n" "${packages[@]}")"

    case $(detect_package_manager) in
        apt-get)
            $sudo_tool apt-get update && apt-get install -y "${packages[@]}"
            ;;
        pacman)
            $sudo_tool pacman -Sy --noconfirm --needed "${packages[@]}"
            ;;
        yum)
            $sudo_tool yum install -y "${packages[@]}"
            ;;
        apk)
            $sudo_tool apk add "${packages[@]}"
            ;;
        *)
            log_error "Unsupported package manager for installing common packages."
            local missing_cmds=()
            for cmd in fastfetch "${packages[@]}"; do
                if ! command -v "$cmd" >/dev/null 2>&1; then
                    missing_cmds+=("$cmd")
                fi
            done
            if [ ${#missing_cmds[@]} -gt 0 ]; then
                log_error "The following required commands are missing:\n$(printf "  - %s\n" "${missing_cmds[@]}")"
                log_error "Please install them manually."
                exit 1
            else
                log_info "All required commands are already installed."
            fi
            ;;
    esac
}

main() {

    log_info "Installer downloaded successfully. Starting installation..."

    install_packages

    # Remove Oh my Posh if it exists
    if [ -f "$HOME/.local/bin/oh-my-posh" ]; then
        rm "$HOME/.local/bin/oh-my-posh" && \
        rm -rf "$HOME/.cache/oh-my-posh"
    fi

    mkdir -p ~/.cache


    if [ ! -d "$DSTPATH/.git" ]; then
        # Delete $DSTPATH if it exists and is not a repo to ensure a clean install
        if [ -d "$DSTPATH" ]; then
            rm -rf "$DSTPATH"
        fi

        git clone --depth=1 https://github.com/AWildLeon/lhzsh.git "$DSTPATH"
    else
        ~/.lhzsh/bin/lhzsh update
    fi

    mkdir -p ~/.config ~/.local/bin

    
    # link eza config
    local skip_eza_link=false
    if [ -L ~/.config/eza ]; then
        if [ "$(readlink ~/.config/eza)" = "$HOME/.lhzsh/eza-config" ]; then
            skip_eza_link=true
        else
            rm ~/.config/eza
        fi
    elif [ -d ~/.config/eza ]; then
        if ! rmdir ~/.config/eza 2>/dev/null; then
            log_error "eza config dir is not empty, skipping"
            skip_eza_link=true
        fi
    elif [ -e ~/.config/eza ]; then
        if rm ~/.config/eza; then
            log_info "Removed existing eza config file"
        else
            log_error "Failed to remove existing eza config file"
            skip_eza_link=true
        fi
    fi

    if [ "$skip_eza_link" = false ]; then
        if ln -s ~/.lhzsh/eza-config ~/.config/eza; then
            log_info "eza config linked successfully"
        else
            log_error "Failed to link eza config"
        fi
    fi


    rm -f ~/.zshrc
    ~/.lhzsh/bin/lhzsh install
    mkdir -p "$DSTPATH/data"

    # Change default shell to Zsh
    local current_user current_shell
    current_user=$(id -un)
    current_shell=$(getent passwd "$current_user" | cut -d: -f7)
    
    if [ "$current_shell" != "$(which zsh)" ]; then
        log_info "Changing default shell to Zsh..."
        chsh -s "$(which zsh)"
    else
        log_info "Default shell is already set to Zsh."
    fi
}