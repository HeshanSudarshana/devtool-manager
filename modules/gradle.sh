#!/usr/bin/env bash

# Gradle management module

GRADLE_ROOT="${DTM_ROOT}/gradle"

# Get the latest patch version for a major.minor version from Gradle API
get_latest_gradle_version() {
    local major_minor="$1"

    log_info "Fetching latest Gradle $major_minor version..." >&2

    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "${DTM_GRADLE_DIST}/versions/all" 2>/dev/null) || {
        log_error "Failed to query Gradle versions API" >&2
        return 1
    }

    local version
    version=$(echo "$response" \
        | jq -r '.[].version' 2>/dev/null \
        | grep -E "^${major_minor}\." \
        | sort -V \
        | tail -1)

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
    local download_url="${DTM_GRADLE_DIST}/distributions/gradle-${version}-bin.zip"
    
    # Note: Gradle URLs return 307 redirect, so we don't need to verify
    # The API already validated the version exists
    
    echo "$download_url"
}

# Pull (download and install) Gradle
pull_gradle() {
    local version="$1"
    local exact_version=""

    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_info "Version $version is a major.minor version, fetching latest patch version..."
        exact_version=$(get_latest_gradle_version "$version") || {
            log_error "Failed to get latest version for Gradle $version"
            exit 1
        }
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi

    mkdir -p "$GRADLE_ROOT"

    local install_dir="${GRADLE_ROOT}/${exact_version}"
    local lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "Gradle $exact_version is already installed at $install_dir"
        if ! dtm_confirm "Do you want to reinstall? (y/N): "; then
            log_info "Installation cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local download_url
    download_url=$(get_gradle_download_url "$exact_version") || exit 1

    log_info "Downloading Gradle from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/gradle.zip"

    if ! dtm_download "$download_url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Fetching checksum..."
    local expected_checksum
    expected_checksum=$(fetch_checksum_from_url "${download_url}.sha256")
    if [[ -z "$expected_checksum" ]]; then
        log_error "Failed to fetch checksum from ${download_url}.sha256"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Verifying checksum (sha256)..."
    if ! verify_checksum "$download_file" "$expected_checksum" sha256; then
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Extracting Gradle to $install_dir..."
    mkdir -p "$install_dir"
    if ! unzip -q "$download_file" -d "$temp_dir"; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    if ! mv "$temp_dir"/gradle-${exact_version}/* "$install_dir/"; then
        log_error "Failed to move extracted Gradle into $install_dir"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "Gradle $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set gradle $exact_version' to activate this version"
}

# Set Gradle version as active
# Usage: set_gradle <version> [mode]
#   mode: "set" (default) writes ~/.dtmrc; "use" applies to current shell only.
set_gradle() {
    local version="$1"
    local mode="${2:-set}"

    # Find matching installation
    local install_dir=""

    if [[ -d "${GRADLE_ROOT}/${version}" && ! -L "${GRADLE_ROOT}/${version}" ]]; then
        install_dir="${GRADLE_ROOT}/${version}"
    else
        local major_minor matching_dirs
        major_minor=$(echo "$version" | grep -o '^[0-9]\+\.[0-9]\+')
        if [[ -n "$major_minor" ]]; then
            matching_dirs=$(find "$GRADLE_ROOT" -maxdepth 1 -type d -name "${major_minor}.*" 2>/dev/null | sort -V | tail -1)

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

    if [[ "$mode" == "set" ]]; then
        log_info "Setting Gradle to $(basename "$install_dir")..." >&2

        mkdir -p "$(dirname "$DTM_CONFIG")"
        dtm_clean_dtmrc_for "GRADLE_HOME" "/gradle/.*/bin"
        dtm_set_current_symlink "$GRADLE_ROOT" "$install_dir"

        local stable_path="${GRADLE_ROOT}/current"
        cat >> "$DTM_CONFIG" << EOF
export GRADLE_HOME="${stable_path}"
export PATH="\${GRADLE_HOME}/bin:\${PATH}"
EOF

        log_success "Gradle $(basename "$install_dir") activated" >&2

        if [[ -f "${install_dir}/bin/gradle" ]]; then
            echo "" >&2
            log_info "Version details:" >&2
            "${install_dir}/bin/gradle" --version 2>&1 | head -5 >&2
            echo "" >&2
        fi

        log_info "Applying changes to current shell..." >&2

        echo "export GRADLE_HOME=\"${stable_path}\""
        echo "export PATH=\"\${GRADLE_HOME}/bin:\${PATH}\""
        return 0
    fi

    # `use` mode: per-shell only — direct path, leave the symlink alone.
    echo "export GRADLE_HOME=\"${install_dir}\""
    echo "export PATH=\"\${GRADLE_HOME}/bin:\${PATH}\""
}

# List installed Gradle versions
list_gradle() {
    if [[ ! -d "$GRADLE_ROOT" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_info "No Gradle versions installed"; fi
        return 0
    fi

    local current_gradle_home="${GRADLE_HOME:-}"
    local active_resolved=""
    [[ -n "$current_gradle_home" && -e "$current_gradle_home" ]] && \
        active_resolved="$(dtm_resolved_path "$current_gradle_home")"

    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        local entries=()
        local dir version active
        for dir in "$GRADLE_ROOT"/*; do
            [[ -L "$dir" ]] && continue
            [[ -d "$dir" && -f "$dir/bin/gradle" ]] || continue
            version=$(basename "$dir")
            active=false
            [[ "$dir" == "$active_resolved" ]] && active=true
            entries+=("$(jq -nc \
                --arg version "$version" \
                --arg path "$dir" \
                --argjson active "$active" \
                '{version:$version,path:$path,active:$active}')")
        done
        if (( ${#entries[@]} == 0 )); then echo "[]"; else printf '%s\n' "${entries[@]}" | jq -s .; fi
        return 0
    fi

    log_info "Installed Gradle versions:"
    for dir in "$GRADLE_ROOT"/*; do
        [[ -L "$dir" ]] && continue
        if [[ -d "$dir" && -f "$dir/bin/gradle" ]]; then
            local version=$(basename "$dir")
            if [[ "$dir" == "$active_resolved" ]]; then
                echo -e "  ${GREEN}* $version${NC} (active)"
            else
                echo "    $version"
            fi
        fi
    done
}

# List available Gradle versions from services.gradle.org.
# Usage: available_gradle [major_or_major_minor]
#   No arg     -> list recent stable releases (last 20).
#   <prefix>   -> list all stable versions starting with that prefix
#                 (e.g. "8" or "8.5").
available_gradle() {
    local filter="$1"

    log_info "Fetching available Gradle versions..." >&2
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_GRADLE_DIST}/versions/all" 2>/dev/null) || {
        log_error "Failed to query Gradle versions API" >&2
        return 1
    }

    local versions
    versions=$(echo "$response" \
        | jq -r '.[] | select(.snapshot==false and .nightly==false and .broken==false and .rcFor=="" and .milestoneFor=="") | .version' \
        2>/dev/null \
        | sort -V -u)

    if [[ -z "$versions" ]]; then
        log_error "No Gradle versions parsed from API" >&2
        return 1
    fi

    if [[ -n "$filter" ]]; then
        local matched
        matched=$(echo "$versions" | grep -E "^${filter//./\\.}(\$|\\.)" || true)
        if [[ -z "$matched" ]]; then
            if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No Gradle versions matching '$filter'"; fi
            return 1
        fi
        log_info "Available Gradle versions matching '$filter':"
        echo "$matched" | dtm_emit_version_list
    else
        log_info "Available Gradle versions (most recent 20; pass a prefix to filter):"
        echo "$versions" | tail -20 | dtm_emit_version_list
    fi
}

# Print currently active Gradle version (or fail if none)
current_gradle() {
    local current_gradle_home="${GRADLE_HOME:-}"
    if [[ -z "$current_gradle_home" ]]; then
        log_warn "No active Gradle version (GRADLE_HOME not set)" >&2
        return 1
    fi
    if [[ "$current_gradle_home" != "$GRADLE_ROOT"/* ]]; then
        log_warn "Active GRADLE_HOME is not managed by dtm: $current_gradle_home" >&2
        return 1
    fi
    if [[ ! -x "$current_gradle_home/bin/gradle" ]]; then
        log_warn "Active Gradle install is missing: $current_gradle_home" >&2
        return 1
    fi
    local resolved version
    resolved="$(dtm_resolved_path "$current_gradle_home")"
    version="$(basename "$resolved")"
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        jq -nc \
            --arg tool "gradle" \
            --arg version "$version" \
            --arg path "$resolved" \
            --arg link "$current_gradle_home" \
            '{tool:$tool,version:$version,path:$path,link:$link}'
        return 0
    fi
    echo "$version"
}

# Update active Gradle to latest patch in current major.minor series.
update_gradle() {
    local current major_minor latest install_dir
    current=$(DTM_OUTPUT_JSON= current_gradle) || {
        log_error "No active Gradle version to update"
        exit 1
    }
    major_minor=$(echo "$current" | grep -oE '^[0-9]+\.[0-9]+')
    if [[ -z "$major_minor" ]]; then
        log_error "Cannot parse major.minor from '$current'"
        exit 1
    fi
    log_info "Active Gradle: $current (series $major_minor)" >&2

    latest=$(get_latest_gradle_version "$major_minor") || exit 1
    log_info "Latest Gradle $major_minor: $latest" >&2

    if [[ "$latest" == "$current" ]]; then
        log_success "Gradle $current is already the latest patch" >&2
        return 0
    fi

    install_dir="${GRADLE_ROOT}/${latest}"
    if [[ ! -d "$install_dir" ]]; then
        pull_gradle "$latest"
    else
        log_info "Gradle $latest already installed; switching only" >&2
    fi

    set_gradle "$latest" set
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
    if dtm_confirm "Are you sure? (y/N): "; then
        if [[ -L "${GRADLE_ROOT}/current" ]]; then
            local cur_target
            cur_target="$(dtm_resolved_path "${GRADLE_ROOT}/current" 2>/dev/null || true)"
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${GRADLE_ROOT}/current"
            fi
        fi
        rm -rf "$install_dir"
        log_success "Gradle $version removed"
    else
        log_info "Removal cancelled"
    fi
}
