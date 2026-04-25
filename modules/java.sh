#!/usr/bin/env bash

# Java/JDK management module.
#
# Supported distributions (specify as "<dist>@<version>"; bare version implies
# temurin for back-compat):
#   - temurin   (Eclipse Temurin, default)
#   - zulu      (Azul Zulu OpenJDK)
#   - corretto  (Amazon Corretto; latest-of-major only)
#   - liberica  (BellSoft Liberica)
#
# Install dir layout:
#   - temurin: ${JAVA_ROOT}/<version>
#   - others:  ${JAVA_ROOT}/<dist>-<version>

JAVA_ROOT="${DTM_ROOT}/java"
JAVA_DIST_DEFAULT="temurin"
JAVA_DISTS_SUPPORTED=("temurin" "zulu" "corretto" "liberica")

# Parse "<dist>@<version>" or "<version>".
# Sets globals: JAVA_DIST, JAVA_VERSION_SPEC.
parse_java_spec() {
    local spec="$1"
    if [[ "$spec" == *"@"* ]]; then
        JAVA_DIST="${spec%%@*}"
        JAVA_VERSION_SPEC="${spec#*@}"
    else
        JAVA_DIST="$JAVA_DIST_DEFAULT"
        JAVA_VERSION_SPEC="$spec"
    fi

    local d valid=0
    for d in "${JAVA_DISTS_SUPPORTED[@]}"; do
        if [[ "$d" == "$JAVA_DIST" ]]; then
            valid=1
            break
        fi
    done
    if (( ! valid )); then
        log_error "Unsupported Java distribution: $JAVA_DIST"
        log_info "Supported: ${JAVA_DISTS_SUPPORTED[*]}"
        return 1
    fi
}

# Install dir name (basename) for a dist+version.
java_dir_name() {
    local dist="$1" version="$2"
    if [[ "$dist" == "temurin" ]]; then
        echo "$version"
    else
        echo "${dist}-${version}"
    fi
}

# Detect dist from an installed dir basename.
# "21.0.5+11" -> temurin; "zulu-21.0.11" -> zulu.
java_dir_dist() {
    local name="$1" prefix
    for prefix in "${JAVA_DISTS_SUPPORTED[@]}"; do
        if [[ "$prefix" != "temurin" && "$name" == "${prefix}-"* ]]; then
            echo "$prefix"
            return
        fi
    done
    echo "temurin"
}

# Strip dist prefix from an installed dir basename.
java_dir_version() {
    local name="$1" prefix
    for prefix in "${JAVA_DISTS_SUPPORTED[@]}"; do
        if [[ "$prefix" != "temurin" && "$name" == "${prefix}-"* ]]; then
            echo "${name#${prefix}-}"
            return
        fi
    done
    echo "$name"
}

# ---------------------------------------------------------------------------
# Temurin
# ---------------------------------------------------------------------------

_temurin_resolve_version() {
    local input="$1"
    if [[ ! "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return 0
    fi

    log_info "Fetching latest Java $input version from Temurin..." >&2
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "https://api.adoptium.net/v3/assets/latest/${input}/hotspot?image_type=jdk" 2>/dev/null) || {
        log_error "Failed to query Temurin API" >&2
        return 1
    }

    local version
    version=$(echo "$response" | jq -r '.[0].version.semver | split("+")[0]')
    if [[ -z "$version" || "$version" == "null" ]]; then
        log_error "Could not parse version from Temurin API" >&2
        return 1
    fi
    echo "$version"
}

# Outputs three lines: download_url, checksum, algo
_temurin_download_info() {
    local version="$1"
    local major_version
    major_version=$(echo "$version" | cut -d'.' -f1)

    local os_suffix
    case "$OS" in
        linux) os_suffix="linux" ;;
        mac)   os_suffix="mac" ;;
    esac

    local api_url="https://api.adoptium.net/v3/assets/version/jdk-${version}"
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 \
        "${api_url}?architecture=${ARCH}&image_type=jdk&os=${os_suffix}" 2>/dev/null || true)

    if [[ -z "$response" || "$response" == "[]" ]]; then
        api_url="https://api.adoptium.net/v3/assets/latest/${major_version}/hotspot"
        response=$(curl -fsSL --retry 3 --retry-delay 2 \
            "${api_url}?architecture=${ARCH}&image_type=jdk&os=${os_suffix}" 2>/dev/null || true)
    fi

    local info
    info=$(echo "$response" | jq -r '.[0].binary.package | .link, .checksum' 2>/dev/null)
    if [[ -z "$info" || "$info" == *"null"* ]]; then
        log_error "Could not find download URL/checksum for Temurin $version (OS: $os_suffix, ARCH: $ARCH)" >&2
        return 1
    fi
    echo "$info"
    echo "sha256"
}

_temurin_available() {
    local major_version="$1"
    local response

    if [[ -z "$major_version" ]]; then
        log_info "Fetching available Java major releases from Temurin..." >&2
        response=$(curl -fsSL --retry 3 --retry-delay 2 \
            "https://api.adoptium.net/v3/info/available_releases" 2>/dev/null) || {
            log_error "Failed to query Temurin API" >&2
            return 1
        }
        local versions lts_csv
        versions=$(echo "$response" | jq -r '.available_releases[]' | sort -n)
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then
            echo "$versions" | dtm_json_string_array
            return 0
        fi
        lts_csv=$(echo "$response" | jq -r '.available_lts_releases | join(",")')
        log_info "Available Temurin major releases (LTS marked with *):"
        echo "$versions" | while read -r v; do
            if [[ ",$lts_csv," == *",$v,"* ]]; then
                echo "  * $v (LTS)"
            else
                echo "    $v"
            fi
        done
        return 0
    fi

    if ! [[ "$major_version" =~ ^[0-9]+$ ]]; then
        log_error "Java filter must be a major version number (e.g. 11, 17, 21)"
        return 1
    fi

    log_info "Fetching available Temurin $major_version GA versions..." >&2
    local next=$((major_version + 1))
    local url="https://api.adoptium.net/v3/info/release_versions"
    url="${url}?release_type=ga&page_size=50&sort_method=DEFAULT&sort_order=DESC"
    url="${url}&version=%5B${major_version}%2C${next}%29"

    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
        log_error "Failed to query Temurin API" >&2
        return 1
    }

    local versions
    versions=$(echo "$response" | jq -r '.versions[].semver | split("+")[0]' \
        | sort -V -u)
    if [[ -z "$versions" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No GA versions found for Temurin $major_version"; fi
        return 1
    fi
    log_info "Available Temurin $major_version GA versions:"
    echo "$versions" | dtm_emit_version_list
}

# ---------------------------------------------------------------------------
# Zulu (Azul)
# ---------------------------------------------------------------------------

_zulu_os() {
    case "$OS" in
        linux) echo "linux" ;;
        mac)   echo "macos" ;;
    esac
}

_zulu_arch() {
    case "$ARCH" in
        x64)     echo "x64" ;;
        aarch64) echo "aarch64" ;;
    esac
}

# Query Azul; outputs three lines on success: download_url, sha256, java_version
_zulu_query() {
    local version_filter="$1"
    local os_p arch_p
    os_p=$(_zulu_os)
    arch_p=$(_zulu_arch)
    local url="https://api.azul.com/metadata/v1/zulu/packages/"
    url="${url}?os=${os_p}&arch=${arch_p}&archive_type=tar.gz"
    url="${url}&java_package_type=jdk&javafx_bundled=false&release_status=ga"
    url="${url}&latest=true&include_fields=sha256_hash"
    if [[ -n "$version_filter" ]]; then
        url="${url}&java_version=${version_filter}"
    fi

    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
        log_error "Failed to query Zulu API" >&2
        return 1
    }

    local link sha jv
    link=$(echo "$response" | jq -r '.[0].download_url')
    sha=$(echo "$response" | jq -r '.[0].sha256_hash')
    jv=$(echo "$response" | jq -r '.[0].java_version | join(".")')
    if [[ -z "$link" || "$link" == "null" || -z "$sha" || "$sha" == "null" ]]; then
        log_error "Zulu: no matching package for filter='${version_filter}', os=${os_p}, arch=${arch_p}" >&2
        return 1
    fi
    echo "$link"
    echo "$sha"
    echo "$jv"
}

_zulu_resolve_version() {
    local input="$1"
    local out
    out=$(_zulu_query "$input") || return 1
    echo "$out" | sed -n '3p'
}

_zulu_download_info() {
    local version="$1"
    local out
    out=$(_zulu_query "$version") || return 1
    echo "$out" | sed -n '1p'
    echo "$out" | sed -n '2p'
    echo "sha256"
}

_zulu_available() {
    local major_version="$1"
    local os_p arch_p
    os_p=$(_zulu_os)
    arch_p=$(_zulu_arch)

    if [[ -z "$major_version" ]]; then
        log_info "Fetching available Java major releases from Zulu..." >&2
        local url="https://api.azul.com/metadata/v1/zulu/packages/"
        url="${url}?os=${os_p}&arch=${arch_p}&archive_type=tar.gz"
        url="${url}&java_package_type=jdk&javafx_bundled=false&release_status=ga"
        url="${url}&latest_per_version=true&include_fields=java_version"
        local response
        response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
            log_error "Failed to query Zulu API" >&2
            return 1
        }
        log_info "Available Zulu major releases:"
        echo "$response" | jq -r '[.[].java_version[0]] | unique[]' | sort -n \
            | dtm_emit_version_list
        return 0
    fi

    if ! [[ "$major_version" =~ ^[0-9]+$ ]]; then
        log_error "Java filter must be a major version number (e.g. 11, 17, 21)"
        return 1
    fi

    log_info "Fetching available Zulu $major_version GA versions..." >&2
    local url="https://api.azul.com/metadata/v1/zulu/packages/"
    url="${url}?os=${os_p}&arch=${arch_p}&archive_type=tar.gz"
    url="${url}&java_package_type=jdk&javafx_bundled=false&release_status=ga"
    url="${url}&java_version=${major_version}&include_fields=java_version&page_size=200"

    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
        log_error "Failed to query Zulu API" >&2
        return 1
    }
    local versions
    versions=$(echo "$response" | jq -r '.[].java_version | join(".")' | sort -V -u)
    if [[ -z "$versions" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No GA versions found for Zulu $major_version"; fi
        return 1
    fi
    log_info "Available Zulu $major_version GA versions:"
    echo "$versions" | dtm_emit_version_list
}

# ---------------------------------------------------------------------------
# Corretto (Amazon)
# ---------------------------------------------------------------------------

_corretto_os() {
    case "$OS" in
        linux) echo "linux" ;;
        mac)   echo "macos" ;;
    esac
}

_corretto_arch() {
    case "$ARCH" in
        x64)     echo "x64" ;;
        aarch64) echo "aarch64" ;;
    esac
}

# Resolve major to current latest patch via redirect.
# Input must be a major (e.g. "21"); exact-version specs are validated against
# whatever current latest resolves to.
_corretto_resolve_version() {
    local input="$1"
    local major_version
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        major_version="$input"
    else
        major_version="${input%%.*}"
    fi

    local os_p arch_p
    os_p=$(_corretto_os)
    arch_p=$(_corretto_arch)

    local latest_url="https://corretto.aws/downloads/latest/amazon-corretto-${major_version}-${arch_p}-${os_p}-jdk.tar.gz"
    log_info "Resolving Corretto $major_version latest..." >&2
    local resolved
    resolved=$(curl -fsSLI --retry 3 --retry-delay 2 \
        -o /dev/null -w '%{url_effective}' "$latest_url" 2>/dev/null) || {
        log_error "Failed to resolve Corretto $major_version" >&2
        return 1
    }

    # Resolved URL is .../resources/<version>/amazon-corretto-<version>-...
    local version
    version=$(echo "$resolved" | sed -n 's|.*/resources/\([^/]*\)/.*|\1|p')
    if [[ -z "$version" ]]; then
        log_error "Could not parse Corretto version from $resolved" >&2
        return 1
    fi

    if [[ ! "$input" =~ ^[0-9]+$ && "$input" != "$version" ]]; then
        log_error "Corretto only supports current-latest installs." >&2
        log_error "Requested $input, but latest of major $major_version is $version." >&2
        log_info "Run with 'corretto@${major_version}' for the latest." >&2
        return 1
    fi
    echo "$version"
}

_corretto_download_info() {
    local version="$1"
    local major_version="${version%%.*}"
    local os_p arch_p
    os_p=$(_corretto_os)
    arch_p=$(_corretto_arch)

    local file="amazon-corretto-${major_version}-${arch_p}-${os_p}-jdk.tar.gz"
    local url="https://corretto.aws/downloads/latest/${file}"
    local checksum
    checksum=$(curl -fsSL --retry 3 --retry-delay 2 \
        "https://corretto.aws/downloads/latest_sha256/${file}" 2>/dev/null) || {
        log_error "Failed to fetch Corretto checksum" >&2
        return 1
    }
    if [[ -z "$checksum" ]]; then
        log_error "Empty Corretto checksum response" >&2
        return 1
    fi
    echo "$url"
    echo "$checksum"
    echo "sha256"
}

_corretto_available() {
    local major_version="$1"
    if [[ -n "$major_version" ]]; then
        log_warn "Corretto only supports the current latest of each major; ignoring filter '$major_version'" >&2
    fi
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        printf '%s\n' 8 11 17 21 | dtm_json_string_array
        return 0
    fi
    log_info "Corretto-supported majors (per corretto-N repos on GitHub):"
    echo "    8  (corretto-8)"
    echo "    11 (corretto-11)"
    echo "    17 (corretto-17)"
    echo "    21 (corretto-21)"
    log_info "Use 'dtm pull java corretto@<major>' to install latest of a major" >&2
}

# ---------------------------------------------------------------------------
# Liberica (BellSoft)
# ---------------------------------------------------------------------------

_liberica_os() {
    case "$OS" in
        linux) echo "linux" ;;
        mac)   echo "macos" ;;
    esac
}

# Liberica uses (arch, bitness) pair. Echoes "<arch> <bitness>".
_liberica_arch_bits() {
    case "$ARCH" in
        x64)     echo "x86 64" ;;
        aarch64) echo "arm 64" ;;
    esac
}

# Outputs three lines on success: download_url, sha1, version
_liberica_query() {
    local mode="$1" version_filter="$2"
    local os_p ab
    os_p=$(_liberica_os)
    ab=$(_liberica_arch_bits)
    local arch_p="${ab%% *}" bits="${ab##* }"

    local url="https://api.bell-sw.com/v1/liberica/releases"
    url="${url}?os=${os_p}&arch=${arch_p}&bitness=${bits}"
    url="${url}&package-type=tar.gz&bundle-type=jdk"

    if [[ "$mode" == "latest-major" ]]; then
        url="${url}&version-feature=${version_filter}&version-modifier=latest"
    elif [[ "$mode" == "exact" ]]; then
        # Strip build suffix for filter; Liberica matches by version string.
        url="${url}&version=${version_filter}"
    fi

    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
        log_error "Failed to query Liberica API" >&2
        return 1
    }

    local link sha ver
    link=$(echo "$response" | jq -r '.[0].downloadUrl')
    sha=$(echo  "$response" | jq -r '.[0].sha1')
    ver=$(echo  "$response" | jq -r '.[0].version')
    if [[ -z "$link" || "$link" == "null" || -z "$sha" || "$sha" == "null" ]]; then
        log_error "Liberica: no matching package for $mode='$version_filter', os=${os_p}, arch=${arch_p}/${bits}" >&2
        return 1
    fi
    echo "$link"
    echo "$sha"
    echo "$ver"
}

_liberica_resolve_version() {
    local input="$1"
    local out mode
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        mode="latest-major"
    else
        mode="exact"
    fi
    out=$(_liberica_query "$mode" "$input") || return 1
    echo "$out" | sed -n '3p'
}

_liberica_download_info() {
    local version="$1"
    local out
    out=$(_liberica_query "exact" "$version") || return 1
    echo "$out" | sed -n '1p'
    echo "$out" | sed -n '2p'
    echo "sha1"
}

_liberica_available() {
    local major_version="$1"
    local os_p ab
    os_p=$(_liberica_os)
    ab=$(_liberica_arch_bits)
    local arch_p="${ab%% *}" bits="${ab##* }"

    if [[ -z "$major_version" ]]; then
        log_info "Fetching available Java major releases from Liberica..." >&2
        local url="https://api.bell-sw.com/v1/liberica/releases"
        url="${url}?os=${os_p}&arch=${arch_p}&bitness=${bits}"
        url="${url}&package-type=tar.gz&bundle-type=jdk"
        local response
        response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
            log_error "Failed to query Liberica API" >&2
            return 1
        }
        log_info "Available Liberica major releases:"
        echo "$response" | jq -r '[.[].featureVersion] | unique[]' | sort -n \
            | dtm_emit_version_list
        return 0
    fi

    if ! [[ "$major_version" =~ ^[0-9]+$ ]]; then
        log_error "Java filter must be a major version number (e.g. 11, 17, 21)"
        return 1
    fi

    log_info "Fetching available Liberica $major_version GA versions..." >&2
    local url="https://api.bell-sw.com/v1/liberica/releases"
    url="${url}?os=${os_p}&arch=${arch_p}&bitness=${bits}"
    url="${url}&package-type=tar.gz&bundle-type=jdk&version-feature=${major_version}"
    local response
    response=$(curl -fsSL --retry 3 --retry-delay 2 "$url" 2>/dev/null) || {
        log_error "Failed to query Liberica API" >&2
        return 1
    }
    local versions
    versions=$(echo "$response" | jq -r '.[] | select(.GA == true) | .version' | sort -V -u)
    if [[ -z "$versions" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_warn "No GA versions found for Liberica $major_version"; fi
        return 1
    fi
    log_info "Available Liberica $major_version GA versions:"
    echo "$versions" | dtm_emit_version_list
}

# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

_java_resolve_version() {
    local dist="$1" input="$2"
    case "$dist" in
        temurin)  _temurin_resolve_version  "$input" ;;
        zulu)     _zulu_resolve_version     "$input" ;;
        corretto) _corretto_resolve_version "$input" ;;
        liberica) _liberica_resolve_version "$input" ;;
        *) log_error "Unknown distribution: $dist" >&2; return 1 ;;
    esac
}

_java_download_info() {
    local dist="$1" version="$2"
    case "$dist" in
        temurin)  _temurin_download_info  "$version" ;;
        zulu)     _zulu_download_info     "$version" ;;
        corretto) _corretto_download_info "$version" ;;
        liberica) _liberica_download_info "$version" ;;
        *) log_error "Unknown distribution: $dist" >&2; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Top-level commands
# ---------------------------------------------------------------------------

pull_java() {
    local spec="$1"
    parse_java_spec "$spec" || exit 1
    local dist="$JAVA_DIST"
    local version_input="$JAVA_VERSION_SPEC"

    local exact_version
    if [[ "$version_input" =~ ^[0-9]+$ ]]; then
        log_info "Resolving latest $dist $version_input..."
        exact_version=$(_java_resolve_version "$dist" "$version_input") || exit 1
        log_info "Latest version: $exact_version"
    else
        exact_version=$(_java_resolve_version "$dist" "$version_input") || exit 1
        if [[ "$exact_version" != "$version_input" ]]; then
            log_info "Resolved $version_input -> $exact_version"
        fi
    fi

    mkdir -p "$JAVA_ROOT"

    local dir_name install_dir lock_path
    dir_name=$(java_dir_name "$dist" "$exact_version")
    install_dir="${JAVA_ROOT}/${dir_name}"
    lock_path="${install_dir}.lock"

    dtm_acquire_lock "$lock_path" || exit 1
    trap 'dtm_release_lock "'"$lock_path"'"' EXIT INT TERM

    if [[ -d "$install_dir" ]]; then
        log_warn "$dist $exact_version is already installed at $install_dir"
        if ! dtm_confirm "Do you want to reinstall? (y/N): "; then
            log_info "Installation cancelled"
            dtm_release_lock "$lock_path"
            trap - EXIT INT TERM
            return 0
        fi
        rm -rf "$install_dir"
    fi

    local download_info
    download_info=$(_java_download_info "$dist" "$exact_version") || exit 1

    local download_url expected_checksum checksum_algo
    download_url=$(echo "$download_info" | sed -n '1p')
    expected_checksum=$(echo "$download_info" | sed -n '2p')
    checksum_algo=$(echo "$download_info" | sed -n '3p')

    log_info "Downloading $dist JDK from: $download_url"

    local temp_dir
    temp_dir=$(mktemp -d)
    local download_file="${temp_dir}/jdk.tar.gz"

    if ! dtm_download "$download_url" "$download_file"; then
        log_error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi

    log_info "Verifying checksum (${checksum_algo})..."
    if ! verify_checksum "$download_file" "$expected_checksum" "$checksum_algo"; then
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

    # Some macOS JDK tarballs put bin/ inside Contents/Home/. Detect and flatten.
    if [[ ! -x "${install_dir}/bin/java" && -x "${install_dir}/Contents/Home/bin/java" ]]; then
        log_info "macOS bundle layout detected; flattening Contents/Home"
        local tmp_flatten="${install_dir}.flatten"
        mv "${install_dir}/Contents/Home" "$tmp_flatten"
        rm -rf "$install_dir"
        mv "$tmp_flatten" "$install_dir"
    fi

    rm -rf "$temp_dir"

    dtm_release_lock "$lock_path"
    trap - EXIT INT TERM

    log_success "$dist $exact_version installed successfully to $install_dir"
    log_info "Run 'dtm set java ${dist}@${exact_version}' to activate this version"
}

# Resolve an installed dir matching a spec. Echoes the absolute install dir.
# Spec accepted forms:
#   <major>            -> latest temurin matching major
#   <exact>            -> exact temurin install
#   <dist>@<major>     -> latest installed of dist for major
#   <dist>@<exact>     -> exact dist install
_resolve_installed_java() {
    local dist="$1" version="$2"
    local exact_dir="${JAVA_ROOT}/$(java_dir_name "$dist" "$version")"
    if [[ -d "$exact_dir" && ! -L "$exact_dir" ]]; then
        echo "$exact_dir"
        return 0
    fi

    local major
    major=$(echo "$version" | cut -d'.' -f1)
    local pattern
    if [[ "$dist" == "temurin" ]]; then
        pattern="${major}.*"
    else
        pattern="${dist}-${major}.*"
    fi
    local match
    # -type d skips the `current` symlink already.
    match=$(find "$JAVA_ROOT" -maxdepth 1 -mindepth 1 -type d -name "$pattern" 2>/dev/null | sort -V | tail -1)
    if [[ -n "$match" ]]; then
        echo "$match"
        return 0
    fi
    return 1
}

# Set Java version as active.
# Usage: set_java <spec> [mode]   mode: set | use
set_java() {
    local spec="$1"
    local mode="${2:-set}"
    parse_java_spec "$spec" || exit 1
    local dist="$JAVA_DIST"
    local version="$JAVA_VERSION_SPEC"

    local install_dir
    install_dir=$(_resolve_installed_java "$dist" "$version") || {
        log_error "$dist $version is not installed"
        log_info "Available versions:"
        list_java
        exit 1
    }

    local dir_label
    dir_label=$(basename "$install_dir")

    if [[ "$mode" == "set" ]]; then
        log_info "Setting Java to $dir_label..." >&2

        mkdir -p "$(dirname "$DTM_CONFIG")"
        dtm_clean_dtmrc_for "JAVA_HOME" "/java/.*/bin"
        dtm_set_current_symlink "$JAVA_ROOT" "$install_dir"

        local stable_path="${JAVA_ROOT}/current"
        cat >> "$DTM_CONFIG" << EOF
export JAVA_HOME="${stable_path}"
export PATH="\${JAVA_HOME}/bin:\${PATH}"
EOF

        log_success "Java $dir_label activated" >&2

        if [[ -f "${install_dir}/bin/java" ]]; then
            echo "" >&2
            log_info "Version details:" >&2
            "${install_dir}/bin/java" -version 2>&1 | head -3 >&2
            echo "" >&2
        fi

        log_info "Applying changes to current shell..." >&2

        echo "export JAVA_HOME=\"${stable_path}\""
        echo "export PATH=\"\${JAVA_HOME}/bin:\${PATH}\""
        return 0
    fi

    # `use` mode: per-shell only — emit direct install path, do not touch the
    # global symlink (other shells may rely on it).
    echo "export JAVA_HOME=\"${install_dir}\""
    echo "export PATH=\"\${JAVA_HOME}/bin:\${PATH}\""
}

# List installed Java versions (all distributions).
list_java() {
    if [[ ! -d "$JAVA_ROOT" ]]; then
        if [[ -n "$DTM_OUTPUT_JSON" ]]; then echo "[]"; else log_info "No Java versions installed"; fi
        return 0
    fi

    local current_java_home="${JAVA_HOME:-}"
    local active_resolved=""
    [[ -n "$current_java_home" && -e "$current_java_home" ]] && \
        active_resolved="$(dtm_resolved_path "$current_java_home")"

    local dir name dist version label

    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        local entries=()
        for dir in "$JAVA_ROOT"/*; do
            [[ -L "$dir" ]] && continue
            [[ -d "$dir" && -f "$dir/bin/java" ]] || continue
            name=$(basename "$dir")
            dist=$(java_dir_dist "$name")
            version=$(java_dir_version "$name")
            local active=false
            [[ "$dir" == "$active_resolved" ]] && active=true
            entries+=("$(jq -nc \
                --arg dist "$dist" \
                --arg version "$version" \
                --arg dir "$name" \
                --arg path "$dir" \
                --argjson active "$active" \
                '{dist:$dist,version:$version,dir:$dir,path:$path,active:$active}')")
        done
        if (( ${#entries[@]} == 0 )); then echo "[]"; else printf '%s\n' "${entries[@]}" | jq -s .; fi
        return 0
    fi

    log_info "Installed Java versions:"
    for dir in "$JAVA_ROOT"/*; do
        [[ -L "$dir" ]] && continue
        [[ -d "$dir" && -f "$dir/bin/java" ]] || continue
        name=$(basename "$dir")
        dist=$(java_dir_dist "$name")
        version=$(java_dir_version "$name")
        label="${dist}@${version}    ($name)"
        if [[ "$dir" == "$active_resolved" ]]; then
            echo -e "  ${GREEN}* ${label}${NC} (active)"
        else
            echo "    ${label}"
        fi
    done
}

# Available remote versions.
# Usage: available_java [filter]
#   filter forms:
#     (empty)          -> Temurin majors
#     <major>          -> Temurin patches for major
#     <dist>           -> majors for dist
#     <dist>@<major>   -> patches for dist+major
available_java() {
    local filter="$1"
    local dist major

    if [[ -z "$filter" ]]; then
        dist="$JAVA_DIST_DEFAULT"
        major=""
    elif [[ "$filter" == *"@"* ]]; then
        parse_java_spec "$filter" || return 1
        dist="$JAVA_DIST"
        major="$JAVA_VERSION_SPEC"
    elif [[ "$filter" =~ ^[0-9]+$ ]]; then
        dist="$JAVA_DIST_DEFAULT"
        major="$filter"
    else
        # Bare distribution name.
        local d valid=0
        for d in "${JAVA_DISTS_SUPPORTED[@]}"; do
            [[ "$d" == "$filter" ]] && { valid=1; break; }
        done
        if (( ! valid )); then
            log_error "Unrecognised filter: $filter"
            log_info "Use a major number, a dist (${JAVA_DISTS_SUPPORTED[*]}), or '<dist>@<major>'"
            return 1
        fi
        dist="$filter"
        major=""
    fi

    case "$dist" in
        temurin)  _temurin_available  "$major" ;;
        zulu)     _zulu_available     "$major" ;;
        corretto) _corretto_available "$major" ;;
        liberica) _liberica_available "$major" ;;
    esac
}

# Print currently active Java version (or fail if none).
current_java() {
    local current_java_home="${JAVA_HOME:-}"
    if [[ -z "$current_java_home" ]]; then
        log_warn "No active Java version (JAVA_HOME not set)" >&2
        return 1
    fi
    if [[ "$current_java_home" != "$JAVA_ROOT"/* ]]; then
        log_warn "Active JAVA_HOME is not managed by dtm: $current_java_home" >&2
        return 1
    fi
    if [[ ! -x "$current_java_home/bin/java" ]]; then
        log_warn "Active Java install is missing: $current_java_home" >&2
        return 1
    fi
    local resolved name dist version
    resolved="$(dtm_resolved_path "$current_java_home")"
    name=$(basename "$resolved")
    dist=$(java_dir_dist "$name")
    version=$(java_dir_version "$name")
    if [[ -n "$DTM_OUTPUT_JSON" ]]; then
        jq -nc \
            --arg tool "java" \
            --arg dist "$dist" \
            --arg version "$version" \
            --arg dir "$name" \
            --arg path "$resolved" \
            --arg link "$current_java_home" \
            '{tool:$tool,dist:$dist,version:$version,dir:$dir,path:$path,link:$link}'
        return 0
    fi
    echo "${dist}@${version}"
}

# Update active Java to latest patch in the current major series, preserving dist.
update_java() {
    local current_java_home="${JAVA_HOME:-}"
    if [[ -z "$current_java_home" || "$current_java_home" != "$JAVA_ROOT"/* ]]; then
        log_error "No dtm-managed active Java version to update"
        exit 1
    fi
    local name dist version major latest install_dir
    name=$(basename "$current_java_home")
    dist=$(java_dir_dist "$name")
    version=$(java_dir_version "$name")
    major="${version%%.*}"
    log_info "Active Java: ${dist}@${version} (major $major)" >&2

    latest=$(_java_resolve_version "$dist" "$major") || exit 1
    log_info "Latest $dist $major: $latest" >&2

    if [[ "$latest" == "$version" ]]; then
        log_success "${dist}@${version} is already the latest patch" >&2
        return 0
    fi

    install_dir="${JAVA_ROOT}/$(java_dir_name "$dist" "$latest")"
    if [[ ! -d "$install_dir" || -L "$install_dir" ]]; then
        pull_java "${dist}@${latest}"
    else
        log_info "${dist}@${latest} already installed; switching only" >&2
    fi

    set_java "${dist}@${latest}" set
}

# Remove Java version.
# Usage: remove_java <spec>
remove_java() {
    local spec="$1"
    parse_java_spec "$spec" || exit 1
    local dist="$JAVA_DIST" version="$JAVA_VERSION_SPEC"

    local install_dir
    install_dir=$(_resolve_installed_java "$dist" "$version") || {
        log_error "$dist $version is not installed"
        return 1
    }

    log_warn "About to remove $(basename "$install_dir") from $install_dir"
    if dtm_confirm "Are you sure? (y/N): "; then
        # If `current` symlink points at this dir, drop it too.
        if [[ -L "${JAVA_ROOT}/current" ]]; then
            local cur_target
            cur_target="$(dtm_resolved_path "${JAVA_ROOT}/current" 2>/dev/null || true)"
            if [[ "$cur_target" == "$install_dir" ]]; then
                rm -f "${JAVA_ROOT}/current"
            fi
        fi
        rm -rf "$install_dir"
        log_success "$(basename "$install_dir") removed"
    else
        log_info "Removal cancelled"
    fi
}
