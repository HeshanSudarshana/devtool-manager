#!/usr/bin/env bash

# Go management module

GO_ROOT="${DTM_ROOT}/go"
GO_WORKSPACE_ROOT="${DTM_ROOT}/go-workspaces"

# Get the latest patch version for a major.minor version from Go's download page
get_latest_go_version() {
    local major_minor="$1"

    log_info "Fetching latest Go $major_minor version..." >&2

    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "https://go.dev/dl/?mode=json" 2>/dev/null) || {
        log_error "Failed to query go.dev download index" >&2
        return 1
    }

    local version
    version=$(echo "$response" \
        | jq -r '.[] | select(.stable == true) | .version' 2>/dev/null \
        | sed 's/^go//' \
        | grep -E "^${major_minor}\." \
        | sort -V \
        | tail -1)

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
    
    local download_url="https://go.dev/dl/go${version}.${os_name}-${arch_name}.tar.gz"

    if ! dtm_url_exists "$download_url"; then
        log_error "Could not find download URL for Go $version (OS: $os_name, ARCH: $arch_name)" >&2
        return 1
    fi

    echo "$download_url"
}

# Pull (download and install) Go
pull_go() {
    local version="$1"
    local exact_version=""

    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_info "Version $version is a major.minor version, fetching latest patch version..."
        exact_version=$(get_latest_go_version "$version") || {
            log_error "Failed to get latest version for Go $version"
            exit 1
        }
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi

    mkdir -p "$GO_ROOT"
    mkdir -p "$GO_WORKSPACE_ROOT"

    local install_dir="${GO_ROOT}/${exact_version}"
    local workspace_dir="${GO_WORKSPACE_ROOT}/${exact_version}"
    local lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "Go $exact_version is already installed at $install_dir"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local download_url
    download_url=$(get_go_download_url "$exact_version") || exit 1

    log_info "Downloading Go from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/go.tar.gz"

    if ! dtm_download "$download_url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Fetching checksum..."
    # Go publishes sha256 at dl.google.com, not go.dev (where the URL is HTML)
    local checksum_url="${download_url/https:\/\/go.dev\/dl\//https://dl.google.com/go/}.sha256"
    local expected_checksum
    expected_checksum=$(fetch_checksum_from_url "$checksum_url")
    if [[ -z "$expected_checksum" ]]; then
        log_error "Failed to fetch checksum from $checksum_url"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Verifying checksum (sha256)..."
    if ! verify_checksum "$download_file" "$expected_checksum" sha256; then
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Extracting Go to $install_dir..."
    mkdir -p "$install_dir"
    if ! tar -xzf "$download_file" -C "$install_dir" --strip-components=1; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    mkdir -p "$workspace_dir"/{src,pkg,bin}

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "Go $exact_version installed successfully to $install_dir"
    log_info "Workspace created at $workspace_dir"
    log_info "Run 'dtm set go $exact_version' to activate this version"
}

# Set Go version as active
set_go() {
    local version="$1"
    
    # Find matching installation
    local install_dir=""
    
    if [[ -d "${GO_ROOT}/${version}" ]]; then
        install_dir="${GO_ROOT}/${version}"
    else
        local major_minor matching_dirs
        major_minor=$(echo "$version" | grep -o '^[0-9]\+\.[0-9]\+')
        if [[ -n "$major_minor" ]]; then
            matching_dirs=$(find "$GO_ROOT" -maxdepth 1 -type d -name "${major_minor}.*" 2>/dev/null | sort -V | tail -1)

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

    local exact_version workspace_dir
    exact_version=$(basename "$install_dir")
    workspace_dir="${GO_WORKSPACE_ROOT}/${exact_version}"

    if [[ ! -d "$workspace_dir" ]]; then
        mkdir -p "$workspace_dir"/{src,pkg,bin}
        log_info "Created workspace directory at $workspace_dir" >&2
    fi

    log_info "Setting Go to $exact_version..." >&2

    mkdir -p "$(dirname "$DTM_CONFIG")"

    dtm_clean_dtmrc_for "GOROOT" "/go/.*/bin"
    dtm_clean_dtmrc_for "GOPATH"
    
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

# List available Go versions from go.dev.
# Usage: available_go [major_or_major_minor]
#   No arg     -> list recent stable releases (last 20).
#   <prefix>   -> list all stable versions starting with that prefix
#                 (e.g. "1" or "1.22").
available_go() {
    local filter="$1"

    log_info "Fetching available Go versions..." >&2
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "https://go.dev/dl/?mode=json&include=all" 2>/dev/null) || {
        log_error "Failed to query go.dev download index" >&2
        return 1
    }

    local versions
    versions=$(echo "$response" \
        | jq -r '.[] | select(.stable==true) | .version' 2>/dev/null \
        | sed 's/^go//' \
        | sort -V -u)

    if [[ -z "$versions" ]]; then
        log_error "No Go versions parsed from go.dev index" >&2
        return 1
    fi

    if [[ -n "$filter" ]]; then
        local matched
        matched=$(echo "$versions" | grep -E "^${filter//./\\.}(\$|\\.)" || true)
        if [[ -z "$matched" ]]; then
            log_warn "No Go versions matching '$filter'"
            return 1
        fi
        log_info "Available Go versions matching '$filter':"
        echo "$matched" | sed 's/^/    /'
    else
        log_info "Available Go versions (most recent 20; pass a prefix to filter):"
        echo "$versions" | tail -20 | sed 's/^/    /'
    fi
}

# Print currently active Go version (or fail if none)
current_go() {
    local current_goroot="${GOROOT:-}"
    if [[ -z "$current_goroot" ]]; then
        log_warn "No active Go version (GOROOT not set)" >&2
        return 1
    fi
    if [[ "$current_goroot" != "$GO_ROOT"/* ]]; then
        log_warn "Active GOROOT is not managed by dtm: $current_goroot" >&2
        return 1
    fi
    if [[ ! -x "$current_goroot/bin/go" ]]; then
        log_warn "Active Go install is missing: $current_goroot" >&2
        return 1
    fi
    basename "$current_goroot"
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
