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
#   binary_name             Executable filename (default: basename of binary_check).
#   binary_check            Path under install dir that proves a valid install (e.g. bin/kotlinc).
#   archive_format          tar.gz | tgz | tar.xz | zip | binary.
#                           `binary` = no archive, payload is the raw executable.
#   archive_layout          nested        = single top-level dir, its contents become install_dir.
#                           flat          = extract contents directly into install_dir.
#                           flat_to_bin   = single binary at archive root, install as bin_subdir/binary_name.
#                           nested_to_bin = single top-level dir containing a binary (plus optional
#                                           docs); install just the binary as bin_subdir/binary_name.
#                           binary        = (set automatically when archive_format=binary).
#                           Backwards-compat: archive_strip_top=1 maps to nested, =0 maps to flat.
#   download_url            Template. Substitutions: ${VERSION}, ${OS}, ${ARCH}.
#   checksum_url            Optional sidecar URL template (omitted = skip with warning).
#   checksum_algo           sha256 (default), sha512, sha1.
#   checksum_format         single (file body is the hash, default) | multi (lines `<hash>  <filename>`,
#                           grep by basename of download_url).
#   os_linux, os_mac        Per-candidate alias for ${OS}. Defaults to dtm's OS (linux|mac).
#   arch_x64, arch_aarch64  Per-candidate alias for ${ARCH}. Defaults to dtm's ARCH (x64|aarch64).
#   version_strategy        Named strategy: github_releases | hashicorp_releases |
#                           maven_central | gradle_versions | go_dl | apache_dist |
#                           dir_index.
#   version_strategy_arg    Strategy-specific arg (e.g. "owner/repo", "terraform",
#                           Maven artifact path, "<dir>;<prefix>;<suffix>" for
#                           apache_dist, "<url>;<prefix>;<suffix>" for dir_index).
#   version_filter          Regex applied to listed versions.
#   version_tag_prefix      Prefix stripped from upstream tag names (e.g. v, go).
#   post_install_fn         Optional shell function called as: <fn> <install_dir> <version>.
#   workspace_var           Optional secondary env var (e.g. GOPATH) pointing at a
#                           per-version sibling dir under DTM_ROOT/<workspace_subdir>/<version>.
#   workspace_subdir        Sibling dir name under DTM_ROOT (e.g. go-workspaces).
#   workspace_bin           Subdir of the workspace to prepend after bin_subdir on PATH (e.g. bin).
#   workspace_init          Comma-separated subdirs to create on pull (e.g. "src,pkg,bin").

# Registry of discovered descriptor files: parallel indexed arrays of
# names and absolute paths. Bash 3.2 has no associative arrays, so lookups
# are linear scans. Candidate count is small (~dozen), so O(n) is fine.
DTM_CANDIDATE_NAMES=()
DTM_CANDIDATE_PATHS=()

# Set or update the descriptor path for a candidate name.
dtm_cand_set() {
    local name="$1" path="$2" i
    for (( i=0; i < ${#DTM_CANDIDATE_NAMES[@]}; i++ )); do
        if [[ "${DTM_CANDIDATE_NAMES[$i]}" == "$name" ]]; then
            DTM_CANDIDATE_PATHS[$i]="$path"
            return 0
        fi
    done
    DTM_CANDIDATE_NAMES+=("$name")
    DTM_CANDIDATE_PATHS+=("$path")
}

# Echo the descriptor path for a candidate name. Returns non-zero if absent.
dtm_cand_get() {
    local name="$1" i
    for (( i=0; i < ${#DTM_CANDIDATE_NAMES[@]}; i++ )); do
        if [[ "${DTM_CANDIDATE_NAMES[$i]}" == "$name" ]]; then
            echo "${DTM_CANDIDATE_PATHS[$i]}"
            return 0
        fi
    done
    return 1
}

# Test whether a candidate name is registered. Silent.
dtm_cand_has() {
    local name="$1" i
    for (( i=0; i < ${#DTM_CANDIDATE_NAMES[@]}; i++ )); do
        [[ "${DTM_CANDIDATE_NAMES[$i]}" == "$name" ]] && return 0
    done
    return 1
}

# Reset all candidate_* variables to defaults so a new load doesn't inherit
# leftover state from a prior load in the same process.
candidate_reset() {
    candidate_name=""
    candidate_home_var=""
    candidate_extra_vars=""
    candidate_bin_subdir="bin"
    candidate_binary_name=""
    candidate_binary_check=""
    candidate_archive_format=""
    candidate_archive_layout=""
    candidate_archive_strip_top=""
    candidate_download_url=""
    candidate_checksum_url=""
    candidate_checksum_algo="sha256"
    candidate_checksum_format="single"
    # candidate_os_*/arch_* are read indirectly via ${!os_key} in
    # candidate_render_url; shellcheck can't see that, so silence SC2034.
    # shellcheck disable=SC2034
    candidate_os_linux="linux"
    # shellcheck disable=SC2034
    candidate_os_mac="mac"
    # shellcheck disable=SC2034
    candidate_arch_x64="x64"
    # shellcheck disable=SC2034
    candidate_arch_aarch64="aarch64"
    candidate_version_strategy=""
    candidate_version_strategy_arg=""
    candidate_version_filter=""
    candidate_version_tag_prefix=""
    candidate_post_install_fn=""
    candidate_workspace_var=""
    candidate_workspace_subdir=""
    candidate_workspace_bin=""
    candidate_workspace_init=""
}

# Load a descriptor file. Sets candidate_* variables.
candidate_load() {
    local name="$1"
    local file
    file=$(dtm_cand_get "$name") || file=""
    if [[ -z "$file" || ! -f "$file" ]]; then
        log_error "No descriptor for candidate: $name"
        return 1
    fi
    candidate_reset
    # shellcheck source=/dev/null
    source "$file"
    candidate_name="${candidate_name:-$name}"

    # archive_layout defaults: derive from archive_format / strip_top.
    if [[ -z "$candidate_archive_layout" ]]; then
        if [[ "$candidate_archive_format" == "binary" ]]; then
            candidate_archive_layout="binary"
        elif [[ "$candidate_archive_strip_top" == "1" ]]; then
            candidate_archive_layout="nested"
        else
            candidate_archive_layout="flat"
        fi
    fi

    # binary_name default: basename of binary_check.
    if [[ -z "$candidate_binary_name" && -n "$candidate_binary_check" ]]; then
        candidate_binary_name="$(basename "$candidate_binary_check")"
    fi
}

candidate_root() {
    echo "${DTM_ROOT}/${candidate_name}"
}

# Substitute ${VERSION}, ${OS}, ${ARCH} in a URL template. OS/ARCH are mapped
# through per-candidate aliases (candidate_os_<dtm_os>, candidate_arch_<dtm_arch>).
# OS and ARCH globals are populated by detect_platform() in dtm. Any remaining
# ${VAR} references (e.g. ${DTM_MAVEN_DIST}) are expanded from the environment;
# a missing var aborts so descriptors fail loudly instead of producing broken URLs.
candidate_render_url() {
    local template="$1" version="$2"
    local os_key="candidate_os_${OS}" arch_key="candidate_arch_${ARCH}"
    local os_val="${!os_key:-$OS}" arch_val="${!arch_key:-$ARCH}"
    local out="${template//\$\{VERSION\}/$version}"
    out="${out//\$\{OS\}/$os_val}"
    out="${out//\$\{ARCH\}/$arch_val}"
    while [[ "$out" =~ \$\{([A-Z_][A-Z0-9_]*)\} ]]; do
        local var="${BASH_REMATCH[1]}"
        local val="${!var-}"
        if [[ -z "${!var+x}" ]]; then
            log_error "URL template references undefined env var: \${$var}" >&2
            return 1
        fi
        out="${out//\$\{$var\}/$val}"
    done
    echo "$out"
}

# Emit `export` lines for the active install. Goes to stdout so the dtm.sh
# wrapper can eval it into the parent shell. <workspace> is optional — only used
# when the descriptor sets workspace_var (e.g. GOPATH for go).
candidate_emit_exports() {
    local home="$1" workspace="${2:-}"
    local home_path
    if [[ -n "$candidate_home_var" ]]; then
        echo "export ${candidate_home_var}=\"${home}\""
        home_path="\${${candidate_home_var}}/${candidate_bin_subdir}"
    else
        home_path="${home}/${candidate_bin_subdir}"
    fi
    local v
    for v in $candidate_extra_vars; do
        echo "export ${v}=\"${home}\""
    done
    if [[ -n "$candidate_workspace_var" && -n "$workspace" ]]; then
        echo "export ${candidate_workspace_var}=\"${workspace}\""
    fi
    local path_line="$home_path"
    if [[ -n "$candidate_workspace_var" && -n "$candidate_workspace_bin" && -n "$workspace" ]]; then
        path_line="${path_line}:\${${candidate_workspace_var}}/${candidate_workspace_bin}"
    fi
    echo "export PATH=\"${path_line}:\${PATH}\""
}

# Compute the workspace dir for a given version. Echoes empty if no workspace_var.
candidate_workspace_dir() {
    local version="$1"
    if [[ -z "$candidate_workspace_var" || -z "$candidate_workspace_subdir" ]]; then
        return 0
    fi
    echo "${DTM_ROOT}/${candidate_workspace_subdir}/${version}"
}

# Create workspace dir + init subdirs (idempotent).
candidate_workspace_ensure() {
    local ws_dir="$1"
    [[ -z "$ws_dir" ]] && return 0
    if [[ ! -d "$ws_dir" ]]; then
        if [[ -n "$candidate_workspace_init" ]]; then
            local init="${candidate_workspace_init//,/ }"
            local sub
            for sub in $init; do
                mkdir -p "$ws_dir/$sub"
            done
        else
            mkdir -p "$ws_dir"
        fi
    fi
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
    candidate_filter_versions "$tags"
}

# HashiCorp releases API: https://api.releases.hashicorp.com/v1/releases/<product>?limit=20
# The API caps `limit` at 20, so we paginate using `?after=<timestamp_created>`
# from the oldest item of the previous page until the page returns fewer than
# 20 entries. Pages are bounded by DTM_HASHICORP_MAX_PAGES (default 25) so a
# misbehaving server can't trigger an unbounded loop.
strategy_hashicorp_releases_list() {
    local product="$1"
    local max_pages="${DTM_HASHICORP_MAX_PAGES:-25}"
    local base="https://api.releases.hashicorp.com/v1/releases/${product}?limit=20"
    local after="" page=0 response page_versions all_versions="" count last_ts
    while (( page < max_pages )); do
        local url="$base"
        [[ -n "$after" ]] && url="${base}&after=${after}"
        response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || return 1
        count=$(echo "$response" | jq 'length' 2>/dev/null) || return 1
        [[ "$count" == "0" ]] && break
        page_versions=$(echo "$response" | jq -r '.[] | select(.is_prerelease==false) | .version' 2>/dev/null) || return 1
        if [[ -z "$all_versions" ]]; then
            all_versions="$page_versions"
        else
            all_versions="${all_versions}"$'\n'"${page_versions}"
        fi
        (( count < 20 )) && break
        last_ts=$(echo "$response" | jq -r '.[-1].timestamp_created' 2>/dev/null) || return 1
        [[ -z "$last_ts" || "$last_ts" == "null" ]] && break
        after="$last_ts"
        page=$((page+1))
    done
    candidate_filter_versions "$all_versions"
}

# Maven Central metadata XML: lists every published version of an artifact.
# Strategy arg is the artifact path (e.g. "org/apache/maven/apache-maven").
# Excludes hyphenated versions (RCs, alphas, milestones).
strategy_maven_central_list() {
    local artifact_path="$1"
    local url="${DTM_MAVEN_REPO}/${artifact_path}/maven-metadata.xml"
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || return 1
    local versions
    versions=$(echo "$response" \
        | grep -o '<version>[^<]*</version>' \
        | sed 's/<[^>]*>//g' \
        | grep -v -- '-')
    candidate_filter_versions "$versions"
}

# Gradle versions API: services.gradle.org/versions/all (JSON list of releases).
# Strategy arg is ignored. Excludes snapshots, nightlies, RCs, milestones, broken.
strategy_gradle_versions_list() {
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_GRADLE_DIST}/versions/all" 2>/dev/null) || return 1
    local versions
    versions=$(echo "$response" | jq -r \
        '.[] | select(.snapshot==false and .nightly==false and .broken==false and .rcFor=="" and .milestoneFor=="") | .version' \
        2>/dev/null) || return 1
    candidate_filter_versions "$versions"
}

# Generic HTML directory index. Strategy arg is `<base_url>;<prefix>;<suffix>`.
# Walks the listing, picks hrefs of the form <prefix>VERSION<suffix>, and emits
# VERSION per line. Use this for vendors that publish a static HTML index of
# release files but don't fit `apache_dist`'s host shape (e.g. download.docker.com).
strategy_dir_index_list() {
    local arg="$1"
    local url prefix suffix
    IFS=';' read -r url prefix suffix <<< "$arg"
    if [[ -z "$url" || -z "$prefix" || -z "$suffix" ]]; then
        log_error "dir_index arg must be '<url>;<prefix>;<suffix>'" >&2
        return 1
    fi
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || return 1
    local pre_re="${prefix//./\\.}"
    local suf_re="${suffix//./\\.}"
    local versions
    versions=$(echo "$response" \
        | grep -oE "href=\"${pre_re}[^\"]+${suf_re}\"" \
        | sed -e "s|href=\"${prefix}||" -e "s|${suffix}\"\$||")
    candidate_filter_versions "$versions"
}

# Apache dist directory listing. Walks the Apache archive HTML index and
# extracts version substrings from filenames. Strategy arg has the form
#   <relative_path>;<filename_prefix>;<filename_suffix>
# Example for ant:
#   ant/binaries;apache-ant-;-bin.tar.gz
# `.` characters in prefix/suffix are escaped before matching. Versions are
# substrings between prefix and suffix on each href in the listing. Override
# the host via DTM_APACHE_DIST (defaults to https://archive.apache.org/dist).
strategy_apache_dist_list() {
    local arg="$1"
    local path prefix suffix
    IFS=';' read -r path prefix suffix <<< "$arg"
    if [[ -z "$path" || -z "$prefix" || -z "$suffix" ]]; then
        log_error "apache_dist arg must be '<path>;<prefix>;<suffix>'" >&2
        return 1
    fi
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_APACHE_DIST}/${path}/" 2>/dev/null) || return 1
    local pre_re="${prefix//./\\.}"
    local suf_re="${suffix//./\\.}"
    local versions
    versions=$(echo "$response" \
        | grep -oE "href=\"${pre_re}[^\"]+${suf_re}\"" \
        | sed -e "s|href=\"${prefix}||" -e "s|${suffix}\"\$||")
    candidate_filter_versions "$versions"
}

# go.dev download index: all stable Go releases. Strategy arg is ignored.
# version_tag_prefix=go strips the "go" prefix from upstream "go1.22.0" tags.
strategy_go_dl_list() {
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${DTM_GO_DIST}/dl/?mode=json&include=all" 2>/dev/null) || return 1
    local versions
    versions=$(echo "$response" | jq -r \
        '.[] | select(.stable==true) | .version' 2>/dev/null) || return 1
    candidate_filter_versions "$versions"
}

# Apply candidate_version_tag_prefix + candidate_version_filter, then sort/dedup.
candidate_filter_versions() {
    local list="$1"
    local prefix="${candidate_version_tag_prefix:-}"
    if [[ -n "$prefix" ]]; then
        # sed s///, not ${var//}: needs per-line ^anchor on multiline input.
        # shellcheck disable=SC2001
        list=$(echo "$list" | sed "s/^${prefix}//")
    fi
    local filter="${candidate_version_filter:-}"
    if [[ -n "$filter" ]]; then
        list=$(echo "$list" | grep -E "$filter" || true)
    fi
    echo "$list" | sort -V -u | grep -v '^$' || true
}

# Dispatch to the configured version strategy.
candidate_list_versions() {
    case "$candidate_version_strategy" in
        github_releases)    strategy_github_releases_list    "$candidate_version_strategy_arg" ;;
        hashicorp_releases) strategy_hashicorp_releases_list "$candidate_version_strategy_arg" ;;
        maven_central)      strategy_maven_central_list      "$candidate_version_strategy_arg" ;;
        gradle_versions)    strategy_gradle_versions_list ;;
        go_dl)              strategy_go_dl_list ;;
        apache_dist)        strategy_apache_dist_list        "$candidate_version_strategy_arg" ;;
        dir_index)          strategy_dir_index_list          "$candidate_version_strategy_arg" ;;
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
    elif [[ "$version" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        # Major or major.minor → resolve to latest matching patch.
        log_info "Resolving latest ${name} ${version} patch..."
        exact=$(candidate_list_versions \
            | grep -E "^${version//./\\.}(\$|\\.)" \
            | sort -V | tail -1)
        if [[ -z "$exact" ]]; then
            log_error "No ${name} versions found matching prefix '${version}'"
            exit 1
        fi
        log_info "Latest ${name} ${version}: $exact"
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

    local temp_dir download_file url_basename
    temp_dir=$(mktemp -d)
    url_basename=$(basename "$url")
    download_file="${temp_dir}/${url_basename}"

    if ! dtm_download "$url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    if [[ -n "$candidate_checksum_url" ]]; then
        local checksum_url checksum
        checksum_url=$(candidate_render_url "$candidate_checksum_url" "$exact")
        log_info "Fetching checksum from $checksum_url"
        checksum=$(candidate_fetch_checksum "$checksum_url" "$url_basename")
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

    log_info "Installing ${name} to $install_dir..."
    mkdir -p "$install_dir"
    if ! candidate_extract "$download_file" "$install_dir" "$temp_dir"; then
        log_error "Install payload step failed"
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

    local ws_dir
    ws_dir=$(candidate_workspace_dir "$exact")
    if [[ -n "$ws_dir" ]]; then
        candidate_workspace_ensure "$ws_dir"
        log_info "Workspace ready at $ws_dir"
    fi

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "${name} ${exact} installed to $install_dir"
    log_info "Run 'dtm set ${name} ${exact}' to activate"
}

# Fetch checksum from a sidecar URL. Honors candidate_checksum_format:
#   single (default) — file body is the hash (first whitespace token).
#   multi            — lines `<hash>  <filename>`; pick the line matching <basename>.
candidate_fetch_checksum() {
    local url="$1" basename="$2"
    case "$candidate_checksum_format" in
        single|"")
            fetch_checksum_from_url "$url"
            ;;
        multi)
            local content line
            content=$(curl -sL --fail "$url" 2>/dev/null) || return 1
            line=$(echo "$content" | awk -v name="$basename" '$2 == name {print $1; exit}')
            echo "$line"
            ;;
        *)
            log_error "Unknown checksum_format: $candidate_checksum_format" >&2
            return 1
            ;;
    esac
}

# Place the downloaded payload into <install_dir>, honoring archive_format and
# archive_layout. <temp_dir> is a scratch dir for staging zip extracts.
candidate_extract() {
    local archive="$1" install_dir="$2" temp_dir="$3"

    # `binary` mode: payload is the raw executable, no extraction.
    if [[ "$candidate_archive_format" == "binary" ]]; then
        if [[ -z "$candidate_binary_name" ]]; then
            log_error "binary_name required when archive_format=binary"
            return 1
        fi
        local target="${install_dir}/${candidate_bin_subdir}/${candidate_binary_name}"
        mkdir -p "$(dirname "$target")"
        cp "$archive" "$target" || return 1
        chmod +x "$target" || return 1
        return 0
    fi

    # Stage all archive types into a temp dir, then move into place per layout.
    local stage="${temp_dir}/extracted"
    mkdir -p "$stage"
    case "$candidate_archive_format" in
        tar.gz|tgz) tar -xzf "$archive" -C "$stage" || return 1 ;;
        tar.xz)     tar -xJf "$archive" -C "$stage" || return 1 ;;
        zip)        unzip -q "$archive" -d "$stage" || return 1 ;;
        *)
            log_error "Unsupported archive_format: $candidate_archive_format"
            return 1
            ;;
    esac

    case "$candidate_archive_layout" in
        nested)
            local count top
            count=$(find "$stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
            if [[ "$count" != "1" ]]; then
                log_error "Expected single top-level entry in archive, found $count"
                return 1
            fi
            top=$(find "$stage" -mindepth 1 -maxdepth 1 | head -1)
            if [[ ! -d "$top" ]]; then
                log_error "Top-level entry in archive is not a directory: $top"
                return 1
            fi
            ( shopt -s dotglob nullglob; mv "$top"/* "$install_dir/" )
            ;;
        flat)
            ( shopt -s dotglob nullglob; mv "$stage"/* "$install_dir/" )
            ;;
        flat_to_bin)
            if [[ -z "$candidate_binary_name" ]]; then
                log_error "binary_name required when archive_layout=flat_to_bin"
                return 1
            fi
            local src="${stage}/${candidate_binary_name}"
            if [[ ! -f "$src" ]]; then
                log_error "Expected binary at archive root: ${candidate_binary_name}"
                return 1
            fi
            mkdir -p "${install_dir}/${candidate_bin_subdir}"
            mv "$src" "${install_dir}/${candidate_bin_subdir}/${candidate_binary_name}"
            chmod +x "${install_dir}/${candidate_bin_subdir}/${candidate_binary_name}"
            ;;
        nested_to_bin)
            if [[ -z "$candidate_binary_name" ]]; then
                log_error "binary_name required when archive_layout=nested_to_bin"
                return 1
            fi
            local nb_count nb_top nb_src
            nb_count=$(find "$stage" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
            if [[ "$nb_count" != "1" ]]; then
                log_error "Expected single top-level entry in archive, found $nb_count"
                return 1
            fi
            nb_top=$(find "$stage" -mindepth 1 -maxdepth 1 | head -1)
            if [[ ! -d "$nb_top" ]]; then
                log_error "Top-level entry in archive is not a directory: $nb_top"
                return 1
            fi
            nb_src="${nb_top}/${candidate_binary_name}"
            if [[ ! -f "$nb_src" ]]; then
                log_error "Expected binary inside top-level dir: ${candidate_binary_name}"
                return 1
            fi
            mkdir -p "${install_dir}/${candidate_bin_subdir}"
            mv "$nb_src" "${install_dir}/${candidate_bin_subdir}/${candidate_binary_name}"
            chmod +x "${install_dir}/${candidate_bin_subdir}/${candidate_binary_name}"
            ;;
        *)
            log_error "Unknown archive_layout: $candidate_archive_layout"
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
        # Strict prefix match: require a dot boundary so "1.2" doesn't match
        # "1.20" — picks the latest installed patch in the requested series.
        install_dir=$(find "$root" -maxdepth 1 -type d -name "${version}.*" 2>/dev/null | sort -V | tail -1)
        if [[ -z "$install_dir" ]]; then
            log_error "${name} ${version} is not installed"
            log_info "Available versions:"
            candidate_list "$name"
            exit 1
        fi
    fi

    local resolved
    resolved=$(basename "$install_dir")

    # Workspace dir + stable symlink (only when descriptor declares a workspace_var).
    local ws_dir="" ws_root="" ws_stable=""
    if [[ -n "$candidate_workspace_var" && -n "$candidate_workspace_subdir" ]]; then
        ws_root="${DTM_ROOT}/${candidate_workspace_subdir}"
        ws_dir="${ws_root}/${resolved}"
        candidate_workspace_ensure "$ws_dir"
    fi

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
        if [[ -n "$candidate_workspace_var" ]]; then
            dtm_clean_dtmrc_for "$candidate_workspace_var"
        fi
        dtm_set_current_symlink "$root" "$install_dir"
        if [[ -n "$ws_dir" ]]; then
            mkdir -p "$ws_root"
            ln -sfn "$ws_dir" "${ws_root}/current"
            ws_stable="${ws_root}/current"
        fi

        local stable="${root}/current"
        candidate_emit_exports "$stable" "$ws_stable" >> "$DTM_CONFIG"

        log_success "${name} ${resolved} activated" >&2
        log_info "Applying changes to current shell..." >&2

        candidate_emit_exports "$stable" "$ws_stable"
        return 0
    fi

    # use mode: per-shell only, direct paths, no symlink update.
    candidate_emit_exports "$install_dir" "$ws_dir"
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
        local ws_link="" ws_resolved=""
        if [[ -n "$candidate_workspace_var" ]]; then
            ws_link="${!candidate_workspace_var:-}"
            if [[ -n "$ws_link" && -e "$ws_link" ]]; then
                ws_resolved=$(dtm_resolved_path "$ws_link")
            fi
        fi
        jq -nc \
            --arg tool "$name" \
            --arg version "$version" \
            --arg path "$resolved" \
            --arg link "$cur" \
            --arg ws_var "$candidate_workspace_var" \
            --arg ws_link "$ws_link" \
            --arg ws_path "$ws_resolved" \
            '{tool:$tool,version:$version,path:$path,link:$link}
             + (if $ws_var == "" then {} else
                  {workspace: {var:$ws_var,
                               link:(if $ws_link=="" then null else $ws_link end),
                               path:(if $ws_path=="" then null else $ws_path end)}}
                end)'
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
    current=$(DTM_OUTPUT_JSON='' candidate_current "$name") || {
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

    local root install_dir ws_root ws_dir
    root=$(candidate_root)
    install_dir="${root}/${version}"
    ws_dir=$(candidate_workspace_dir "$version")
    if [[ -n "$candidate_workspace_subdir" ]]; then
        ws_root="${DTM_ROOT}/${candidate_workspace_subdir}"
    fi

    if [[ ! -d "$install_dir" ]]; then
        log_error "${name} ${version} is not installed"
        return 1
    fi

    log_warn "About to remove ${name} ${version} from:"
    log_warn "  - $install_dir"
    if [[ -n "$ws_dir" && -d "$ws_dir" ]]; then
        log_warn "  - $ws_dir (workspace)"
    fi
    if dtm_confirm "Are you sure? (y/N): "; then
        if [[ -L "${root}/current" ]]; then
            local cur_target
            cur_target=$(dtm_resolved_path "${root}/current" 2>/dev/null || true)
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${root}/current"
            fi
        fi
        if [[ -n "$ws_root" && -L "${ws_root}/current" ]]; then
            local cur_ws
            cur_ws=$(dtm_resolved_path "${ws_root}/current" 2>/dev/null || true)
            if [[ "$cur_ws" == "$ws_dir" ]]; then
                rm -f "${ws_root}/current"
            fi
        fi
        rm -rf "$install_dir"
        if [[ -n "$ws_dir" && -d "$ws_dir" ]]; then
            rm -rf "$ws_dir"
        fi
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
