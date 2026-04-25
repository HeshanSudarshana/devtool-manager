#!/usr/bin/env bash

# Maven management module

MAVEN_ROOT="${DTM_ROOT}/maven"

# Get the latest Maven version from Apache
get_latest_maven_version() {
    log_info "Fetching latest Maven version..." >&2

    local metadata_url="${DTM_MAVEN_REPO}/org/apache/maven/apache-maven/maven-metadata.xml"
    local version
    version=$(curl -fsSL --retry 3 --retry-delay 2 "$metadata_url" 2>/dev/null \
        | grep -o '<latest>[^<]*</latest>' | sed 's/<[^>]*>//g')

    if [[ -z "$version" ]]; then
        log_error "Could not fetch latest Maven version" >&2
        return 1
    fi

    echo "$version"
}

# Build download URL for Maven
get_maven_download_url() {
    local version="$1"

    local download_url="${DTM_MAVEN_DIST}/maven-3/${version}/binaries/apache-maven-${version}-bin.tar.gz"

    if ! dtm_url_exists "$download_url"; then
        log_error "Could not find download URL for Maven $version" >&2
        return 1
    fi

    echo "$download_url"
}

# Pull (download and install) Maven
pull_maven() {
    local version="$1"
    local exact_version=""

    if [[ "$version" == "latest" ]]; then
        exact_version=$(get_latest_maven_version) || {
            log_error "Failed to get latest Maven version"
            exit 1
        }
        log_info "Latest version found: $exact_version"
    else
        exact_version="$version"
    fi

    mkdir -p "$MAVEN_ROOT"

    local install_dir="${MAVEN_ROOT}/${exact_version}"
    local lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "Maven $exact_version is already installed at $install_dir"
        if ! dtm_confirm "Do you want to reinstall? (y/N): "; then
            log_info "Installation cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local download_url
    download_url=$(get_maven_download_url "$exact_version") || exit 1

    log_info "Downloading Maven from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/maven.tar.gz"

    if ! dtm_download "$download_url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Fetching checksum..."
    local expected_checksum
    expected_checksum=$(fetch_checksum_from_url "${download_url}.sha512")
    if [[ -z "$expected_checksum" ]]; then
        log_error "Failed to fetch checksum from ${download_url}.sha512"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Verifying checksum (sha512)..."
    if ! verify_checksum "$download_file" "$expected_checksum" sha512; then
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Extracting Maven to $install_dir..."
    mkdir -p "$install_dir"
    if ! tar -xzf "$download_file" -C "$install_dir" --strip-components=1; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "Maven $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set maven $exact_version' to activate this version"
}

# Set Maven version as active
# Usage: set_maven <version> [mode]
#   mode: "set" (default) writes ~/.dtmrc; "use" applies to current shell only.
set_maven() {
    local version="$1"
    local mode="${2:-set}"

    # Find matching installation. Skip the `current` symlink when a version
    # literally equal to "current" is requested? In practice, Maven versions
    # are dotted, so the symlink can't collide.
    local install_dir=""

    if [[ -d "${MAVEN_ROOT}/${version}" && ! -L "${MAVEN_ROOT}/${version}" ]]; then
        install_dir="${MAVEN_ROOT}/${version}"
    else
        local matching_dirs
        matching_dirs=$(find "$MAVEN_ROOT" -maxdepth 1 -type d -name "${version}*" 2>/dev/null | sort -V | tail -1)

        if [[ -n "$matching_dirs" ]]; then
            install_dir="$matching_dirs"
        else
            log_error "Maven $version is not installed"
            log_info "Available versions:"
            list_maven
            exit 1
        fi
    fi

    if [[ "$mode" == "set" ]]; then
        log_info "Setting Maven to $(basename "$install_dir")..." >&2

        mkdir -p "$(dirname "$DTM_CONFIG")"
        dtm_clean_dtmrc_for "MAVEN_HOME" "/maven/.*/bin"
        dtm_clean_dtmrc_for "M2_HOME"
        dtm_set_current_symlink "$MAVEN_ROOT" "$install_dir"

        local stable_path="${MAVEN_ROOT}/current"
        cat >> "$DTM_CONFIG" << EOF
export MAVEN_HOME="${stable_path}"
export M2_HOME="${stable_path}"
export PATH="\${MAVEN_HOME}/bin:\${PATH}"
EOF

        log_success "Maven $(basename "$install_dir") activated" >&2

        if [[ -f "${install_dir}/bin/mvn" ]]; then
            echo "" >&2
            log_info "Version details:" >&2
            "${install_dir}/bin/mvn" --version 2>&1 | head -3 >&2
            echo "" >&2
        fi

        log_info "Applying changes to current shell..." >&2

        echo "export MAVEN_HOME=\"${stable_path}\""
        echo "export M2_HOME=\"${stable_path}\""
        echo "export PATH=\"\${MAVEN_HOME}/bin:\${PATH}\""
        return 0
    fi

    # `use` mode: per-shell only — direct path, leave the symlink alone.
    echo "export MAVEN_HOME=\"${install_dir}\""
    echo "export M2_HOME=\"${install_dir}\""
    echo "export PATH=\"\${MAVEN_HOME}/bin:\${PATH}\""
}

# List installed Maven versions
list_maven() {
    if [[ ! -d "$MAVEN_ROOT" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_info "No Maven versions installed"; fi
        return 0
    fi

    local current_maven_home="${MAVEN_HOME:-}"
    local active_resolved=""
    [[ -n "$current_maven_home" && -e "$current_maven_home" ]] && \
        active_resolved="$(dtm_resolved_path "$current_maven_home")"

    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        local entries=()
        local dir version active
        for dir in "$MAVEN_ROOT"/*; do
            [[ -L "$dir" ]] && continue
            [[ -d "$dir" && -f "$dir/bin/mvn" ]] || continue
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

    log_info "Installed Maven versions:"
    for dir in "$MAVEN_ROOT"/*; do
        [[ -L "$dir" ]] && continue
        if [[ -d "$dir" && -f "$dir/bin/mvn" ]]; then
            local version=$(basename "$dir")
            if [[ "$dir" == "$active_resolved" ]]; then
                echo -e "  ${GREEN}* $version${NC} (active)"
            else
                echo "    $version"
            fi
        fi
    done
}

# List available Maven versions from Apache.
# Usage: available_maven [major_or_prefix]
#   No arg     -> list recent releases (last 20).
#   <prefix>   -> list all matching versions starting with that prefix
#                 (e.g. "3" -> all 3.x, "3.9" -> all 3.9.x).
available_maven() {
    local filter="$1"
    local metadata_url="${DTM_MAVEN_REPO}/org/apache/maven/apache-maven/maven-metadata.xml"

    log_info "Fetching available Maven versions..." >&2
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$metadata_url" 2>/dev/null) || {
        log_error "Failed to query Maven metadata" >&2
        return 1
    }

    local versions
    versions=$(echo "$response" \
        | grep -o '<version>[^<]*</version>' \
        | sed 's/<[^>]*>//g' \
        | grep -v -- '-' \
        | sort -V -u)

    if [[ -z "$versions" ]]; then
        log_error "No Maven versions parsed from metadata" >&2
        return 1
    fi

    if [[ -n "$filter" ]]; then
        local matched
        matched=$(echo "$versions" | grep -E "^${filter//./\\.}(\$|\\.)" || true)
        if [[ -z "$matched" ]]; then
            if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No Maven versions matching '$filter'"; fi
            return 1
        fi
        log_info "Available Maven versions matching '$filter':"
        echo "$matched" | dtm_emit_version_list
    else
        log_info "Available Maven versions (most recent 20; pass a prefix to filter):"
        echo "$versions" | tail -20 | dtm_emit_version_list
    fi
}

# Print currently active Maven version (or fail if none)
current_maven() {
    local current_maven_home="${MAVEN_HOME:-}"
    if [[ -z "$current_maven_home" ]]; then
        log_warn "No active Maven version (MAVEN_HOME not set)" >&2
        return 1
    fi
    if [[ "$current_maven_home" != "$MAVEN_ROOT"/* ]]; then
        log_warn "Active MAVEN_HOME is not managed by dtm: $current_maven_home" >&2
        return 1
    fi
    if [[ ! -x "$current_maven_home/bin/mvn" ]]; then
        log_warn "Active Maven install is missing: $current_maven_home" >&2
        return 1
    fi
    local resolved version
    resolved="$(dtm_resolved_path "$current_maven_home")"
    version="$(basename "$resolved")"
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        jq -nc \
            --arg tool "maven" \
            --arg version "$version" \
            --arg path "$resolved" \
            --arg link "$current_maven_home" \
            '{tool:$tool,version:$version,path:$path,link:$link}'
        return 0
    fi
    echo "$version"
}

# Get latest Maven version matching a prefix (e.g. "3.9" -> latest 3.9.x).
get_latest_maven_for_prefix() {
    local prefix="$1"
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_MAVEN_REPO}/org/apache/maven/apache-maven/maven-metadata.xml" 2>/dev/null) || {
        log_error "Failed to query Maven metadata" >&2
        return 1
    }
    local latest
    latest=$(echo "$response" \
        | grep -o '<version>[^<]*</version>' \
        | sed 's/<[^>]*>//g' \
        | grep -v -- '-' \
        | grep -E "^${prefix//./\\.}\\." \
        | sort -V \
        | tail -1)
    if [[ -z "$latest" ]]; then
        log_error "No Maven version found for prefix '$prefix'" >&2
        return 1
    fi
    echo "$latest"
}

# Update active Maven to latest patch in current major.minor series.
update_maven() {
    local current major_minor latest install_dir
    # current_maven would emit JSON in --json mode; we want the raw version
    # name here for parsing. Run it without JSON.
    current=$(DTM_OUTPUT_JSON= current_maven) || {
        log_error "No active Maven version to update"
        exit 1
    }
    major_minor=$(echo "$current" | grep -oE '^[0-9]+\.[0-9]+')
    if [[ -z "$major_minor" ]]; then
        log_error "Cannot parse major.minor from '$current'"
        exit 1
    fi
    log_info "Active Maven: $current (series $major_minor)" >&2

    latest=$(get_latest_maven_for_prefix "$major_minor") || exit 1
    log_info "Latest Maven $major_minor: $latest" >&2

    if [[ "$latest" == "$current" ]]; then
        log_success "Maven $current is already the latest patch" >&2
        return 0
    fi

    install_dir="${MAVEN_ROOT}/${latest}"
    if [[ ! -d "$install_dir" ]]; then
        pull_maven "$latest"
    else
        log_info "Maven $latest already installed; switching only" >&2
    fi

    set_maven "$latest" set
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
    if dtm_confirm "Are you sure? (y/N): "; then
        if [[ -L "${MAVEN_ROOT}/current" ]]; then
            local cur_target
            cur_target="$(dtm_resolved_path "${MAVEN_ROOT}/current" 2>/dev/null || true)"
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${MAVEN_ROOT}/current"
            fi
        fi
        rm -rf "$install_dir"
        log_success "Maven $version removed"
    else
        log_info "Removal cancelled"
    fi
}
