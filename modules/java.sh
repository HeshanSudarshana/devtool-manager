#!/usr/bin/env bash

# Java/JDK management module using Eclipse Temurin

JAVA_ROOT="${DTM_ROOT}/java"

# Get the latest patch version for a major version from Temurin API
get_latest_java_version() {
    local major_version="$1"
    
    log_info "Fetching latest Java $major_version version from Temurin..." >&2
    
    # Query Temurin API for available releases (filter for JDK image type)
    local api_url="https://api.adoptium.net/v3/assets/latest/${major_version}/hotspot?image_type=jdk"
    
    # Use Python for reliable JSON parsing
    local version=$(curl -s "$api_url" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data[0]['version']['semver'].split('+')[0])" 2>/dev/null)
    
    if [[ -z "$version" ]]; then
        log_error "Could not fetch or parse version from Temurin API" >&2
        return 1
    fi
    
    echo "$version"
}

# Build download URL for Temurin JDK
get_java_download_url() {
    local version="$1"
    local major_version=$(echo "$version" | cut -d'.' -f1)
    
    # Determine OS suffix
    local os_suffix
    case "$OS" in
        linux) os_suffix="linux" ;;
        mac) os_suffix="mac" ;;
    esac
    
    # Build API query URL - try specific version first
    local api_url="https://api.adoptium.net/v3/assets/version/jdk-${version}"
    local response=$(curl -s "${api_url}?architecture=${ARCH}&image_type=jdk&os=${os_suffix}")
    
    if [[ -z "$response" || "$response" == "[]" ]]; then
        # Try with latest for major version
        api_url="https://api.adoptium.net/v3/assets/latest/${major_version}/hotspot"
        response=$(curl -s "${api_url}?architecture=${ARCH}&image_type=jdk&os=${os_suffix}")
    fi
    
    # Extract download URL using Python
    local download_url=$(echo "$response" | python3 -c "import sys, json; data = json.load(sys.stdin); print(data[0]['binary']['package']['link'])" 2>/dev/null)
    
    if [[ -z "$download_url" ]]; then
        log_error "Could not find download URL for Java $version (OS: $os_suffix, ARCH: $ARCH)" >&2
        return 1
    fi
    
    echo "$download_url"
}

# Pull (download and install) Java JDK
pull_java() {
    local version="$1"
    local exact_version=""
    
    # Check if version is just major version (e.g., "11") or full version (e.g., "11.0.21")
    if [[ "$version" =~ ^[0-9]+$ ]]; then
        log_info "Version $version is a major version, fetching latest patch version..."
        exact_version=$(get_latest_java_version "$version")
        if [[ $? -ne 0 ]]; then
            log_error "Failed to get latest version for Java $version"
            exit 1
        fi
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi
    
    # Create Java directory if it doesn't exist
    mkdir -p "$JAVA_ROOT"
    
    # Determine installation directory
    local install_dir="${JAVA_ROOT}/${exact_version}"
    
    if [[ -d "$install_dir" ]]; then
        log_warn "Java $exact_version is already installed at $install_dir"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            return 0
        fi
        rm -rf "$install_dir"
    fi
    
    # Get download URL
    local download_url=$(get_java_download_url "$exact_version")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    log_info "Downloading JDK from: $download_url"
    
    # Create temp directory for download
    local temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/jdk.tar.gz"
    
    # Download with progress
    if ! curl -L --progress-bar -o "$download_file" "$download_url"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log_info "Extracting JDK to $install_dir..."
    
    # Extract tarball
    mkdir -p "$install_dir"
    tar -xzf "$download_file" -C "$install_dir" --strip-components=1
    
    if [[ $? -ne 0 ]]; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_success "Java $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set java $exact_version' to activate this version"
}

# Set Java version as active
set_java() {
    local version="$1"
    
    # Find matching installation
    local install_dir=""
    
    # Check if exact version exists
    if [[ -d "${JAVA_ROOT}/${version}" ]]; then
        install_dir="${JAVA_ROOT}/${version}"
    else
        # Try to find latest version matching the major version
        local major_version=$(echo "$version" | cut -d'.' -f1)
        local matching_dirs=$(find "$JAVA_ROOT" -maxdepth 1 -type d -name "${major_version}.*" 2>/dev/null | sort -V | tail -1)
        
        if [[ -n "$matching_dirs" ]]; then
            install_dir="$matching_dirs"
        else
            log_error "Java $version is not installed"
            log_info "Available versions:"
            list_java
            exit 1
        fi
    fi
    
    log_info "Setting Java to $(basename $install_dir)..." >&2
    
    # Update .dtmrc configuration file
    mkdir -p "$(dirname $DTM_CONFIG)"
    
    # Remove old Java configuration
    if [[ -f "$DTM_CONFIG" ]]; then
        sed -i '/^export JAVA_HOME=/d' "$DTM_CONFIG"
        sed -i '/^export PATH=.*java.*bin/d' "$DTM_CONFIG"
    fi
    
    # Add new Java configuration
    cat >> "$DTM_CONFIG" << EOF
export JAVA_HOME="${install_dir}"
export PATH="\${JAVA_HOME}/bin:\${PATH}"
EOF
    
    log_success "Java $(basename $install_dir) activated" >&2
    
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
