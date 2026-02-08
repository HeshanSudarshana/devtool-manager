#!/usr/bin/env bash

# Simple installation script for dtm

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"

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
    echo "" >> "$SHELL_RC"
    echo "# DevTool Manager - auto-apply wrapper" >> "$SHELL_RC"
    echo "source \"${SCRIPT_DIR}/dtm.sh\"" >> "$SHELL_RC"
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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Optional: Install Node.js and Python managers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "dtm can manage Node.js and Python using nvm and pyenv."
echo ""

# Check for nvm
if ! command -v nvm &> /dev/null && [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    read -p "Install nvm for Node.js management? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Installing nvm from master branch..."
        if curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash; then
            echo "✓ nvm installed successfully"
            echo ""
            echo "To use nvm in this session, run:"
            echo "  source ~/.nvm/nvm.sh"
        else
            echo "✗ Failed to install nvm"
        fi
    fi
else
    echo "✓ nvm is already installed"
fi

echo ""

# Check for pyenv
if ! command -v pyenv &> /dev/null && [ ! -s "$HOME/.pyenv/bin/pyenv" ]; then
    read -p "Install pyenv for Python management? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "Installing pyenv and build dependencies..."
        echo "Note: Unlike Node.js (pre-built binaries), Python must be compiled from source."
        echo "Build tools and libraries are needed to compile Python successfully."
        echo "This may require sudo password."
        echo ""
        
        # Detect OS and install dependencies
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            if command -v pacman &> /dev/null; then
                echo "Detected Arch Linux - installing build dependencies..."
                sudo pacman -S --needed --noconfirm base-devel openssl zlib xz tk
            elif command -v apt-get &> /dev/null; then
                echo "Detected Debian/Ubuntu - installing build dependencies..."
                sudo apt-get update
                sudo apt-get install -y make build-essential libssl-dev zlib1g-dev \
                    libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm \
                    libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
                    libffi-dev liblzma-dev
            elif command -v yum &> /dev/null; then
                echo "Detected RHEL/CentOS/Fedora - installing build dependencies..."
                sudo yum install -y gcc zlib-devel bzip2 bzip2-devel readline-devel \
                    sqlite sqlite-devel openssl-devel tk-devel libffi-devel xz-devel
            else
                echo "Unknown Linux distribution. Please install build dependencies manually."
                echo "Visit: https://github.com/pyenv/pyenv/wiki#suggested-build-environment"
            fi
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            echo "On macOS, make sure Xcode Command Line Tools are installed"
            echo "Run: xcode-select --install (if not already installed)"
        fi
        
        # Install pyenv
        if curl https://pyenv.run | bash; then
            echo "✓ pyenv installed successfully"
            echo ""
            echo "Add these to your $SHELL_RC:"
            echo "  export PYENV_ROOT=\"\$HOME/.pyenv\""
            echo "  export PATH=\"\$PYENV_ROOT/bin:\$PATH\""
            echo "  eval \"\$(pyenv init -)\""
        else
            echo "✗ Failed to install pyenv"
        fi
    fi
else
    echo "✓ pyenv is already installed"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Installation complete! Try these commands:"
echo "  dtm pull java 11      # Native Java management"
echo "  dtm pull go 1.21      # Native Go management"
echo "  dtm pull node 20      # Via nvm"
echo "  dtm pull python 3.12  # Via pyenv"
