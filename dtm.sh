#!/usr/bin/env bash
# Shell function wrapper for dtm to auto-apply environment changes
# Add this to your ~/.bashrc or ~/.zshrc:
#   source /home/heshan/development/devtools/devtool-manager/dtm.sh
#
# Optional: enable .tool-versions auto-switch on cd by exporting before sourcing:
#   export DTM_AUTO_SWITCH=1

# Resolve dtm binary: env override > PATH lookup > default fallback.
# `type -P` is used instead of `command -v` so a previously-defined `dtm`
# shell function (from a prior source of this file) is skipped.
if [[ -z "${DTM_BIN:-}" ]]; then
    DTM_BIN="$(type -P dtm 2>/dev/null || true)"
fi
DTM_BIN="${DTM_BIN:-${HOME}/.local/bin/dtm}"

# Wrapper function that evals the output of 'dtm set' / 'dtm use' commands.
# Exports DTM_WRAPPED=1 so the binary can detect that its stdout will be
# eval'd and skip the "wrapper not detected" warning.
dtm() {
    local subcmd="$1"

    if [[ "$subcmd" == "set" || "$subcmd" == "use" || "$subcmd" == "update" ]]; then
        local exports
        exports=$(DTM_WRAPPED=1 "$DTM_BIN" "$@")
        local exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            eval "$exports"
            if [[ "$subcmd" == "set" || "$subcmd" == "update" ]]; then
                echo "✓ Changes applied to current shell"
            fi
        fi
        return $exit_code
    else
        "$DTM_BIN" "$@"
    fi
}

# --- .tool-versions auto-switch (asdf-style) -----------------------------
# Opt in by exporting DTM_AUTO_SWITCH=1 before sourcing this file.

# Walk up from $PWD until a .tool-versions file is found. Echoes its path.
_dtm_find_tool_versions() {
    local dir="${1:-$PWD}"
    while [[ -n "$dir" && "$dir" != "/" ]]; do
        if [[ -f "$dir/.tool-versions" ]]; then
            echo "$dir/.tool-versions"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    if [[ -f "/.tool-versions" ]]; then
        echo "/.tool-versions"
        return 0
    fi
    return 1
}

_dtm_file_mtime() {
    local f="$1"
    if stat -c %Y "$f" 2>/dev/null; then
        return 0
    fi
    stat -f %m "$f" 2>/dev/null
}

# Apply the nearest .tool-versions to the current shell. No-op if path+mtime
# match the last applied file, so safe to invoke from prompt hooks.
_dtm_apply_tool_versions() {
    local file mtime
    if ! file=$(_dtm_find_tool_versions); then
        _DTM_LAST_TOOL_VERSIONS_PATH=""
        _DTM_LAST_TOOL_VERSIONS_MTIME=""
        return 0
    fi

    mtime=$(_dtm_file_mtime "$file")
    if [[ "$file" == "$_DTM_LAST_TOOL_VERSIONS_PATH" \
        && "$mtime" == "$_DTM_LAST_TOOL_VERSIONS_MTIME" ]]; then
        return 0
    fi

    local applied=()
    local tool version line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        # trim leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        tool="${line%% *}"
        version="${line#* }"
        version="${version%% *}"
        [[ -z "$tool" || -z "$version" || "$tool" == "$version" ]] && continue

        # asdf compatibility aliases
        case "$tool" in
            nodejs) tool=node ;;
            golang) tool=go ;;
        esac

        # Try to activate via dtm. Tools dtm doesn't recognise simply fail
        # silently — no need to maintain a parallel allowlist here.
        local exports
        if exports=$(DTM_WRAPPED=1 "$DTM_BIN" use "$tool" "$version" 2>/dev/null); then
            eval "$exports"
            applied+=("${tool}@${version}")
        fi
    done < "$file"

    _DTM_LAST_TOOL_VERSIONS_PATH="$file"
    _DTM_LAST_TOOL_VERSIONS_MTIME="$mtime"

    if (( ${#applied[@]} > 0 )); then
        echo "✓ dtm: applied ${applied[*]} from $file"
    fi
}

if [[ -n "$DTM_AUTO_SWITCH" ]]; then
    if [[ -n "$ZSH_VERSION" ]]; then
        autoload -U add-zsh-hook 2>/dev/null
        add-zsh-hook chpwd _dtm_apply_tool_versions 2>/dev/null
    elif [[ -n "$BASH_VERSION" ]]; then
        case "$PROMPT_COMMAND" in
            *_dtm_apply_tool_versions*) ;;
            *) PROMPT_COMMAND="_dtm_apply_tool_versions${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
        esac
    fi
    _dtm_apply_tool_versions
fi
