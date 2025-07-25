#!/bin/sh
# This script is meant to be POSIX compatible, to work on as many different systems as possible.
# Please try to stick to this. Use a tool like shellcheck to validate changes.
set -eu

# The whole body of the script is wrapped in a function so that a partially
# downloaded script does not get executed by accident. The function is called
# at the end.
main () {
    install_root="$HOME/.dune"
    bin_dir="${install_root}/bin"

    # Reset
    Color_Off='\033[0m' # Text Reset

    # Regular Colors
    Red='\033[0;31m'    # Red
    Green='\033[0;32m'  # Green
    Yellow='\033[0;33m' # Yellow
    White='\033[0;0m'   # White

    # Bold
    Bold_Green='\033[1;32m' # Bold Green
    Bold_White='\033[1m'    # Bold White

    error() {
        printf "%berror%b: %s\n" "${Red}" "${Color_Off}" "$*" >&2
        exit 1
    }

    warn() {
        printf "%bwarn%b: %s\n" "${Yellow}" "${Color_Off}" "$*" >&2
    }

    info() {
         printf "%b%s %b" "${White}" "$*" "${Color_Off}"
    }

    info_bold() {
        printf "%b%s %b" "${Bold_White}" "$*" "${Color_Off}"
    }

    success() {
        printf "%b%s %b" "${Green}" "$*" "${Color_Off}"
    }

    success_bold() {
        printf "%b%s %b" "${Bold_Green}" "$*" "${Color_Off}"
    }

    command_exists() {
        command -v "$1" >/dev/null 2>&1
    }

    ensure_command() {
        command_exists "$1" || error "Failed to find \"$1\". This script needs \"$1\" to be able to install dune."
    }

    unsubst_home() {
        echo "$1" | sed -e "s#^$HOME#\$HOME#"
    }

    remove_home() {
        echo "$1" | sed -e "s#^$HOME/##" | sed -e 's#^/##'
    }

    tildify() {
        case "$1" in
        "$HOME"/*)
            tilde_replacement=\~
            echo "$1" | sed "s|$HOME|$tilde_replacement|g"
            ;;
        *)
            echo "$1"
            ;;
        esac
    }

    get_current_dune_state() {
        ensure_command "which"
        which_dune=$(which dune || echo "none")
        case "$which_dune" in
            none)
                echo none
                ;;
            $HOME/.opam/* | ~/.opam/*)
                echo opam
                ;;
            $HOME/.local/bin/* | ~/.local/bin/*)
                echo home_local
                ;;
            $HOME/.dune/bin/* | ~/.dune/bin/*)
                echo home_dune
                ;;
            $HOME/* | ~/*)
                echo home_other
                ;;
            *)
                echo other
                ;;
        esac
    }

    opam_switch_before_dot_local_bin_in_path() {
        # The most conventional place to install dune is ~/.local but if
        # ~/.local/bin is already in the user's PATH variable and the current
        # opam switch appears in PATH before ~/.local/bin then this will cause
        # any dune managed by opam to take precedence over the dune installed
        # by this script, which is likely not what the user intended when they
        # ran this script. This function detects this case and returns 0 iff
        # ~/.local/bin is already in PATH and is behind the current opam
        # switch's bin directory.
        echo "$PATH" |\
            tr ':' '\n' |\
            grep "\(\($HOME\|~\)/\.local/bin\)\|\(\($HOME\|~\)/\.opam\)" |\
            sed 's#.*opam.*#opam#' |\
            sed 's#.*local.*#local#' |\
            paste -sd: - |\
            grep '^\(opam\)\+:\(local\)' > /dev/null
    }

    if [ "$#" != "1" ]; then
        echo "expected 1 argument, got $#"
        return
    fi
    version="$1"
    case $(uname -ms) in
        'Darwin x86_64')
            target=x86_64-apple-darwin
            ;;
        'Darwin arm64')
            target=aarch64-apple-darwin
            ;;
        'Linux x86_64')
            target=x86_64-unknown-linux-musl
            ;;
        *)
            error "The dune installation script does not currently support $(uname -ms)."
    esac
    tarball="dune-$version-$target.tar.gz"
    tar_uri="https://github.com/ocaml-dune/dune-bin/releases/download/$version/$tarball"
    # The tarball is expected to contain a single directory with this name:
    tarball_dir="dune-$version-$target"

    ensure_command "tar"
    ensure_command "gzip"
    ensure_command "curl"

    echo
    info_bold "Welcome to the Dune installer!"
    echo
    echo

    install_root_local="$HOME/.local"
    install_root_dune="$HOME/.dune"
    if opam_switch_before_dot_local_bin_in_path; then
        warn "Your current opam switch is earlier in your \$PATH than dune's recommended install location. This installer would normally recommend installing dune to $install_root_local however in your case this would cause the dune executable from your current opam switch to take precedent over the dune installed by this installer. This installer will proceed with an alternative default installation directory $install_root_dune which you are free to override."
        echo
        default_install_root="$install_root_dune"
        install_root_local_message=""
        install_root_dune_message=" (recommended)"
    else
        default_install_root="$install_root_local"
        install_root_local_message=" (recommended)"
        install_root_dune_message=""
    fi

    install_root=""
    while [ -z "$install_root" ]; do
        info "Where would you install dune? (enter index number or custom absolute path)"
        echo
        info "1) $install_root_local$install_root_local_message"
        echo
        info "2) $install_root_dune$install_root_dune_message"
        echo
        read -p "[$default_install_root] > " choice

        case "$choice" in
            "")
                install_root=$default_install_root
                ;;
            1)
                install_root=$install_root_local
                ;;
            2)
                install_root=$install_root_dune
                ;;
            /*)
                install_root=$choice
                ;;
            *)
                echo
                warn "Unrecognized choice: $choice"
                echo
                ;;
        esac
    done

    echo
    info "Dune will now be installed to $install_root"
    echo

    tmp_dir="$(mktemp -d -t dune-install.XXXXXXXX)"
    trap 'rm -rf "${tmp_dir}"' EXIT

    # Determine whether we can use --no-same-owner to force tar to extract with user permissions.
    touch "${tmp_dir}/tar-detect"
    tar cf "${tmp_dir}/tar-detect.tar" -C "${tmp_dir}" tar-detect
    if tar -C "${tmp_dir}" -xf "${tmp_dir}/tar-detect.tar" --no-same-owner; then
        tar_owner="--no-same-owner"
    else
        tar_owner=""
    fi
    tmp_tar="$tmp_dir/$tarball"

    curl --fail --location --progress-bar \
        --proto '=https' --tlsv1.2 \
        --output "$tmp_tar" "$tar_uri" ||
        error "Failed to download dune tar from \"$tar_uri\""

    tar -xf "$tmp_tar" -C "$tmp_dir" "${tar_owner}" > /dev/null 2>&1 ||
        error "Failed to extract dune archive content from \"$tmp_tar\""

    mkdir -p "$install_root"
    for d in "$tmp_dir/$tarball_dir"/*; do
        cp -r "$d" "$install_root"
    done

    echo
    success "Dune successfully installed to $install_root!"
    echo
    echo

    shell=$(basename "${SHELL:-*}")
    env_dir="$install_root/share/dune/env"
    case "$shell" in
        bash)
            env_file="$env_dir/env.bash"
            shell_config="$HOME/.bashrc"
            ;;
        zsh)
            env_file="$env_dir/env.zsh"
            shell_config="$HOME/.zshrc"
            ;;
        fish)
            env_file="$env_dir/env.fish"
            shell_config="$HOME/.config/fish/config.fish"
            ;;
        *)
            info "The install script does not recognize your shell ($shell)."
            echo
            info "It's up to you to ensure $install_root/bin is in your \$PATH variable."
            echo
            info "This installer will now exit."
            echo
            exit 0
            ;;
    esac

    dune_env_call="__dune_env $(unsubst_home $install_root)"
    if [ -f "$shell_config" ] && match=$(grep -n "$(echo $dune_env_call | sed 's#\$#\\$#')" "$shell_config"); then
        info "It appears your shell config file ($shell_config) is already set up correctly as it contains the line:"
        echo
        info "$match"
        echo
        echo
        info "Just in case it isn't, here are the lines that need run when your shell starts to initialize dune:"
        echo
        echo
        echo "source $(unsubst_home $env_file)"
        echo "__dune_env $(unsubst_home $install_root)"
        echo
        info "This installer will now exit."
        echo
        exit 0
    fi

    info "To run dune from your terminal, you'll need to add the following lines to your shell config file ($shell_config):"
    echo
    echo
    echo "source $(unsubst_home $env_file)"
    echo "__dune_env $(unsubst_home $install_root)"
    echo

    should_update_shell_config=""
    while [ -z "$should_update_shell_config" ]; do
        info "Would you like these lines to be appended to $shell_config? (y/n)"
        read -p "[n] > " choice
        case "$choice" in
            "")
                should_update_shell_config="n"
                ;;
            y|Y)
                should_update_shell_config="y"
                ;;
            n|N)
                should_update_shell_config="n"
                ;;
            *)
                warn "Please enter y or n."
                echo
                ;;
        esac
    done

    case "$should_update_shell_config" in
        y)
            printf "\n# From dune installer:\nsource $(unsubst_home $env_file)\n__dune_env $(unsubst_home $install_root)" >> "$shell_config"
            echo
            success "Add dune setup commands to $shell_config!"
            echo
            ;;
        *)
        ;;
    esac

    info "This installer will now exit."
    echo
}
main "$@"
