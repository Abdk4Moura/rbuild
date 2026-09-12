#!/usr/bin/env bash
# Symlink rbuild into ~/.local/bin (or $1).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; DEST="${1:-$HOME/.local/bin}"
mkdir -p "$DEST"
ln -sfn "$HERE/bin/rbuild" "$DEST/rbuild"
echo "installed: $DEST/rbuild -> $HERE/bin/rbuild"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "note: $DEST is not on PATH" ;; esac
