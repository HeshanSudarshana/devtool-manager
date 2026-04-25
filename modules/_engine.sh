#!/usr/bin/env bash

# Generic candidate engine.
#
# A candidate is a tool described by a small key=value descriptor file under
# modules/candidates/<name>.conf. The engine reads the descriptor and drives
# pull/set/list/current/available/update/remove with no per-tool code.
#
# Descriptor variables (all prefixed `candidate_`):
#   name                    Candidate identifier (matches filename).
#   home_var                Env var to export for the active install (e.g. KOTLIN_HOME).
#   extra_vars              Space-separated extra env vars to also point at the home dir.
#   bin_subdir              Subdir under home that goes on PATH (default: bin).
#   binary_check            Path under install dir that proves a valid install (e.g. bin/kotlinc).
#   archive_format          One of: tar.gz, tgz, tar.xz, zip.
#   archive_strip_top       1 = archive has a single top-level dir whose contents become install_dir.
#                           0 = extract directly into install_dir.
#   download_url            Template; ${VERSION} is substituted with the resolved version.
#   checksum_url            Optional sidecar URL template (omitted = skip checksum, with warning).
#   checksum_algo           sha256 (default), sha512, sha1.
#   version_strategy        Named version-list strategy: github_releases (more to come).
#   version_strategy_arg    Strategy-specific argument (e.g. "owner/repo" for github_releases).
#   version_filter          Regex applied to listed versions (anchor with ^/$).
#   version_tag_prefix      Prefix stripped from upstream tag names before comparison (e.g. v).
#   post_install_fn         Optional shell function called as: <fn> <install_dir> <version>.

# Registry of discovered descriptor files: name -> absolute path.
declare -gA DTM_CANDIDATE_FILES

# Reset all candidate_* variables to defaults so a new load doesn't inherit
# leftover state from a prior load in the same process.
candidate_reset() {
    candidate_name=""
    candidate_home_var=""
    candidate_extra_vars=""
    candidate_bin_subdir="bin"
    candidate_binary_check=""
    candidate_archive_format=""
    candidate_archive_strip_top="0"
    candidate_download_url=""
    candidate_checksum_url=""
    candidate_checksum_algo="sha256"
    candidate_version_strategy=""
    candidate_version_strategy_arg=""
    candidate_version_filter=""
    candidate_version_tag_prefix=""
    candidate_post_install_fn=""
}

# Load a descriptor file. Sets candidate_* variables.
candidate_load() {
    local name="$1"
    local file="${DTM_CANDIDATE_FILES[$name]:-}"
    if [[ -z "$file" || ! -f "$file" ]]; then
        log_error "No descriptor for candidate: $name"
        return 1
    fi
    candidate_reset
    # shellcheck source=/dev/null
    source "$file"
    candidate_name="${candidate_name:-$name}"
}

candidate_root() {
    echo "${DTM_ROOT}/${candidate_name}"
}

# Substitute ${VERSION} (and only that) in a URL template.
candidate_render_url() {
    local template="$1" version="$2"
    echo "${template//\$\{VERSION\}/$version}"
}

# Emit `export` lines for the active install. Goes to stdout so the dtm.sh
# wrapper can eval it into the parent shell.
candidate_emit_exports() {
    local home="$1"
    if [[ -n "$candidate_home_var" ]]; then
        echo "export ${candidate_home_var}=\"${home}\""
        echo "export PATH=\"\${${candidate_home_var}}/${candidate_bin_subdir}:\${PATH}\""
    else
        echo "export PATH=\"${home}/${candidate_bin_subdir}:\${PATH}\""
    fi
    local v
    for v in $candidate_extra_vars; do
        echo "export ${v}=\"${home}\""
    done
}

# --- version-list strategies -------------------------------------------------
# Each strategy_<name>_list takes the descriptor's version_strategy_arg and
# echoes one version per line, sorted, deduplicated, with version_tag_prefix
# stripped and version_filter applied.

strategy_github_releases_list() {
    local repo="$1"
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "https://api.github.com/repos/${repo}/releases?per_page=100" 2>/dev/null) || return 1
    local tags
    tags=$(echo "$response" | jq -r '.[] | select(.draft==false and .prerelease==false) | .tag_name' 2>/dev/null) || return 1
    local prefix="${candidate_version_tag_prefix:-}"
    if [[ -n "$prefix" ]]; then
        tags=$(echo "$tags" | sed "s/^${prefix}//")
    fi
    local filter="${candidate_version_filter:-}"
    if [[ -n "$filter" ]]; then
        tags=$(echo "$tags" | grep -E "$filter" || true)
    fi
    echo "$tags" | sort -V -u | grep -v '^$' || true
}

# Dispatch to the configured version strategy.
candidate_list_versions() {
    case "$candidate_version_strategy" in
        github_releases) strategy_github_releases_list "$candidate_version_strategy_arg" ;;
        *) log_error "Unknown version strategy: $candidate_version_strategy" >&2; return 1 ;;
    esac
}

candidate_resolve_latest() {
    candidate_list_versions | tail -1
}

# --- engine commands ---------------------------------------------------------

candidate_pull() {
    local name="$1" version="$2"
    candidate_load "$name" || exit 1

    local exact="$version"
    if [[ "$version" == "latest" ]]; then
        log_info "Resolving latest ${name} version..."
        exact=$(candidate_resolve_latest)
        if [[ -z "$exact" ]]; then
            log_error "Failed to resolve latest ${name} version"
            exit 1
        fi
        log_info "Latest ${name}: $exact"
    fi

    local root install_dir lock_path
    root=$(candidate_root)
    mkdir -p "$root"
    install_dir="${root}/${exact}"
    lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "${name} ${exact} already installed at $install_dir"
        if ! dtm_confirm "Reinstall? (y/N): "; then
            log_info "Cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local url
    url=$(candidate_render_url "$candidate_download_url" "$exact")
    log_info "Downloading ${name} from $url"

    local temp_dir ext download_file
    temp_dir=$(mktemp -d)
    case "$candidate_archive_format" in
        tar.gz|tgz) ext="tar.gz" ;;
        tar.xz)     ext="tar.xz" ;;
        zip)        ext="zip" ;;
        *)
            log_error "Unsupported archive_format: $candidate_archive_format"
            rm -rf "$temp_dir"
            exit 1
            ;;
    esac
    download_file="${temp_dir}/${name}.${ext}"

    if ! dtm_download "$url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    if [[ -n "$candidate_checksum_url" ]]; then
        local checksum_url checksum
        checksum_url=$(candidate_render_url "$candidate_checksum_url" "$exact")
        log_info "Fetching checksum from $checksum_url"
        checksum=$(fetch_checksum_from_url "$checksum_url")
        if [[ -z "$checksum" ]]; then
            log_error "Failed to fetch checksum from $checksum_url"
            rm -rf "$temp_dir"
            exit 1
        fi
        log_info "Verifying checksum (${candidate_checksum_algo})..."
        if ! verify_checksum "$download_file" "$checksum" "$candidate_checksum_algo"; then
            rm -rf "$temp_dir"
            exit 1
        fi
    else
        log_warn "No checksum configured for ${name} — skipping verification"
    fi

    log_info "Extracting ${name} to $install_dir..."
    mkdir -p "$install_dir"
    if ! candidate_extract "$download_file" "$install_dir" "$temp_dir"; then
        log_error "Extraction failed"
        rm -rf "$temp_dir" "$install_dir"
        exit 1
    fi

    rm -rf "$temp_dir"

    if [[ -n "$candidate_binary_check" && ! -e "${install_dir}/${candidate_binary_check}" ]]; then
        log_error "Install verification failed: missing ${install_dir}/${candidate_binary_check}"
        rm -rf "$install_dir"
        dtm_release_lock "$lock_path"
        trap - EXIT INT TERM
        exit 1
    fi

    if [[ -n "$candidate_post_install_fn" ]]; then
        if ! "$candidate_post_install_fn" "$install_dir" "$exact"; then
            log_error "post_install hook failed: $candidate_post_install_fn"
            rm -rf "$install_dir"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            exit 1
        fi
    fi

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "${name} ${exact} installed to $install_dir"
    log_info "Run 'dtm set ${name} ${exact}' to activate"
}

# Extract <archive> into <install_dir>, honoring archive_format and
# archive_strip_top. <temp_dir> is a scratch dir for staging zip extracts.
candidate_extract() {
    local archive="$1" install_dir="$2" temp_dir="$3"
    case "$candidate_archive_format" in
        tar.gz|tgz)
            if [[ "$candidate_archive_strip_top" == "1" ]]; then
                tar -xzf "$archive" -C "$install_dir" --strip-components=1
            else
                tar -xzf "$archive" -C "$install_dir"
            fi
            ;;
        tar.xz)
            if [[ "$candidate_archive_strip_top" == "1" ]]; then
                tar -xJf "$archive" -C "$install_dir" --strip-components=1
            else
                tar -xJf "$archive" -C "$install_dir"
            fi
            ;;
        zip)
            local stage="${temp_dir}/extracted"
            mkdir -p "$stage"
            unzip -q "$archive" -d "$stage" || return 1
            if [[ "$candidate_archive_strip_top" == "1" ]]; then
                local count top
                count=$(find "$stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
                if [[ "$count" != "1" ]]; then
                    log_error "Expected single top-level entry in zip, found $count"
                    return 1
                fi
                top=$(find "$stage" -mindepth 1 -maxdepth 1 | head -1)
                if [[ ! -d "$top" ]]; then
                    log_error "Top-level entry in zip is not a directory: $top"
                    return 1
                fi
                ( shopt -s dotglob nullglob; mv "$top"/* "$install_dir/" )
            else
                ( shopt -s dotglob nullglob; mv "$stage"/* "$install_dir/" )
            fi
            ;;
        *)
            log_error "Unsupported archive_format: $candidate_archive_format"
            return 1
            ;;
    esac
}

candidate_set() {
    local name="$1" version="$2" mode="${3:-set}"
    candidate_load "$name" || exit 1

    local root install_dir
    root=$(candidate_root)

    if [[ -d "${root}/${version}" && ! -L "${root}/${version}" ]]; then
        install_dir="${root}/${version}"
    else
        install_dir=$(find "$root" -maxdepth 1 -type d -name "${version}*" 2>/dev/null | sort -V | tail -1)
        if [[ -z "$install_dir" ]]; then
            log_error "${name} ${version} is not installed"
            log_info "Available versions:"
            candidate_list "$name"
            exit 1
        fi
    fi

    local resolved
    resolved=$(basename "$install_dir")

    if [[ "$mode" == "set" ]]; then
        log_info "Setting ${name} to ${resolved}..." >&2

        mkdir -p "$(dirname "$DTM_CONFIG")"
        if [[ -n "$candidate_home_var" ]]; then
            dtm_clean_dtmrc_for "$candidate_home_var" "/${name}/.*/${candidate_bin_subdir}"
        fi
        local v
        for v in $candidate_extra_vars; do
            dtm_clean_dtmrc_for "$v"
        done
        dtm_set_current_symlink "$root" "$install_dir"

        local stable="${root}/current"
        candidate_emit_exports "$stable" >> "$DTM_CONFIG"

        log_success "${name} ${resolved} activated" >&2
        log_info "Applying changes to current shell..." >&2

        candidate_emit_exports "$stable"
        return 0
    fi

    # use mode: per-shell only, direct path, no symlink update.
    candidate_emit_exports "$install_dir"
}

candidate_list() {
    local name="$1"
    candidate_load "$name" || exit 1

    local root
    root=$(candidate_root)
    if [[ ! -d "$root" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_info "No ${name} versions installed"; fi
        return 0
    fi

    local active_resolved=""
    if [[ -n "$candidate_home_var" ]]; then
        local cur="${!candidate_home_var:-}"
        if [[ -n "$cur" && -e "$cur" ]]; then
            active_resolved=$(dtm_resolved_path "$cur")
        fi
    fi

    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        local entries=() dir version active
        for dir in "$root"/*; do
            [[ -L "$dir" ]] && continue
            [[ -d "$dir" ]] || continue
            [[ -n "$candidate_binary_check" && ! -e "$dir/$candidate_binary_check" ]] && continue
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

    log_info "Installed ${name} versions:"
    local dir version
    for dir in "$root"/*; do
        [[ -L "$dir" ]] && continue
        [[ -d "$dir" ]] || continue
        [[ -n "$candidate_binary_check" && ! -e "$dir/$candidate_binary_check" ]] && continue
        version=$(basename "$dir")
        if [[ "$dir" == "$active_resolved" ]]; then
            echo -e "  ${GREEN}* $version${NC} (active)"
        else
            echo "    $version"
        fi
    done
}

candidate_current() {
    local name="$1"
    candidate_load "$name" || exit 1

    if [[ -z "$candidate_home_var" ]]; then
        log_warn "${name} has no home_var configured" >&2
        return 1
    fi

    local root cur
    root=$(candidate_root)
    cur="${!candidate_home_var:-}"
    if [[ -z "$cur" ]]; then
        log_warn "No active ${name} (${candidate_home_var} not set)" >&2
        return 1
    fi
    if [[ "$cur" != "$root"/* ]]; then
        log_warn "Active ${candidate_home_var} not managed by dtm: $cur" >&2
        return 1
    fi
    if [[ -n "$candidate_binary_check" && ! -e "$cur/$candidate_binary_check" ]]; then
        log_warn "Active ${name} install missing: $cur" >&2
        return 1
    fi

    local resolved version
    resolved=$(dtm_resolved_path "$cur")
    version=$(basename "$resolved")

    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        jq -nc \
            --arg tool "$name" \
            --arg version "$version" \
            --arg path "$resolved" \
            --arg link "$cur" \
            '{tool:$tool,version:$version,path:$path,link:$link}'
        return 0
    fi
    echo "$version"
}

candidate_available() {
    local name="$1" filter="$2"
    candidate_load "$name" || exit 1

    log_info "Fetching available ${name} versions..." >&2
    local versions
    versions=$(candidate_list_versions)
    if [[ -z "$versions" ]]; then
        log_error "No ${name} versions found" >&2
        return 1
    fi

    if [[ -n "$filter" ]]; then
        local matched
        matched=$(echo "$versions" | grep -E "^${filter//./\\.}(\$|\\.)" || true)
        if [[ -z "$matched" ]]; then
            if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No ${name} versions matching '$filter'"; fi
            return 1
        fi
        log_info "Available ${name} versions matching '$filter':"
        echo "$matched" | dtm_emit_version_list
    else
        log_info "Available ${name} versions (most recent 20; pass a prefix to filter):"
        echo "$versions" | tail -20 | dtm_emit_version_list
    fi
}

candidate_update() {
    local name="$1"
    candidate_load "$name" || exit 1

    local current major_minor latest install_dir root
    root=$(candidate_root)
    current=$(DTM_OUTPUT_JSON= candidate_current "$name") || {
        log_error "No active ${name} version to update"
        exit 1
    }
    major_minor=$(echo "$current" | grep -oE '^[0-9]+\.[0-9]+')
    if [[ -z "$major_minor" ]]; then
        log_error "Cannot parse major.minor from '$current'"
        exit 1
    fi
    log_info "Active ${name}: $current (series $major_minor)" >&2

    latest=$(candidate_list_versions | grep -E "^${major_minor//./\\.}\\." | sort -V | tail -1)
    if [[ -z "$latest" ]]; then
        log_error "No ${name} version found for series $major_minor"
        exit 1
    fi
    log_info "Latest ${name} ${major_minor}: $latest" >&2

    if [[ "$latest" == "$current" ]]; then
        log_success "${name} ${current} is already the latest patch" >&2
        return 0
    fi

    install_dir="${root}/${latest}"
    if [[ ! -d "$install_dir" ]]; then
        candidate_pull "$name" "$latest"
    else
        log_info "${name} ${latest} already installed; switching only" >&2
    fi

    candidate_set "$name" "$latest" set
}

candidate_remove() {
    local name="$1" version="$2"
    candidate_load "$name" || exit 1

    local root install_dir
    root=$(candidate_root)
    install_dir="${root}/${version}"

    if [[ ! -d "$install_dir" ]]; then
        log_error "${name} ${version} is not installed"
        return 1
    fi

    log_warn "About to remove ${name} ${version} from $install_dir"
    if dtm_confirm "Are you sure? (y/N): "; then
        if [[ -L "${root}/current" ]]; then
            local cur_target
            cur_target=$(dtm_resolved_path "${root}/current" 2>/dev/null || true)
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${root}/current"
            fi
        fi
        rm -rf "$install_dir"
        log_success "${name} ${version} removed"
    else
        log_info "Removal cancelled"
    fi
}

# Single entry point used by the dtm dispatcher.
candidate_dispatch() {
    local cmd="$1" name="$2" version="$3"
    case "$cmd" in
        pull)
            if [[ -z "$version" ]]; then
                log_error "Version is required for pull command"
                exit 1
            fi
            dtm_check_deps
            candidate_pull "$name" "$version"
            ;;
        set)
            if [[ -z "$version" ]]; then
                log_error "Version is required for set command"
                exit 1
            fi
            candidate_set "$name" "$version" set
            ;;
        use)
            if [[ -z "$version" ]]; then
                log_error "Version is required for use command"
                exit 1
            fi
            candidate_set "$name" "$version" use
            ;;
        list)      candidate_list "$name" ;;
        current)   candidate_current "$name" ;;
        available) dtm_check_deps; candidate_available "$name" "$version" ;;
        update)    dtm_check_deps; candidate_update "$name" ;;
        remove)
            if [[ -z "$version" ]]; then
                log_error "Version is required for remove command"
                exit 1
            fi
            candidate_remove "$name" "$version"
            ;;
        *)
            log_error "Unsupported command for candidate ${name}: $cmd"
            exit 1
            ;;
    esac
}
