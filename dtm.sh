#!/usr/bin/env bash
# Shell function wrapper for dtm to auto-apply environment changes
# Add this to your ~/.bashrc or ~/.zshrc:
#   source /home/heshan/development/devtools/devtool-manager/dtm.sh

# Wrapper function that evals the output of 'dtm set' commands
dtm() {
    local dtm_bin="${HOME}/.local/bin/dtm"
    
    # Check if it's a 'set' command
    if [[ "$1" == "set" ]]; then
        # Capture stdout (export commands) and let stderr pass through
        local exports
        exports=$("$dtm_bin" "$@")
        local exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            # Eval the export commands
            eval "$exports"
            echo "✓ Changes applied to current shell"
        fi
        return $exit_code
    else
        # For all other commands, just run normally
        "$dtm_bin" "$@"
    fi
}
