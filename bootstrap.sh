#!/usr/bin/env bash
#
# DevTool Manager (dtm) — remote bootstrap installer.
#
# Designed for `curl -fsSL <url>/bootstrap.sh | bash`. The whole script is
# wrapped in a function so a truncated download cannot execute partial logic.
#
# Env overrides:
#   DTM_REPO     git URL to clone (default: https://github.com/HeshanSudarshana/devtool-manager.git)
#   DTM_REF      branch, tag, or commit to check out (default: main)
#   DTM_SRC_DIR  where to clone the source tree (default: ~/.local/share/devtool-manager)
#
# Extra args are forwarded to install.sh, e.g.:
#   curl -fsSL <url>/bootstrap.sh | bash -s -- --yes

set -euo pipefail

dtm_bootstrap() {
    local repo="${DTM_REPO:-https://github.com/HeshanSudarshana/devtool-manager.git}"
    local ref="${DTM_REF:-main}"
    local src_dir="${DTM_SRC_DIR:-${HOME}/.local/share/devtool-manager}"

    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required. Install git and re-run." >&2
        echo "  (dtm self-update also relies on the install dir being a git checkout.)" >&2
        exit 1
    fi

    echo "DevTool Manager bootstrap"
    echo "  repo: $repo"
    echo "  ref:  $ref"
    echo "  dir:  $src_dir"
    echo

    if [[ -e "$src_dir" && ! -d "$src_dir/.git" ]]; then
        echo "Error: $src_dir exists but is not a git checkout." >&2
        echo "Move or remove it, or set DTM_SRC_DIR to another path." >&2
        exit 1
    fi

    if [[ -d "$src_dir/.git" ]]; then
        echo "Updating existing checkout..."
        git -C "$src_dir" fetch --tags origin
        git -C "$src_dir" checkout "$ref"
        # Fast-forward only when on a branch; detached HEAD (tag/commit) skips pull.
        if git -C "$src_dir" symbolic-ref -q HEAD >/dev/null; then
            git -C "$src_dir" pull --ff-only origin "$ref"
        fi
    else
        mkdir -p "$(dirname "$src_dir")"
        echo "Cloning..."
        git clone "$repo" "$src_dir"
        git -C "$src_dir" checkout "$ref"
    fi

    echo
    echo "Running installer..."
    exec bash "$src_dir/install.sh" "$@"
}

dtm_bootstrap "$@"
