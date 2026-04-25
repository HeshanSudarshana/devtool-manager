#!/usr/bin/env bash

# Node.js management module - wraps nvm

NODE_ROOT="${DTM_ROOT}/node"

# Check and load nvm
ensure_nvm() {
    # Check if nvm command is available
    if ! command -v nvm &> /dev/null; then
        # Try to load nvm from common locations
        if [ -s "$NVM_DIR/nvm.sh" ]; then
            source "$NVM_DIR/nvm.sh"
        elif [ -s "$HOME/.nvm/nvm.sh" ]; then
            export NVM_DIR="$HOME/.nvm"
            source "$NVM_DIR/nvm.sh"
        elif [ -s "/usr/local/opt/nvm/nvm.sh" ]; then
            export NVM_DIR="/usr/local/opt/nvm"
            source "$NVM_DIR/nvm.sh"
        fi
    fi
    
    # Final check
    if ! command -v nvm &> /dev/null; then
        log_error "nvm is not installed" >&2
        echo "" >&2
        log_info "nvm is required for Node.js management" >&2
        echo "" >&2
        read -p "Would you like to install nvm now? (y/N): " -n 1 -r >&2
        echo "" >&2
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installing nvm from master branch..." >&2
            
            # Download and install nvm
            if curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash; then
                # Load nvm in current session
                export NVM_DIR="$HOME/.nvm"
                [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
                
                log_success "nvm installed successfully!" >&2
                log_info "Please restart your shell or run: source ~/.bashrc (or ~/.zshrc)" >&2
                echo "" >&2
                
                # Verify nvm is now available
                if command -v nvm &> /dev/null; then
                    return 0
                else
                    log_warn "nvm installed but not yet active in this session" >&2
                    log_info "Please run: source $NVM_DIR/nvm.sh" >&2
                    return 1
                fi
            else
                log_error "Failed to install nvm" >&2
                log_info "Please install manually: https://github.com/nvm-sh/nvm" >&2
                return 1
            fi
        else
            echo "" >&2
            log_info "To install nvm manually:" >&2
            echo "  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash" >&2
            echo "" >&2
            log_info "Or visit: https://github.com/nvm-sh/nvm" >&2
            return 1
        fi
    fi
    
    return 0
}

# Pull (install) Node.js version using nvm
pull_node() {
    local version="$1"
    
    if ! ensure_nvm; then
        exit 1
    fi
    
    log_info "Installing Node.js $version using nvm..."
    
    # Use nvm to install
    nvm install "$version"
    
    if [[ $? -eq 0 ]]; then
        log_success "Node.js $version installed successfully"
        log_info "Run 'dtm set node $version' to activate this version"
    else
        log_error "Failed to install Node.js $version"
        exit 1
    fi
}

# Set Node.js version as active using nvm
# Usage: set_node <version> [mode]
#   mode: "set" (default) verbose; "use" quiet (for shell-only activation).
#   nvm itself is per-shell, so neither mode persists beyond emitted exports.
set_node() {
    local version="$1"
    local mode="${2:-set}"

    if ! ensure_nvm; then
        exit 1
    fi

    if [[ "$mode" == "set" ]]; then
        log_info "Switching to Node.js $version using nvm..." >&2
    fi

    nvm use "$version" >/dev/null 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Failed to switch to Node.js $version" >&2
        if [[ "$mode" == "set" ]]; then
            log_info "Available versions:" >&2
            nvm ls >&2
        fi
        exit 1
    fi

    local node_path
    node_path=$(nvm which "$version" 2>/dev/null)

    if [[ -z "$node_path" ]]; then
        log_error "Could not determine Node.js installation path" >&2
        exit 1
    fi

    if [[ "$mode" == "set" ]]; then
        log_success "Node.js $version activated" >&2

        if [[ -f "$node_path" ]]; then
            echo "" >&2
            log_info "Version details:" >&2
            "$node_path" --version >&2
            log_info "npm version: $(dirname "$node_path")/npm --version 2>/dev/null" >&2
            echo "" >&2
        fi

        log_info "Applying changes to current shell..." >&2
    fi

    echo "export NVM_DIR=\"${NVM_DIR:-$HOME/.nvm}\""
    echo "[ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\""
    echo "nvm use $version --silent"
}

# List installed Node.js versions using nvm
list_node() {
    if ! ensure_nvm; then
        exit 1
    fi
    
    log_info "Installed Node.js versions (via nvm):"
    nvm ls
    
    echo ""
    log_info "To see all available versions online:"
    echo "  nvm ls-remote"
}

# Print currently active Node.js version (or fail if none)
current_node() {
    if ! ensure_nvm; then
        return 1
    fi

    local current
    current=$(nvm current 2>/dev/null)

    if [[ -z "$current" || "$current" == "none" || "$current" == "system" ]]; then
        log_warn "No active Node.js version managed by nvm (nvm current: ${current:-empty})" >&2
        return 1
    fi

    # Strip leading "v" so output matches `dtm pull node <version>` input
    echo "${current#v}"
}

# Remove Node.js version using nvm
remove_node() {
    local version="$1"
    
    if ! ensure_nvm; then
        exit 1
    fi
    
    log_warn "About to uninstall Node.js $version using nvm"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        nvm uninstall "$version"
        
        if [[ $? -eq 0 ]]; then
            log_success "Node.js $version removed"
        else
            log_error "Failed to remove Node.js $version"
        fi
    else
        log_info "Removal cancelled"
    fi
}
