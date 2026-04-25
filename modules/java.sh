#!/usr/bin/env bash

# Java/JDK management module using Eclipse Temurin

JAVA_ROOT="${DTM_ROOT}/java"

# Get the latest patch version for a major version from Temurin API
get_latest_java_version() {
    local major_version="$1"

    log_info "Fetching latest Java $major_version version from Temurin..." >&2

    local api_url="https://api.adoptium.net/v3/assets/latest/${major_version}/hotspot?image_type=jdk"

    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$api_url" 2>/dev/null) || {
        log_error "Failed to query Temurin API: $api_url" >&2
        return 1
    }

    local version
    version=$(echo "$response" | jq -r '.[0].version.semver | split("+")[0]' 2>/dev/null)

    if [[ -z "$version" || "$version" == "null" ]]; then
        log_error "Could not parse version from Temurin API" >&2
        return 1
    fi

    echo "$version"
}

# Build download URL and checksum for Temurin JDK.
# Outputs two lines: download_url, sha256 checksum
get_java_download_info() {
    local version="$1"
    local major_version
    major_version=$(echo "$version" | cut -d'.' -f1)

    local os_suffix
    case "$OS" in
        linux) os_suffix="linux" ;;
        mac) os_suffix="mac" ;;
    esac

    local api_url="https://api.adoptium.net/v3/assets/version/jdk-${version}"
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "${api_url}?architecture=${ARCH}&image_type=jdk&os=${os_suffix}" 2>/dev/null || true)

    if [[ -z "$response" || "$response" == "[]" ]]; then
        api_url="https://api.adoptium.net/v3/assets/latest/${major_version}/hotspot"
        response=$(curl -fsSL --retry 3 --retry-delay 2 "${api_url}?architecture=${ARCH}&image_type=jdk&os=${os_suffix}" 2>/dev/null || true)
    fi

    local info
    info=$(echo "$response" | jq -r '.[0].binary.package | .link, .checksum' 2>/dev/null)

    if [[ -z "$info" || "$info" == *"null"* ]]; then
        log_error "Could not find download URL/checksum for Java $version (OS: $os_suffix, ARCH: $ARCH)" >&2
        return 1
    fi

    echo "$info"
}

# Pull (download and install) Java JDK
pull_java() {
    local version="$1"
    local exact_version=""

    if [[ "$version" =~ ^[0-9]+$ ]]; then
        log_info "Version $version is a major version, fetching latest patch version..."
        exact_version=$(get_latest_java_version "$version") || {
            log_error "Failed to get latest version for Java $version"
            exit 1
        }
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi

    mkdir -p "$JAVA_ROOT"

    local install_dir="${JAVA_ROOT}/${exact_version}"
    local lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "Java $exact_version is already installed at $install_dir"
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

    local download_info
    download_info=$(get_java_download_info "$exact_version") || exit 1

    local download_url expected_checksum
    download_url=$(echo "$download_info" | sed -n '1p')
    expected_checksum=$(echo "$download_info" | sed -n '2p')

    log_info "Downloading JDK from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/jdk.tar.gz"

    if ! dtm_download "$download_url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Verifying checksum (sha256)..."
    if ! verify_checksum "$download_file" "$expected_checksum" sha256; then
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Extracting JDK to $install_dir..."
    mkdir -p "$install_dir"
    if ! tar -xzf "$download_file" -C "$install_dir" --strip-components=1; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "Java $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set java $exact_version' to activate this version"
}

# Set Java version as active
set_java() {
    local version="$1"
    
    # Find matching installation
    local install_dir=""
    
    if [[ -d "${JAVA_ROOT}/${version}" ]]; then
        install_dir="${JAVA_ROOT}/${version}"
    else
        local major_version matching_dirs
        major_version=$(echo "$version" | cut -d'.' -f1)
        matching_dirs=$(find "$JAVA_ROOT" -maxdepth 1 -type d -name "${major_version}.*" 2>/dev/null | sort -V | tail -1)

        if [[ -n "$matching_dirs" ]]; then
            install_dir="$matching_dirs"
        else
            log_error "Java $version is not installed"
            log_info "Available versions:"
            list_java
            exit 1
        fi
    fi

    log_info "Setting Java to $(basename "$install_dir")..." >&2

    mkdir -p "$(dirname "$DTM_CONFIG")"

    dtm_clean_dtmrc_for "JAVA_HOME" "/java/.*/bin"
    
    # Add new Java configuration
    cat >> "$DTM_CONFIG" << EOF
export JAVA_HOME="${install_dir}"
export PATH="\${JAVA_HOME}/bin:\${PATH}"
EOF
    
    log_success "Java $(basename "$install_dir") activated" >&2
    
    # Show current Java version from the new installation
    if [[ -f "${install_dir}/bin/java" ]]; then
        echo "" >&2
        log_info "Version details:" >&2
        "${install_dir}/bin/java" -version 2>&1 | head -3 >&2
        echo "" >&2
    fi
    
    log_info "Applying changes to current shell..." >&2
    
    # Output the export commands to stdout (plain text, no colors)
    echo "export JAVA_HOME=\"${install_dir}\""
    echo "export PATH=\"\${JAVA_HOME}/bin:\${PATH}\""
}

# List installed Java versions
list_java() {
    if [[ ! -d "$JAVA_ROOT" ]]; then
        log_info "No Java versions installed"
        return 0
    fi
    
    log_info "Installed Java versions:"
    
    local current_java_home="${JAVA_HOME:-}"
    
    for dir in "$JAVA_ROOT"/*; do
        if [[ -d "$dir" && -f "$dir/bin/java" ]]; then
            local version=$(basename "$dir")
            if [[ "$dir" == "$current_java_home" ]]; then
                echo -e "  ${GREEN}* $version${NC} (active)"
            else
                echo "    $version"
            fi
        fi
    done
}

# Remove Java version
remove_java() {
    local version="$1"
    local install_dir="${JAVA_ROOT}/${version}"
    
    if [[ ! -d "$install_dir" ]]; then
        log_error "Java $version is not installed"
        return 1
    fi
    
    log_warn "About to remove Java $version from $install_dir"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$install_dir"
        log_success "Java $version removed"
    else
        log_info "Removal cancelled"
    fi
}
