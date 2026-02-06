#!/usr/bin/env bash

# Maven management module

MAVEN_ROOT="${DTM_ROOT}/maven"

# Get the latest Maven version from Apache
get_latest_maven_version() {
    log_info "Fetching latest Maven version..." >&2
    
    # Query Maven metadata for latest version
    local metadata_url="https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml"
    local version=$(curl -s "$metadata_url" | grep -o '<latest>[^<]*</latest>' | sed 's/<[^>]*>//g')
    
    if [[ -z "$version" ]]; then
        log_error "Could not fetch latest Maven version" >&2
        return 1
    fi
    
    echo "$version"
}

# Build download URL for Maven
get_maven_download_url() {
    local version="$1"
    
    # Maven download URL pattern
    local download_url="https://archive.apache.org/dist/maven/maven-3/${version}/binaries/apache-maven-${version}-bin.tar.gz"
    
    # Verify URL exists
    if ! curl -sI "$download_url" | grep -q "200 OK"; then
        log_error "Could not find download URL for Maven $version" >&2
        return 1
    fi
    
    echo "$download_url"
}

# Pull (download and install) Maven
pull_maven() {
    local version="$1"
    local exact_version=""
    
    # Check if version is "latest" or a specific version
    if [[ "$version" == "latest" ]]; then
        exact_version=$(get_latest_maven_version)
        if [[ $? -ne 0 ]]; then
            log_error "Failed to get latest Maven version"
            exit 1
        fi
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi
    
    # Create Maven directory if it doesn't exist
    mkdir -p "$MAVEN_ROOT"
    
    # Determine installation directory
    local install_dir="${MAVEN_ROOT}/${exact_version}"
    
    if [[ -d "$install_dir" ]]; then
        log_warn "Maven $exact_version is already installed at $install_dir"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            return 0
        fi
        rm -rf "$install_dir"
    fi
    
    # Get download URL
    local download_url=$(get_maven_download_url "$exact_version")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    log_info "Downloading Maven from: $download_url"
    
    # Create temp directory for download
    local temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/maven.tar.gz"
    
    # Download with progress
    if ! curl -L --progress-bar -o "$download_file" "$download_url"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log_info "Extracting Maven to $install_dir..."
    
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
    
    log_success "Maven $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set maven $exact_version' to activate this version"
}

# Set Maven version as active
set_maven() {
    local version="$1"
    
    # Find matching installation
    local install_dir=""
    
    # Check if exact version exists
    if [[ -d "${MAVEN_ROOT}/${version}" ]]; then
        install_dir="${MAVEN_ROOT}/${version}"
    else
        # Try to find latest version matching the pattern
        local matching_dirs=$(find "$MAVEN_ROOT" -maxdepth 1 -type d -name "${version}*" 2>/dev/null | sort -V | tail -1)
        
        if [[ -n "$matching_dirs" ]]; then
            install_dir="$matching_dirs"
        else
            log_error "Maven $version is not installed"
            log_info "Available versions:"
            list_maven
            exit 1
        fi
    fi
    
    log_info "Setting Maven to $(basename $install_dir)..." >&2
    
    # Update .dtmrc configuration file
    mkdir -p "$(dirname $DTM_CONFIG)"
    
    # Remove old Maven configuration
    if [[ -f "$DTM_CONFIG" ]]; then
        sed -i '/^export MAVEN_HOME=/d' "$DTM_CONFIG"
        sed -i '/^export M2_HOME=/d' "$DTM_CONFIG"
        sed -i '/^export PATH=.*maven.*bin/d' "$DTM_CONFIG"
    fi
    
    # Add new Maven configuration
    cat >> "$DTM_CONFIG" << EOF
export MAVEN_HOME="${install_dir}"
export M2_HOME="${install_dir}"
export PATH="\${MAVEN_HOME}/bin:\${PATH}"
EOF
    
    log_success "Maven $(basename $install_dir) activated" >&2
    
    # Show current Maven version
    if [[ -f "${install_dir}/bin/mvn" ]]; then
        echo "" >&2
        log_info "Version details:" >&2
        "${install_dir}/bin/mvn" --version 2>&1 | head -3 >&2
        echo "" >&2
    fi
    
    log_info "Applying changes to current shell..." >&2
    
    # Output the export commands to stdout (plain text, no colors)
    echo "export MAVEN_HOME=\"${install_dir}\""
    echo "export M2_HOME=\"${install_dir}\""
    echo "export PATH=\"\${MAVEN_HOME}/bin:\${PATH}\""
}

# List installed Maven versions
list_maven() {
    if [[ ! -d "$MAVEN_ROOT" ]]; then
        log_info "No Maven versions installed"
        return 0
    fi
    
    log_info "Installed Maven versions:"
    
    local current_maven_home="${MAVEN_HOME:-}"
    
    for dir in "$MAVEN_ROOT"/*; do
        if [[ -d "$dir" && -f "$dir/bin/mvn" ]]; then
            local version=$(basename "$dir")
            if [[ "$dir" == "$current_maven_home" ]]; then
                echo -e "  ${GREEN}* $version${NC} (active)"
            else
                echo "    $version"
            fi
        fi
    done
}

# Remove Maven version
remove_maven() {
    local version="$1"
    local install_dir="${MAVEN_ROOT}/${version}"
    
    if [[ ! -d "$install_dir" ]]; then
        log_error "Maven $version is not installed"
        return 1
    fi
    
    log_warn "About to remove Maven $version from $install_dir"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$install_dir"
        log_success "Maven $version removed"
    else
        log_info "Removal cancelled"
    fi
}
