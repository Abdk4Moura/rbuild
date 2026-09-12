# Shared config loading for rbuild and rbuild-cs. Sourced, not executed.
#
# Per-project settings live in a `.rbuild` file at the source repo root,
# KEY=VALUE per line, `#` comments allowed. Known keys:
#   MANIFEST_DIR  dir with the Cargo.toml to build      (default .)
#   BIN           binary name to collect                (default: repo name)
#   TARGET        rust target triple                    (default x86_64-unknown-linux-musl)
#   FEATURES      feature flags, verbatim               (default empty)
#   DISPATCH_REPO owner/name of the builder repo        (default Abdk4Moura/rbuild)
#   CS            reserve codespace name                (rbuild-cs only)
#   CS_DIR        checkout dir on the codespace         (default /workspaces/<repo name>)
# Environment variables RBUILD_<KEY> override the file; flags override both.

rb_need() { command -v "$1" >/dev/null 2>&1 || { echo "rbuild: missing $1" >&2; exit 2; }; }

rb_load_config() {
  rb_need git; rb_need gh; rb_need jq
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  SRC_REPO="${RBUILD_REPO:-$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
  REPO_NAME="${SRC_REPO##*/}"
  MANIFEST_DIR="."; BIN="$REPO_NAME"; TARGET="x86_64-unknown-linux-musl"; FEATURES=""
  DISPATCH_REPO="Abdk4Moura/rbuild"; CS=""; CS_DIR=""
  if [ -f "$ROOT/.rbuild" ]; then
    while IFS='=' read -r k v; do
      k="${k%%#*}"; k="$(echo "$k" | tr -d '[:space:]')"; [ -n "$k" ] || continue
      v="${v%%#*}"; v="$(echo "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      case "$k" in
        MANIFEST_DIR|BIN|TARGET|FEATURES|DISPATCH_REPO|CS|CS_DIR) printf -v "$k" '%s' "$v" ;;
        *) echo "rbuild: .rbuild: unknown key $k (ignored)" >&2 ;;
      esac
    done < "$ROOT/.rbuild"
  fi
  MANIFEST_DIR="${RBUILD_MANIFEST_DIR:-$MANIFEST_DIR}"
  BIN="${RBUILD_BIN:-$BIN}"
  TARGET="${RBUILD_TARGET:-$TARGET}"
  FEATURES="${RBUILD_FEATURES:-$FEATURES}"
  DISPATCH_REPO="${RBUILD_DISPATCH_REPO:-$DISPATCH_REPO}"
  CS="${RBUILD_CS:-$CS}"
  CS_DIR="${RBUILD_CS_DIR:-${CS_DIR:-/workspaces/$REPO_NAME}}"
}
