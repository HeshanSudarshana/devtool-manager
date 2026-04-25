#!/usr/bin/env bash

# Python management module — native (downloads prebuilt CPython tarballs from
# astral-sh/python-build-standalone; verifies against the per-release
# SHA256SUMS).
#
# Version coverage diverges from pyenv: only CPython builds shipped in
# python-build-standalone releases are installable. No source builds.

PYTHON_ROOT="${DTM_ROOT}/python"

# Rust target triple used in PBS asset names.
_python_triple() {
    local arch_part os_part
    case "$ARCH" in
        x64)     arch_part="x86_64" ;;
        aarch64) arch_part="aarch64" ;;
    esac
    case "$OS" in
        linux) os_part="unknown-linux-gnu" ;;
        mac)   os_part="apple-darwin" ;;
    esac
    echo "${arch_part}-${os_part}"
}

_python_latest_tag() {
    curl -fsSL --retry 3 --retry-delay 2 "$DTM_PBS_LATEST" 2>/dev/null \
        | jq -r '.tag' 2>/dev/null
}

# Echo all install_only CPython versions for the current triple in a given
# PBS release tag, sorted descending (one per line).
_python_release_versions() {
    local tag="$1"
    local triple
    triple=$(_python_triple)
    curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_PBS_REPO}/releases/tags/${tag}" 2>/dev/null \
        | jq -r --arg t "$triple" '
            .assets[]?.name
            | select(startswith("cpython-"))
            | select(endswith("-" + $t + "-install_only.tar.gz"))
            | sub("^cpython-"; "")
            | sub("\\+.*$"; "")' \
        | sort -V -u -r
}

# Resolve <major[.minor[.patch]]|latest> to "<exact_version> <release_tag>".
# Searches the latest PBS release first; for explicit patch versions falls
# back to walking older releases (capped at 5 pages of GitHub API results).
_python_resolve_version() {
    local input="$1"
    local tag versions match
    tag=$(_python_latest_tag) || true
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_error "Failed to query python-build-standalone latest release" >&2
        log_info  "URL: $DTM_PBS_LATEST" >&2
        return 1
    fi
    versions=$(_python_release_versions "$tag") || true
    if [[ -z "$versions" ]]; then
        log_error "No PBS install_only builds for $(_python_triple) in $tag" >&2
        return 1
    fi

    case "$input" in
        latest)
            match=$(echo "$versions" | head -1)
            ;;
        *)
            if [[ "$input" =~ ^[0-9]+$ ]]; then
                match=$(echo "$versions" | grep -E "^${input}\\." | head -1)
            elif [[ "$input" =~ ^[0-9]+\.[0-9]+$ ]]; then
                match=$(echo "$versions" | grep -E "^${input//./\\.}\\." | head -1)
            elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                match=$(echo "$versions" | grep -Fx "$input" | head -1)
                if [[ -z "$match" ]]; then
                    # Walk older releases for the exact patch. Anonymous
                    # GitHub API; rate-limited (60/hr/IP).
                    local page tags older_tag found
                    for page in 1 2 3 4 5; do
                        tags=$(curl -fsSL --retry 3 --retry-delay 2 \
                            "${DTM_PBS_REPO}/releases?per_page=20&page=${page}" \
                            2>/dev/null | jq -r '.[].tag_name' 2>/dev/null) || break
                        [[ -z "$tags" ]] && break
                        while IFS= read -r older_tag; do
                            [[ -z "$older_tag" || "$older_tag" == "$tag" ]] && continue
                            found=$(_python_release_versions "$older_tag" \
                                | grep -Fx "$input" | head -1) || true
                            if [[ -n "$found" ]]; then
                                echo "$found $older_tag"
                                return 0
                            fi
                        done <<< "$tags"
                    done
                fi
            else
                log_error "Invalid Python version spec: $input" >&2
                log_info "Examples: 3, 3.12, 3.12.13, latest" >&2
                return 1
            fi
            ;;
    esac

    if [[ -z "$match" ]]; then
        log_error "Could not resolve Python version: $input" >&2
        log_info "Try 'dtm available python' to list installable versions" >&2
        return 1
    fi
    echo "$match $tag"
}

# Outputs two lines on success: download_url, sha256.
_python_download_info() {
    local version="$1" tag="$2"
    local triple filename url shasums checksum
    triple=$(_python_triple)
    filename="cpython-${version}+${tag}-${triple}-install_only.tar.gz"
    url="${DTM_PBS_DIST}/${tag}/${filename}"

    shasums=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_PBS_DIST}/${tag}/SHA256SUMS" 2>/dev/null) || {
        log_error "Failed to fetch SHA256SUMS for PBS release $tag" >&2
        return 1
    }
    checksum=$(echo "$shasums" | awk -v f="$filename" '$2 == f {print $1; exit}')
    if [[ -z "$checksum" ]]; then
        log_error "No sha256 entry for $filename in SHA256SUMS" >&2
        return 1
    fi

    echo "$url"
    echo "$checksum"
}

pull_python() {
    local input="$1"
    local resolved exact_version tag
    resolved=$(_python_resolve_version "$input") || exit 1
    exact_version="${resolved% *}"
    tag="${resolved##* }"

    if [[ "$input" != "$exact_version" ]]; then
        log_info "Resolved $input -> $exact_version (PBS $tag)"
    fi

    mkdir -p "$PYTHON_ROOT"

    local install_dir="${PYTHON_ROOT}/${exact_version}"
    local lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "Python $exact_version is already installed at $install_dir"
        if ! dtm_confirm "Do you want to reinstall? (y/N): "; then
            log_info "Installation cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local download_info
    download_info=$(_python_download_info "$exact_version" "$tag") || exit 1

    local download_url expected_checksum
    download_url=$(echo "$download_info" | sed -n '1p')
    expected_checksum=$(echo "$download_info" | sed -n '2p')

    log_info "Downloading Python from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/python.tar.gz"

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

    log_info "Extracting Python to $install_dir..."
    mkdir -p "$install_dir"
    if ! tar -xzf "$download_file" -C "$install_dir" --strip-components=1; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "Python $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set python $exact_version' to activate this version"
}

# Set Python version as active.
# Usage: set_python <version> [mode]   mode: set | use
set_python() {
    local version="$1"
    local mode="${2:-set}"

    local install_dir=""
    if [[ -d "${PYTHON_ROOT}/${version}" && ! -L "${PYTHON_ROOT}/${version}" ]]; then
        install_dir="${PYTHON_ROOT}/${version}"
    elif [[ "$version" =~ ^[0-9]+$ || "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        local match
        match=$(find "$PYTHON_ROOT" -maxdepth 1 -mindepth 1 -type d -name "${version}.*" 2>/dev/null \
            | sort -V | tail -1)
        [[ -n "$match" ]] && install_dir="$match"
    fi

    if [[ -z "$install_dir" ]]; then
        log_error "Python $version is not installed"
        log_info "Available versions:"
        list_python
        exit 1
    fi

    local exact_version
    exact_version=$(basename "$install_dir")

    if [[ "$mode" == "set" ]]; then
        log_info "Setting Python to $exact_version..." >&2

        mkdir -p "$(dirname "$DTM_CONFIG")"
        dtm_clean_dtmrc_for "PYTHON_HOME" "/python/.*/bin"
        dtm_set_current_symlink "$PYTHON_ROOT" "$install_dir"

        local stable_path="${PYTHON_ROOT}/current"
        cat >> "$DTM_CONFIG" << EOF
export PYTHON_HOME="${stable_path}"
export PATH="\${PYTHON_HOME}/bin:\${PATH}"
EOF

        log_success "Python $exact_version activated" >&2

        if [[ -x "${install_dir}/bin/python3" ]]; then
            echo "" >&2
            log_info "Version details:" >&2
            "${install_dir}/bin/python3" --version >&2
            if [[ -x "${install_dir}/bin/pip3" ]]; then
                log_info "pip version: $("${install_dir}/bin/pip3" --version 2>/dev/null)" >&2
            fi
            echo "" >&2
        fi

        log_info "Applying changes to current shell..." >&2

        echo "export PYTHON_HOME=\"${stable_path}\""
        echo "export PATH=\"\${PYTHON_HOME}/bin:\${PATH}\""
        return 0
    fi

    # use mode: per-shell only — emit direct install path, leave the global
    # `current` symlink alone (other shells may rely on it).
    echo "export PYTHON_HOME=\"${install_dir}\""
    echo "export PATH=\"\${PYTHON_HOME}/bin:\${PATH}\""
}

list_python() {
    if [[ ! -d "$PYTHON_ROOT" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_info "No Python versions installed"; fi
        return 0
    fi

    local current_python_home="${PYTHON_HOME:-}"
    local active_resolved=""
    [[ -n "$current_python_home" && -e "$current_python_home" ]] && \
        active_resolved="$(dtm_resolved_path "$current_python_home")"

    local dir version
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        local entries=() active
        for dir in "$PYTHON_ROOT"/*; do
            [[ -L "$dir" ]] && continue
            [[ -d "$dir" && -f "$dir/bin/python3" ]] || continue
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

    log_info "Installed Python versions:"
    for dir in "$PYTHON_ROOT"/*; do
        [[ -L "$dir" ]] && continue
        [[ -d "$dir" && -f "$dir/bin/python3" ]] || continue
        version=$(basename "$dir")
        if [[ "$dir" == "$active_resolved" ]]; then
            echo -e "  ${GREEN}* $version${NC} (active)"
        else
            echo "    $version"
        fi
    done
}

# Available remote versions (latest PBS release only).
# Usage: available_python [filter]
#   (empty)        -> all CPython versions in latest PBS release
#   <major>        -> patches in that major
#   <major.minor>  -> patches in that minor
available_python() {
    local filter="$1"
    local tag versions
    tag=$(_python_latest_tag)
    if [[ -z "$tag" || "$tag" == "null" ]]; then
        log_error "Failed to query python-build-standalone latest release" >&2
        return 1
    fi
    versions=$(_python_release_versions "$tag")
    if [[ -z "$versions" ]]; then
        log_error "No PBS install_only builds for $(_python_triple) in $tag" >&2
        return 1
    fi

    if [[ -z "$filter" ]]; then
        log_info "python-build-standalone release: $tag" >&2
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then
            echo "$versions" | dtm_json_string_array
            return 0
        fi
        log_info "Available Python versions:"
        echo "$versions" | sed 's/^/    /'
        return 0
    fi

    local matches
    if [[ "$filter" =~ ^[0-9]+$ || "$filter" =~ ^[0-9]+\.[0-9]+$ ]]; then
        matches=$(echo "$versions" | grep -E "^${filter//./\\.}\\.")
    else
        log_error "Invalid Python filter: $filter"
        log_info "Use a major (e.g. 3) or major.minor (e.g. 3.12)"
        return 1
    fi

    if [[ -z "$matches" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No matching Python versions in $tag"; fi
        return 1
    fi
    log_info "Available Python $filter versions (PBS $tag):" >&2
    echo "$matches" | dtm_emit_version_list
}

current_python() {
    local current_python_home="${PYTHON_HOME:-}"
    if [[ -z "$current_python_home" ]]; then
        log_warn "No active Python version (PYTHON_HOME not set)" >&2
        return 1
    fi
    if [[ "$current_python_home" != "$PYTHON_ROOT"/* ]]; then
        log_warn "Active PYTHON_HOME is not managed by dtm: $current_python_home" >&2
        return 1
    fi
    if [[ ! -x "$current_python_home/bin/python3" ]]; then
        log_warn "Active Python install is missing: $current_python_home" >&2
        return 1
    fi
    local resolved version
    resolved="$(dtm_resolved_path "$current_python_home")"
    version="$(basename "$resolved")"
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        jq -nc \
            --arg tool "python" \
            --arg version "$version" \
            --arg path "$resolved" \
            --arg link "$current_python_home" \
            '{tool:$tool,version:$version,path:$path,link:$link}'
        return 0
    fi
    echo "$version"
}

# Update active Python to latest patch in current major.minor series.
update_python() {
    local current major_minor latest install_dir resolved
    current=$(DTM_OUTPUT_JSON= current_python) || {
        log_error "No active Python version to update"
        exit 1
    }
    major_minor=$(echo "$current" | grep -oE '^[0-9]+\.[0-9]+')
    if [[ -z "$major_minor" ]]; then
        log_error "Cannot parse major.minor from '$current'"
        exit 1
    fi
    log_info "Active Python: $current (series $major_minor)" >&2

    resolved=$(_python_resolve_version "$major_minor") || exit 1
    latest="${resolved% *}"
    log_info "Latest Python $major_minor: $latest" >&2

    if [[ "$latest" == "$current" ]]; then
        log_success "Python $current is already the latest patch" >&2
        return 0
    fi

    install_dir="${PYTHON_ROOT}/${latest}"
    if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
        pull_python "$latest"
    else
        log_info "Python $latest already installed; switching only" >&2
    fi

    set_python "$latest" set
}

remove_python() {
    local version="$1"
    local install_dir="${PYTHON_ROOT}/${version}"

    if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
        log_error "Python $version is not installed"
        return 1
    fi

    log_warn "About to remove Python $version from $install_dir"
    if dtm_confirm "Are you sure? (y/N): "; then
        if [[ -L "${PYTHON_ROOT}/current" ]]; then
            local cur_target
            cur_target="$(dtm_resolved_path "${PYTHON_ROOT}/current" 2>/dev/null || true)"
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${PYTHON_ROOT}/current"
            fi
        fi
        rm -rf "$install_dir"
        log_success "Python $version removed"
    else
        log_info "Removal cancelled"
    fi
}
