# Bash completion for dtm (DevTool Manager)
#
# Source from your ~/.bashrc:
#   source /path/to/devtool-manager/completions/dtm.bash

_dtm_root() {
    if [[ -n "$DTM_HOME" ]]; then
        printf '%s\n' "$DTM_HOME"
    elif [[ -f "$HOME/.dtmconfig" ]]; then
        local line
        line=$(grep -E '^[[:space:]]*export[[:space:]]+DTM_HOME=' "$HOME/.dtmconfig" 2>/dev/null | tail -1)
        line="${line#*=}"
        line="${line%\"}"; line="${line#\"}"
        line="${line%\'}"; line="${line#\'}"
        if [[ -n "$line" ]]; then
            eval "printf '%s\n' $line" 2>/dev/null || printf '%s\n' "$line"
        else
            printf '%s\n' "$HOME/development/devtools"
        fi
    else
        printf '%s\n' "$HOME/development/devtools"
    fi
}

_dtm_installed_versions() {
    local tool="$1" root dir name
    root="$(_dtm_root)/$tool"
    [[ -d "$root" ]] || return 0
    for dir in "$root"/*/; do
        [[ -d "$dir" ]] || continue
        # Skip the active-version symlink (`current/`).
        [[ -L "${dir%/}" ]] && continue
        name="${dir%/}"
        printf '%s\n' "${name##*/}"
    done
}

_dtm() {
    local cur prev words cword
    _init_completion -n =: 2>/dev/null || {
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        words=("${COMP_WORDS[@]}")
        cword=$COMP_CWORD
    }

    local commands="pull set use list current available update remove doctor self-update uninstall config"
    # Pull the live tool list from dtm so newly-added candidate descriptors
    # show up without editing this file. Fall back to the legacy modules if
    # dtm isn't on PATH yet (e.g. during install).
    local tools
    tools=$(command dtm tools 2>/dev/null | tr '\n' ' ')
    [[ -z "$tools" ]] && tools="java node python"
    local versioned_cmds="pull set use remove"
    local tool_only_cmds="list current available update"

    if (( cword == 1 )); then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return 0
    fi

    local cmd="${words[1]}"

    case "$cmd" in
        doctor|self-update|uninstall)
            COMPREPLY=()
            return 0
            ;;
        config)
            if (( cword == 2 )); then
                COMPREPLY=( $(compgen -W "home" -- "$cur") )
            elif (( cword == 3 )) && [[ "${words[2]}" == "home" ]]; then
                COMPREPLY=( $(compgen -d -- "$cur") )
            fi
            return 0
            ;;
    esac

    if [[ " $versioned_cmds $tool_only_cmds " == *" $cmd "* ]]; then
        if (( cword == 2 )); then
            COMPREPLY=( $(compgen -W "$tools" -- "$cur") )
            return 0
        fi
    fi

    if (( cword == 3 )); then
        local tool="${words[2]}"
        case "$cmd" in
            set|use|remove)
                local versions
                versions=$(_dtm_installed_versions "$tool")
                COMPREPLY=( $(compgen -W "$versions" -- "$cur") )
                return 0
                ;;
            available)
                if [[ "$tool" == "java" ]]; then
                    COMPREPLY=( $(compgen -W "temurin zulu corretto liberica 8 11 17 21" -- "$cur") )
                fi
                return 0
                ;;
            pull)
                return 0
                ;;
        esac
    fi

    return 0
}

complete -F _dtm dtm
