#!/usr/bin/env bash

# Node.js management module — native (downloads prebuilt tarballs from
# nodejs.org/dist; verifies against the per-release SHASUMS256.txt).

NODE_ROOT="${DTM_ROOT}/node"

# OS token used in tarball filenames (linux | darwin).
_node_os() {
    case "$OS" in
        linux) echo "linux" ;;
        mac)   echo "darwin" ;;
    esac
}

# OS token used in index.json `files[]` entries (linux | osx).
_node_os_index_key() {
    case "$OS" in
        linux) echo "linux" ;;
        mac)   echo "osx" ;;
    esac
}

_node_arch() {
    # ARCH is set globally by detect_platform() in dtm.
    # shellcheck disable=SC2153
    case "$ARCH" in
        x64)     echo "x64" ;;
        aarch64) echo "arm64" ;;
    esac
}

_node_fetch_index() {
    curl -fsSL --retry 3 --retry-delay 2 "${DTM_NODE_DIST}/index.json" 2>/dev/null
}

# Resolve a version spec to an exact semver (e.g. "22.5.1").
# Spec: <major> | <major>.<minor> | <major>.<minor>.<patch> | lts | latest
_node_resolve_version() {
    local input="$1"
    local response
    response=$(_node_fetch_index) || {
        log_error "Failed to query Node release index (${DTM_NODE_DIST}/index.json)" >&2
        return 1
    }

    local version
    case "$input" in
        lts)
            version=$(echo "$response" \
                | jq -r '[.[] | select(.lts != false)] | .[0].version' 2>/dev/null)
            ;;
        latest)
            version=$(echo "$response" | jq -r '.[0].version' 2>/dev/null)
            ;;
        *)
            if [[ "$input" =~ ^[0-9]+$ || "$input" =~ ^[0-9]+\.[0-9]+$ ]]; then
                version=$(echo "$response" \
                    | jq -r --arg p "v${input}." \
                        '[.[] | select(.version | startswith($p))] | .[0].version' 2>/dev/null)
            elif [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                version=$(echo "$response" \
                    | jq -r --arg v "v${input}" \
                        '[.[] | select(.version == $v)] | .[0].version' 2>/dev/null)
            else
                log_error "Invalid Node version spec: $input" >&2
                log_info "Examples: 22, 22.5, 22.5.1, lts, latest" >&2
                return 1
            fi
            ;;
    esac

    if [[ -z "$version" || "$version" == "null" ]]; then
        log_error "Could not resolve Node version: $input" >&2
        return 1
    fi
    echo "${version#v}"
}

# Outputs two lines on success: download_url, sha256.
_node_download_info() {
    local version="$1"
    local os arch index_key filename url
    os=$(_node_os)
    arch=$(_node_arch)
    index_key="$(_node_os_index_key)-${arch}"
    [[ "$os" == "darwin" ]] && index_key="${index_key}-tar"
    filename="node-v${version}-${os}-${arch}.tar.xz"
    url="${DTM_NODE_DIST}/v${version}/${filename}"

    local response has
    response=$(_node_fetch_index) || return 1
    has=$(echo "$response" \
        | jq -r --arg v "v${version}" --arg k "$index_key" \
            '.[] | select(.version == $v) | .files | index($k)' 2>/dev/null)
    if [[ -z "$has" || "$has" == "null" ]]; then
        log_error "Node $version has no release for ${os}-${arch}" >&2
        return 1
    fi

    local shasums checksum
    shasums=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_NODE_DIST}/v${version}/SHASUMS256.txt" 2>/dev/null) || {
        log_error "Failed to fetch SHASUMS256.txt for Node $version" >&2
        return 1
    }
    checksum=$(echo "$shasums" | awk -v f="$filename" '$2 == f {print $1; exit}')
    if [[ -z "$checksum" ]]; then
        log_error "No sha256 entry for $filename in SHASUMS256.txt" >&2
        return 1
    fi

    echo "$url"
    echo "$checksum"
}

pull_node() {
    local input="$1"
    local exact_version
    exact_version=$(_node_resolve_version "$input") || exit 1

    if [[ "$input" != "$exact_version" ]]; then
        log_info "Resolved $input -> $exact_version"
    fi

    mkdir -p "$NODE_ROOT"

    local install_dir="${NODE_ROOT}/${exact_version}"
    local lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "Node $exact_version is already installed at $install_dir"
        if ! dtm_confirm "Do you want to reinstall? (y/N): "; then
            log_info "Installation cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local download_info
    download_info=$(_node_download_info "$exact_version") || exit 1

    local download_url expected_checksum
    download_url=$(echo "$download_info" | sed -n '1p')
    expected_checksum=$(echo "$download_info" | sed -n '2p')

    log_info "Downloading Node from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/node.tar.xz"

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

    log_info "Extracting Node to $install_dir..."
    mkdir -p "$install_dir"
    if ! tar -xJf "$download_file" -C "$install_dir" --strip-components=1; then
        log_error "Extraction failed (tar may need xz support)"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "Node $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set node $exact_version' to activate this version"
}

# Set Node.js version as active.
# Usage: set_node <version> [mode]   mode: set | use
set_node() {
    local version="$1"
    local mode="${2:-set}"

    local install_dir=""
    if [[ -d "${NODE_ROOT}/${version}" && ! -L "${NODE_ROOT}/${version}" ]]; then
        install_dir="${NODE_ROOT}/${version}"
    elif [[ "$version" =~ ^[0-9]+$ || "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        local match
        match=$(find "$NODE_ROOT" -maxdepth 1 -mindepth 1 -type d -name "${version}.*" 2>/dev/null \
            | sort -V | tail -1)
        [[ -n "$match" ]] && install_dir="$match"
    fi

    if [[ -z "$install_dir" ]]; then
        log_error "Node $version is not installed"
        log_info "Available versions:"
        list_node
        exit 1
    fi

    local exact_version
    exact_version=$(basename "$install_dir")

    if [[ "$mode" == "set" ]]; then
        log_info "Setting Node to $exact_version..." >&2

        mkdir -p "$(dirname "$DTM_CONFIG")"
        dtm_clean_dtmrc_for "NODE_HOME" "/node/.*/bin"
        dtm_set_current_symlink "$NODE_ROOT" "$install_dir"

        local stable_path="${NODE_ROOT}/current"
        cat >> "$DTM_CONFIG" << EOF
export NODE_HOME="${stable_path}"
export PATH="\${NODE_HOME}/bin:\${PATH}"
EOF

        log_success "Node $exact_version activated" >&2

        if [[ -x "${install_dir}/bin/node" ]]; then
            echo "" >&2
            log_info "Version details:" >&2
            "${install_dir}/bin/node" --version >&2
            if [[ -x "${install_dir}/bin/npm" ]]; then
                log_info "npm version: $("${install_dir}/bin/npm" --version 2>/dev/null)" >&2
            fi
            echo "" >&2
        fi

        log_info "Applying changes to current shell..." >&2

        echo "export NODE_HOME=\"${stable_path}\""
        echo "export PATH=\"\${NODE_HOME}/bin:\${PATH}\""
        return 0
    fi

    # use mode: per-shell only — emit direct install path, leave the global
    # `current` symlink alone (other shells may rely on it).
    echo "export NODE_HOME=\"${install_dir}\""
    echo "export PATH=\"\${NODE_HOME}/bin:\${PATH}\""
}

list_node() {
    if [[ ! -d "$NODE_ROOT" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_info "No Node versions installed"; fi
        return 0
    fi

    local current_node_home="${NODE_HOME:-}"
    local active_resolved=""
    [[ -n "$current_node_home" && -e "$current_node_home" ]] && \
        active_resolved="$(dtm_resolved_path "$current_node_home")"

    local dir version
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        local entries=() active
        for dir in "$NODE_ROOT"/*; do
            [[ -L "$dir" ]] && continue
            [[ -d "$dir" && -f "$dir/bin/node" ]] || continue
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

    log_info "Installed Node versions:"
    for dir in "$NODE_ROOT"/*; do
        [[ -L "$dir" ]] && continue
        [[ -d "$dir" && -f "$dir/bin/node" ]] || continue
        version=$(basename "$dir")
        if [[ "$dir" == "$active_resolved" ]]; then
            echo -e "  ${GREEN}* $version${NC} (active)"
        else
            echo "    $version"
        fi
    done
}

# Available remote versions.
# Usage: available_node [filter]
#   filter forms:
#     (empty)        -> majors with LTS marker
#     <major>        -> patches in that major
#     <major.minor>  -> patches in that minor
#     lts            -> all LTS releases
available_node() {
    local filter="$1"
    local response
    response=$(_node_fetch_index) || {
        log_error "Failed to query Node release index" >&2
        return 1
    }

    if [[ -z "$filter" ]]; then
        log_info "Fetching available Node major releases..." >&2
        local majors_json
        majors_json=$(echo "$response" | jq -c '
            [.[] | {major: (.version | sub("^v"; "") | split(".")[0] | tonumber), lts: .lts}]
            | group_by(.major)
            | map({major: .[0].major,
                   lts: ([.[] | select(.lts != false) | .lts] | first // null)})
            | sort_by(.major)
        ')
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then
            echo "$majors_json" | jq '[.[].major | tostring]'
            return 0
        fi
        log_info "Available Node major releases (LTS marked with *):"
        echo "$majors_json" | jq -r '.[] | "\(.major)\t\(.lts // "")"' \
            | while IFS=$'\t' read -r major lts; do
                if [[ -n "$lts" ]]; then
                    echo "  * $major (LTS: $lts)"
                else
                    echo "    $major"
                fi
            done
        return 0
    fi

    local versions
    if [[ "$filter" == "lts" ]]; then
        versions=$(echo "$response" \
            | jq -r '.[] | select(.lts != false) | .version' \
            | sed 's/^v//' | sort -V -u)
        log_info "Available Node LTS versions:"
    elif [[ "$filter" =~ ^[0-9]+$ || "$filter" =~ ^[0-9]+\.[0-9]+$ ]]; then
        versions=$(echo "$response" \
            | jq -r --arg p "v${filter}." '.[] | select(.version | startswith($p)) | .version' \
            | sed 's/^v//' | sort -V -u)
        log_info "Available Node $filter versions:"
    else
        log_error "Invalid Node filter: $filter"
        log_info "Use a major (e.g. 22), major.minor (e.g. 22.5), or 'lts'"
        return 1
    fi

    if [[ -z "$versions" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No matching Node versions"; fi
        return 1
    fi
    echo "$versions" | dtm_emit_version_list
}

current_node() {
    local current_node_home="${NODE_HOME:-}"
    if [[ -z "$current_node_home" ]]; then
        log_warn "No active Node version (NODE_HOME not set)" >&2
        return 1
    fi
    if [[ "$current_node_home" != "$NODE_ROOT"/* ]]; then
        log_warn "Active NODE_HOME is not managed by dtm: $current_node_home" >&2
        return 1
    fi
    if [[ ! -x "$current_node_home/bin/node" ]]; then
        log_warn "Active Node install is missing: $current_node_home" >&2
        return 1
    fi
    local resolved version
    resolved="$(dtm_resolved_path "$current_node_home")"
    version="$(basename "$resolved")"
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        jq -nc \
            --arg tool "node" \
            --arg version "$version" \
            --arg path "$resolved" \
            --arg link "$current_node_home" \
            '{tool:$tool,version:$version,path:$path,link:$link}'
        return 0
    fi
    echo "$version"
}

# Update active Node to latest patch in current major series.
update_node() {
    local current major latest install_dir
    current=$(DTM_OUTPUT_JSON='' current_node) || {
        log_error "No active Node version to update"
        exit 1
    }
    major="${current%%.*}"
    log_info "Active Node: $current (major $major)" >&2

    latest=$(_node_resolve_version "$major") || exit 1
    log_info "Latest Node $major: $latest" >&2

    if [[ "$latest" == "$current" ]]; then
        log_success "Node $current is already the latest patch" >&2
        return 0
    fi

    install_dir="${NODE_ROOT}/${latest}"
    if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
        pull_node "$latest"
    else
        log_info "Node $latest already installed; switching only" >&2
    fi

    set_node "$latest" set
}

remove_node() {
    local version="$1"
    local install_dir="${NODE_ROOT}/${version}"

    if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
        log_error "Node $version is not installed"
        return 1
    fi

    log_warn "About to remove Node $version from $install_dir"
    if dtm_confirm "Are you sure? (y/N): "; then
        if [[ -L "${NODE_ROOT}/current" ]]; then
            local cur_target
            cur_target="$(dtm_resolved_path "${NODE_ROOT}/current" 2>/dev/null || true)"
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${NODE_ROOT}/current"
            fi
        fi
        rm -rf "$install_dir"
        log_success "Node $version removed"
    else
        log_info "Removal cancelled"
    fi
}
