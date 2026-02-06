#!/usr/bin/env bash

# Gradle management module

GRADLE_ROOT="${DTM_ROOT}/gradle"

# Get the latest patch version for a major.minor version from Gradle API
get_latest_gradle_version() {
    local major_minor="$1"
    
    log_info "Fetching latest Gradle $major_minor version..." >&2
    
    # Fetch all versions from Gradle API and find latest matching version
    local version=$(curl -s "https://services.gradle.org/versions/all" | python3 -c "
import sys, json
data = json.load(sys.stdin)
# Get all versions
versions = [item['version'] for item in data]
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

# Build download URL for Gradle
get_gradle_download_url() {
    local version="$1"
    
    # Gradle download URL pattern (using -bin distribution, not -all)
    local download_url="https://services.gradle.org/distributions/gradle-${version}-bin.zip"
    
    # Note: Gradle URLs return 307 redirect, so we don't need to verify
    # The API already validated the version exists
    
    echo "$download_url"
}

# Pull (download and install) Gradle
pull_gradle() {
    local version="$1"
    local exact_version=""
    
    # Check if version is just major.minor (e.g., "8.5") or full version (e.g., "8.5.1")
    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_info "Version $version is a major.minor version, fetching latest patch version..."
        exact_version=$(get_latest_gradle_version "$version")
        if [[ $? -ne 0 ]]; then
            log_error "Failed to get latest version for Gradle $version"
            exit 1
        fi
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi
    
    # Create Gradle directory if it doesn't exist
    mkdir -p "$GRADLE_ROOT"
    
    # Determine installation directory
    local install_dir="${GRADLE_ROOT}/${exact_version}"
    
    if [[ -d "$install_dir" ]]; then
        log_warn "Gradle $exact_version is already installed at $install_dir"
        read -p "Do you want to reinstall? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            return 0
        fi
        rm -rf "$install_dir"
    fi
    
    # Get download URL
    local download_url=$(get_gradle_download_url "$exact_version")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    log_info "Downloading Gradle from: $download_url"
    
    # Create temp directory for download
    local temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/gradle.zip"
    
    # Download with progress
    if ! curl -L --progress-bar -o "$download_file" "$download_url"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log_info "Extracting Gradle to $install_dir..."
    
    # Extract zip file
    mkdir -p "$install_dir"
    unzip -q "$download_file" -d "$temp_dir"
    
    if [[ $? -ne 0 ]]; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi
    
    # Move contents (gradle creates a gradle-x.x.x directory in the zip)
    mv "$temp_dir"/gradle-${exact_version}/* "$install_dir/"
    
    # Cleanup
    rm -rf "$temp_dir"
    
    log_success "Gradle $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set gradle $exact_version' to activate this version"
}

# Set Gradle version as active
set_gradle() {
    local version="$1"
    
    # Find matching installation
    local install_dir=""
    
    # Check if exact version exists
    if [[ -d "${GRADLE_ROOT}/${version}" ]]; then
        install_dir="${GRADLE_ROOT}/${version}"
    else
        # Try to find latest version matching the major.minor version
        local major_minor=$(echo "$version" | grep -o '^[0-9]\+\.[0-9]\+')
        if [[ -n "$major_minor" ]]; then
            local matching_dirs=$(find "$GRADLE_ROOT" -maxdepth 1 -type d -name "${major_minor}.*" 2>/dev/null | sort -V | tail -1)
            
            if [[ -n "$matching_dirs" ]]; then
                install_dir="$matching_dirs"
            fi
        fi
        
        if [[ -z "$install_dir" ]]; then
            log_error "Gradle $version is not installed"
            log_info "Available versions:"
            list_gradle
            exit 1
        fi
    fi
    
    log_info "Setting Gradle to $(basename $install_dir)..." >&2
    
    # Update .dtmrc configuration file
    mkdir -p "$(dirname $DTM_CONFIG)"
    
    # Remove old Gradle configuration
    if [[ -f "$DTM_CONFIG" ]]; then
        sed -i '/^export GRADLE_HOME=/d' "$DTM_CONFIG"
        sed -i '/^export PATH=.*gradle.*bin/d' "$DTM_CONFIG"
    fi
    
    # Add new Gradle configuration
    cat >> "$DTM_CONFIG" << EOF
export GRADLE_HOME="${install_dir}"
export PATH="\${GRADLE_HOME}/bin:\${PATH}"
EOF
    
    log_success "Gradle $(basename $install_dir) activated" >&2
    
    # Show current Gradle version
    if [[ -f "${install_dir}/bin/gradle" ]]; then
        echo "" >&2
        log_info "Version details:" >&2
        "${install_dir}/bin/gradle" --version 2>&1 | head -5 >&2
        echo "" >&2
    fi
    
    log_info "Applying changes to current shell..." >&2
    
    # Output the export commands to stdout (plain text, no colors)
    echo "export GRADLE_HOME=\"${install_dir}\""
    echo "export PATH=\"\${GRADLE_HOME}/bin:\${PATH}\""
}

# List installed Gradle versions
list_gradle() {
    if [[ ! -d "$GRADLE_ROOT" ]]; then
        log_info "No Gradle versions installed"
        return 0
    fi
    
    log_info "Installed Gradle versions:"
    
    local current_gradle_home="${GRADLE_HOME:-}"
    
    for dir in "$GRADLE_ROOT"/*; do
        if [[ -d "$dir" && -f "$dir/bin/gradle" ]]; then
            local version=$(basename "$dir")
            if [[ "$dir" == "$current_gradle_home" ]]; then
                echo -e "  ${GREEN}* $version${NC} (active)"
            else
                echo "    $version"
            fi
        fi
    done
}

# Remove Gradle version
remove_gradle() {
    local version="$1"
    local install_dir="${GRADLE_ROOT}/${version}"
    
    if [[ ! -d "$install_dir" ]]; then
        log_error "Gradle $version is not installed"
        return 1
    fi
    
    log_warn "About to remove Gradle $version from $install_dir"
    read -p "Are you sure? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$install_dir"
        log_success "Gradle $version removed"
    else
        log_info "Removal cancelled"
    fi
}
