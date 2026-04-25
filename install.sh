#!/usr/bin/env bash

# Simple installation script for dtm

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"

# Parse flags. --yes/-y skips interactive prompts (treats them as "no" unless
# the prompt explicitly opts in via the flag). DTM_ASSUME_YES env also honored.
ASSUME_YES="${DTM_ASSUME_YES:-}"
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
    esac
done

# Prompt helper: returns 0 if the user answered yes (or --yes was passed),
# 1 otherwise. Non-TTY stdin without --yes silently declines.
confirm() {
    local prompt="$1"
    if [[ -n "$ASSUME_YES" ]]; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        return 1
    fi
    local reply
    read -p "$prompt" -n 1 -r reply
    echo
    [[ $reply =~ ^[Yy]$ ]]
}

echo "Installing DevTool Manager (dtm)..."

# Create installation directory if it doesn't exist
mkdir -p "$INSTALL_DIR"

# Create symlink
if [ -L "${INSTALL_DIR}/dtm" ]; then
    echo "Removing existing symlink..."
    rm "${INSTALL_DIR}/dtm"
fi

ln -s "${SCRIPT_DIR}/dtm" "${INSTALL_DIR}/dtm"

echo "✓ dtm installed to ${INSTALL_DIR}/dtm"

# Detect active/default shell and choose the right rc file (before PATH/rc messages)
# Use $SHELL (login shell) or fall back to getent; script may be run with bash even when user uses zsh
ACTIVE_SHELL="${SHELL##*/}"
if [ -z "$ACTIVE_SHELL" ]; then
    ACTIVE_SHELL="$(getent passwd "$(whoami)" 2>/dev/null | cut -d: -f7)"
    ACTIVE_SHELL="${ACTIVE_SHELL##*/}"
fi
case "$ACTIVE_SHELL" in
    zsh)  SHELL_RC="${HOME}/.zshrc" ;;
    bash) SHELL_RC="${HOME}/.bashrc" ;;
    ksh)  SHELL_RC="${HOME}/.kshrc" ;;
    fish) SHELL_RC="${HOME}/.config/fish/config.fish" ;;
    *)
        SHELL_RC="${HOME}/.bashrc"
        echo "Note: Unknown shell '$ACTIVE_SHELL', defaulting to ~/.bashrc"
        ;;
esac

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
    echo ""
    echo "Warning: ${INSTALL_DIR} is not in your PATH"
    echo "Add this to your $SHELL_RC:"
    echo ""
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    echo ""
fi

# Add dtm.sh source to shell config for auto-apply functionality
if ! grep -q "source.*dtm.sh" "$SHELL_RC" 2>/dev/null; then
    echo ""
    echo "Adding dtm auto-apply wrapper to $SHELL_RC..."
    {
        echo ""
        echo "# DevTool Manager - auto-apply wrapper"
        echo "source \"${SCRIPT_DIR}/dtm.sh\""
    } >> "$SHELL_RC"
    echo "✓ Added to $SHELL_RC"
    echo ""
    echo "To use immediately in this session, run:"
    echo "  source $SHELL_RC"
fi

if ! grep -q "source.*\.dtmrc" "$SHELL_RC" 2>/dev/null; then
    echo ""
    echo "Note: Add this to your $SHELL_RC for persistent configuration:"
    echo ""
    echo "  # Load dtm configuration"
    echo "  if [ -f ~/.dtmrc ]; then"
    echo "      source ~/.dtmrc"
    echo "  fi"
    echo ""
fi

if ! grep -q "source.*\.dtmconfig" "$SHELL_RC" 2>/dev/null; then
    echo ""
    echo "Note: Add this to your $SHELL_RC to load DTM_HOME configuration:"
    echo ""
    echo "  # Load dtm home configuration"
    echo "  if [ -f ~/.dtmconfig ]; then"
    echo "      source ~/.dtmconfig"
    echo "  fi"
    echo ""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Shell completion"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

COMPLETIONS_DIR="${SCRIPT_DIR}/completions"
case "$ACTIVE_SHELL" in
    bash)
        if ! grep -q "completions/dtm.bash" "$SHELL_RC" 2>/dev/null; then
            {
                echo ""
                echo "# DevTool Manager - bash completion"
                echo "[ -f \"${COMPLETIONS_DIR}/dtm.bash\" ] && source \"${COMPLETIONS_DIR}/dtm.bash\""
            } >> "$SHELL_RC"
            echo "✓ Added bash completion source to $SHELL_RC"
        else
            echo "✓ bash completion already wired into $SHELL_RC"
        fi
        ;;
    zsh)
        ZSH_COMP_DIR="${HOME}/.zsh/completions"
        mkdir -p "$ZSH_COMP_DIR"
        if [ -L "${ZSH_COMP_DIR}/_dtm" ] || [ -e "${ZSH_COMP_DIR}/_dtm" ]; then
            rm -f "${ZSH_COMP_DIR}/_dtm"
        fi
        ln -s "${COMPLETIONS_DIR}/_dtm" "${ZSH_COMP_DIR}/_dtm"
        echo "✓ Linked zsh completion to ${ZSH_COMP_DIR}/_dtm"
        if ! grep -q "${ZSH_COMP_DIR}" "$SHELL_RC" 2>/dev/null; then
            echo ""
            echo "Add this to your $SHELL_RC BEFORE 'compinit':"
            echo "  fpath=(${ZSH_COMP_DIR} \$fpath)"
            echo "Then run: rm -f ~/.zcompdump && compinit"
        fi
        ;;
    fish)
        FISH_COMP_DIR="${HOME}/.config/fish/completions"
        mkdir -p "$FISH_COMP_DIR"
        if [ -L "${FISH_COMP_DIR}/dtm.fish" ] || [ -e "${FISH_COMP_DIR}/dtm.fish" ]; then
            rm -f "${FISH_COMP_DIR}/dtm.fish"
        fi
        ln -s "${COMPLETIONS_DIR}/dtm.fish" "${FISH_COMP_DIR}/dtm.fish"
        echo "✓ Linked fish completion to ${FISH_COMP_DIR}/dtm.fish"
        ;;
    *)
        echo "Skipping completion install for shell '$ACTIVE_SHELL'"
        echo "Manual install files in: ${COMPLETIONS_DIR}"
        ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DTM Home Directory"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "By default, dtm installs tools to: ~/development/devtools"
echo ""
echo "To customize the installation directory, use:"
echo "  dtm config home /your/custom/path"
echo ""

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Installation complete! Try these commands:"
echo "  dtm pull java 11      # Native Java management"
echo "  dtm pull go 1.21      # Native Go management"
echo "  dtm pull node lts     # Native Node management"
echo "  dtm pull python 3.12  # Native Python (python-build-standalone)"
