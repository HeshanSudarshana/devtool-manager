#!/usr/bin/env bash

# Python management module - wraps pyenv

PYTHON_ROOT="${DTM_ROOT}/python"

# Check and load pyenv
ensure_pyenv() {
    # Check if pyenv command is available
    if ! command -v pyenv &> /dev/null; then
        # Try to load pyenv from common locations
        if [ -s "$PYENV_ROOT/bin/pyenv" ]; then
            export PATH="$PYENV_ROOT/bin:$PATH"
            eval "$(pyenv init -)"
        elif [ -s "$HOME/.pyenv/bin/pyenv" ]; then
            export PYENV_ROOT="$HOME/.pyenv"
            export PATH="$PYENV_ROOT/bin:$PATH"
            eval "$(pyenv init -)"
        elif [ -s "/usr/local/bin/pyenv" ]; then
            export PYENV_ROOT="/usr/local"
            eval "$(pyenv init -)"
        fi
    fi
    
    # Final check
    if ! command -v pyenv &> /dev/null; then
        log_error "pyenv is not installed" >&2
        echo "" >&2
        log_info "pyenv is required for Python management" >&2
        echo "" >&2
        read -p "Would you like to install pyenv now? (y/N): " -n 1 -r >&2
        echo "" >&2
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installing pyenv..." >&2
            log_warn "Note: Unlike Node.js, Python must be compiled from source" >&2
            log_warn "Build tools and libraries are required for compilation" >&2
            echo "" >&2
            
            # Install build dependencies based on OS
            if [[ "$OS" == "linux" ]]; then
                if command -v pacman &> /dev/null; then
                    log_info "Detected Arch Linux - installing build dependencies..." >&2
                    sudo pacman -S --needed --noconfirm base-devel openssl zlib xz tk >&2
                elif command -v apt-get &> /dev/null; then
                    log_info "Detected Debian/Ubuntu - installing build dependencies..." >&2
                    sudo apt-get update >&2
                    sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
                        libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
                        libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
                        libffi-dev liblzma-dev >&2
                elif command -v yum &> /dev/null; then
                    log_info "Detected RHEL/CentOS/Fedora - installing build dependencies..." >&2
                    sudo yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
                        sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel >&2
                else
                    log_warn "Unknown Linux distribution. Please install build dependencies manually" >&2
                    log_info "Visit: https://github.com/pyenv/pyenv/wiki#suggested-build-environment" >&2
                fi
            elif [[ "$OS" == "mac" ]]; then
                log_info "On macOS, make sure Xcode Command Line Tools are installed" >&2
                log_info "Run: xcode-select --install" >&2
            fi
            
            # Download and install pyenv
            if curl https://pyenv.run | bash; then
                # Load pyenv in current session
                export PYENV_ROOT="$HOME/.pyenv"
                export PATH="$PYENV_ROOT/bin:$PATH"
                eval "$(pyenv init -)" 2>/dev/null
                
                log_success "pyenv installed successfully!" >&2
                echo "" >&2
                log_info "Add these lines to your ~/.bashrc or ~/.zshrc:" >&2
                echo "  export PYENV_ROOT=\"\$HOME/.pyenv\"" >&2
                echo "  export PATH=\"\$PYENV_ROOT/bin:\$PATH\"" >&2
                echo "  eval \"\$(pyenv init -)\"" >&2
                echo "" >&2
                
                # Verify pyenv is now available
                if command -v pyenv &> /dev/null; then
                    return 0
                else
                    log_warn "pyenv installed but not yet active in this session" >&2
                    log_info "Please restart your shell" >&2
                    return 1
                fi
            else
                log_error "Failed to install pyenv" >&2
                log_info "Please install manually: https://github.com/pyenv/pyenv" >&2
                return 1
            fi
        else
            echo "" >&2
            log_info "To install pyenv manually:" >&2
            echo "  curl https://pyenv.run | bash" >&2
            echo "" >&2
            log_info "Or visit: https://github.com/pyenv/pyenv" >&2
            echo "" >&2
            log_info "Then add to your shell config (~/.bashrc or ~/.zshrc):" >&2
            echo "  export PYENV_ROOT=\"\$HOME/.pyenv\"" >&2
            echo "  export PATH=\"\$PYENV_ROOT/bin:\$PATH\"" >&2
            echo "  eval \"\$(pyenv init -)\"" >&2
            return 1
        fi
    fi
    
    return 0
}

# Pull (install) Python version using pyenv
pull_python() {
    local version="$1"
    
    if ! ensure_pyenv; then
        exit 1
    fi
    
    log_info "Installing Python $version using pyenv..."
    log_info "This may take a while as Python will be compiled from source..."
    
    # Use pyenv to install
    pyenv install "$version"
    
    if [[ $? -eq 0 ]]; then
        log_success "Python $version installed successfully"
        log_info "Run 'dtm set python $version' to activate this version"
    else
        log_error "Failed to install Python $version"
        echo "" >&2
        log_info "To see available versions: pyenv install --list" >&2
        exit 1
    fi
}

# Set Python version as active using pyenv
set_python() {
    local version="$1"
    
    if ! ensure_pyenv; then
        exit 1
    fi
    
    log_info "Switching to Python $version using pyenv..." >&2
    
    # Use pyenv global to set the version
    pyenv global "$version" 2>&1 >&2
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to switch to Python $version" >&2
        log_info "Available versions:" >&2
        pyenv versions >&2
        exit 1
    fi
    
    # Get the python path after pyenv global
    local python_path=$(pyenv which python 2>/dev/null)
    local python_root=$(pyenv root)
    local python_version_dir="${python_root}/versions/${version}"
    
    if [[ -z "$python_path" ]]; then
        log_error "Could not determine Python installation path" >&2
        exit 1
    fi
    
    log_success "Python $version activated" >&2
    
    # Show version info
    if [[ -f "$python_path" ]]; then
        echo "" >&2
        log_info "Version details:" >&2
        "$python_path" --version >&2
        log_info "pip version: $(dirname "$python_path")/pip --version 2>&1 | head -1" >&2
        log_info "Location: $python_version_dir" >&2
        echo "" >&2
    fi
    
    log_info "Applying changes to current shell..." >&2
    
    # Output export commands for dtm wrapper to eval
    # Initialize pyenv and set the global version
    cat << EOF
export PYENV_ROOT="${python_root}"
export PATH="\${PYENV_ROOT}/bin:\${PATH}"
eval "\$(pyenv init -)"
pyenv global ${version}
EOF
}

# List installed Python versions using pyenv
list_python() {
    if ! ensure_pyenv; then
        exit 1
    fi
    
    log_info "Installed Python versions (via pyenv):"
    pyenv versions
    
    echo ""
    log_info "To see all available versions online:"
    echo "  pyenv install --list"
    echo ""
    log_info "Popular versions to install:"
    echo "  dtm pull python 3.12.1    # Latest Python 3.12"
    echo "  dtm pull python 3.11.7    # Latest Python 3.11"
    echo "  dtm pull python 3.10.13   # Latest Python 3.10"
}

# Remove Python version using pyenv
remove_python() {
    local version="$1"
    
    if ! ensure_pyenv; then
        exit 1
    fi
    
    log_warn "About to uninstall Python $version using pyenv"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        pyenv uninstall -f "$version"
        
        if [[ $? -eq 0 ]]; then
            log_success "Python $version removed"
        else
            log_error "Failed to remove Python $version"
        fi
    else
        log_info "Removal cancelled"
    fi
}
