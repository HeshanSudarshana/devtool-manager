#!/usr/bin/env bash

# Go management module

GO_ROOT="${DTM_ROOT}/go"
GO_WORKSPACE_ROOT="${DTM_ROOT}/go-workspaces"

# Get the latest patch version for a major.minor version from Go's download page
get_latest_go_version() {
    local major_minor="$1"
    
    log_info "Fetching latest Go $major_minor version..." >&2
    
    # Fetch the download page and extract versions using Python
    local version=$(curl -s "https://go.dev/dl/?mode=json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
versions = [item['version'].replace('go', '') for item in data if item.get('stable', False)]
# Filter versions matching the pattern
matching = [v for v in versions if v.startswith('${major_minor}.')]
if matching:
    # Sort by splitting version parts as integers
    sorted_versions = sorted(matching, key=lambda x: [int(p) for p in x.split('.')])
    print(sorted_versions[-1])
" 2>/dev/null)
    
    if [[ -z "$version" ]]; then
        log_error "Could not find version matching $major_minor" >&2
        return 1
    fi
    
    echo "$version"
}

# Build download URL for Go
get_go_download_url() {
    local version="$1"
    
    # Determine OS and architecture
    local os_name
    case "$OS" in
        linux) os_name="linux" ;;
        mac) os_name="darwin" ;;
    esac
    
    local arch_name
    case "$ARCH" in
        x64) arch_name="amd64" ;;
        aarch64) arch_name="arm64" ;;
    esac
    
    # Build download URL
    local download_url="https://go.dev/dl/go${version}.${os_name}-${arch_name}.tar.gz"
    
    # Verify URL exists (go.dev returns 302 redirect on valid URLs)
    local status_code=$(curl -sI -o /dev/null -w "%{http_code}" "$download_url")
    if [[ "$status_code" != "302" && "$status_code" != "200" ]]; then
        log_error "Could not find download URL for Go $version (OS: $os_name, ARCH: $arch_name)" >&2
        return 1
    fi
    
    echo "$download_url"
}

# Pull (download and install) Go
pull_go() {
    local version="$1"
    local exact_version=""
    
    # Check if version is just major.minor (e.g., "1.21") or full version (e.g., "1.21.5")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_info "Version $version is a major.minor version, fetching latest patch version..."
        exact_version=$(get_latest_go_version "$version")
        if [[ $? -ne 0 ]]; then
            log_error "Failed to get latest version for Go $version"
            exit 1
        fi
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi
    
    # Create Go directory if it doesn't exist
    mkdir -p "$GO_ROOT"
    mkdir -p "$GO_WORKSPACE_ROOT"
    
    # Determine installation directory
    local install_dir="${GO_ROOT}/${exact_version}"
    local workspace_dir="${GO_WORKSPACE_ROOT}/${exact_version}"
    
    if [[ -d "$install_dir" ]]; then
        log_warn "Go $exact_version is already installed at $install_dir"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            return 0
        fi
        rm -rf "$install_dir"
    fi
    
    # Get download URL
    local download_url=$(get_go_download_url "$exact_version")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    log_info "Downloading Go from: $download_url"
    
    # Create temp directory for download
    local temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/go.tar.gz"
    
    # Download with progress
    if ! curl -L --progress-bar -o "$download_file" "$download_url"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log_info "Extracting Go to $install_dir..."
    
    # Extract tarball
    mkdir -p "$install_dir"
    tar -xzf "$download_file" -C "$install_dir" --strip-components=1
    
    if [[ $? -ne 0 ]]; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi
    
    # Create workspace directory
    mkdir -p "$workspace_dir"/{src,pkg,bin}
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_success "Go $exact_version installed successfully to $install_dir"
    log_info "Workspace created at $workspace_dir"
    log_info "Run 'dtm set go $exact_version' to activate this version"
}

# Set Go version as active
set_go() {
    local version="$1"
    
    # Find matching installation
    local install_dir=""
    
    # Check if exact version exists
    if [[ -d "${GO_ROOT}/${version}" ]]; then
        install_dir="${GO_ROOT}/${version}"
    else
        # Try to find latest version matching the major.minor version
        local major_minor=$(echo "$version" | grep -o '^[0-9]\+\.[0-9]\+')
        if [[ -n "$major_minor" ]]; then
            local matching_dirs=$(find "$GO_ROOT" -maxdepth 1 -type d -name "${major_minor}.*" 2>/dev/null | sort -V | tail -1)
            
            if [[ -n "$matching_dirs" ]]; then
                install_dir="$matching_dirs"
            fi
        fi
        
        if [[ -z "$install_dir" ]]; then
            log_error "Go $version is not installed"
            log_info "Available versions:"
            list_go
            exit 1
        fi
    fi
    
    local exact_version=$(basename "$install_dir")
    local workspace_dir="${GO_WORKSPACE_ROOT}/${exact_version}"
    
    # Create workspace if it doesn't exist
    if [[ ! -d "$workspace_dir" ]]; then
        mkdir -p "$workspace_dir"/{src,pkg,bin}
        log_info "Created workspace directory at $workspace_dir" >&2
    fi
    
    log_info "Setting Go to $exact_version..." >&2
    
    # Update .dtmrc configuration file
    mkdir -p "$(dirname $DTM_CONFIG)"
    
    # Remove old Go configuration
    if [[ -f "$DTM_CONFIG" ]]; then
        sed -i '/^export GOROOT=/d' "$DTM_CONFIG"
        sed -i '/^export GOPATH=/d' "$DTM_CONFIG"
        sed -i '/^export PATH=.*go.*bin/d' "$DTM_CONFIG"
    fi
    
    # Add new Go configuration
    cat >> "$DTM_CONFIG" << EOF
export GOROOT="${install_dir}"
export GOPATH="${workspace_dir}"
export PATH="\${GOROOT}/bin:\${GOPATH}/bin:\${PATH}"
EOF
    
    log_success "Go $exact_version activated" >&2
    
    # Show current Go version
    if [[ -f "${install_dir}/bin/go" ]]; then
        echo "" >&2
        log_info "Version details:" >&2
        "${install_dir}/bin/go" version 2>&1 >&2
        log_info "GOROOT: $install_dir" >&2
        log_info "GOPATH: $workspace_dir" >&2
        echo "" >&2
    fi
    
    log_info "Applying changes to current shell..." >&2
    
    # Output the export commands to stdout (plain text, no colors)
    echo "export GOROOT=\"${install_dir}\""
    echo "export GOPATH=\"${workspace_dir}\""
    echo "export PATH=\"\${GOROOT}/bin:\${GOPATH}/bin:\${PATH}\""
}

# List installed Go versions
list_go() {
    if [[ ! -d "$GO_ROOT" ]]; then
        log_info "No Go versions installed"
        return 0
    fi
    
    log_info "Installed Go versions:"
    
    local current_goroot="${GOROOT:-}"
    
    for dir in "$GO_ROOT"/*; do
        if [[ -d "$dir" && -f "$dir/bin/go" ]]; then
            local version=$(basename "$dir")
            if [[ "$dir" == "$current_goroot" ]]; then
                echo -e "  ${GREEN}* $version${NC} (active)"
            else
                echo "    $version"
            fi
        fi
    done
}

# Remove Go version
remove_go() {
    local version="$1"
    local install_dir="${GO_ROOT}/${version}"
    local workspace_dir="${GO_WORKSPACE_ROOT}/${version}"
    
    if [[ ! -d "$install_dir" ]]; then
        log_error "Go $version is not installed"
        return 1
    fi
    
    log_warn "About to remove Go $version from:"
    log_warn "  - $install_dir"
    if [[ -d "$workspace_dir" ]]; then
        log_warn "  - $workspace_dir (workspace with dependencies)"
    fi
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$install_dir"
        if [[ -d "$workspace_dir" ]]; then
            rm -rf "$workspace_dir"
        fi
        log_success "Go $version removed"
    else
        log_info "Removal cancelled"
    fi
}
