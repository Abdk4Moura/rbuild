# Shared config loading for rbuild and rbuild-cs. Sourced, not executed.
#
# Settings come from three layers, each overriding the previous:
#   1. ~/.config/rbuild/config      user-level, KEY=VALUE (machine defaults, e.g. CS_SSH)
#   2. <source repo root>/.rbuild   per-project, same format
#   3. RBUILD_<KEY> environment variables; flags override all three.
# `#` comments allowed. Known keys:
#   MANIFEST_DIR  dir with the Cargo.toml to build      (default .)
#   BIN           binary name to collect                (default: repo name)
#   TARGET        rust target triple                    (default x86_64-unknown-linux-musl)
#   FEATURES      feature flags, verbatim               (default empty)
#   DISPATCH_REPO owner/name of the builder repo        (default Abdk4Moura/rbuild)
#   CS            reserve codespace name                (rbuild-cs, codespace backend)
#   CS_DIR        checkout dir on the remote            (default /workspaces/<repo> on a
#                                                        codespace, ~/rbuild/<repo> over ssh)
#   CS_SSH        user@host of a persistent build host; when set, `rbuild cs` talks
#                 to it over plain ssh instead of the codespace (BACKEND=ssh)
#   CS_SSH_PROXY  optional ProxyCommand for that host (e.g. filament forward --stdio host:22)
#   CS_SSH_KEY    identity file for that host           (default ~/.ssh/rbuild_ed25519)
#   CS_SSH_PORT   ssh port                              (default 22)
#   SYNC_EXCLUDE  comma-separated paths `rbuild cs sync/dev` skip (besides .git, target, node_modules)
#   CS_TARGET_DIR remote CARGO_TARGET_DIR; lets several checkouts (one CS_DIR per agent) share one
#                 target dir on a small disk. cargo serializes concurrent builds on its lock.
# BACKEND=codespace|ssh in a config file sets the default even when CS_SSH is set.
# RBUILD_BACKEND=codespace ignores CS_SSH for one invocation (RBUILD_BACKEND=ssh
# forces the other way). rb_load_config exports BACKEND as `ssh` or `codespace`.

rb_need() { command -v "$1" >/dev/null 2>&1 || { echo "rbuild: missing $1" >&2; exit 2; }; }

RB_KEYS="MANIFEST_DIR BIN TARGET FEATURES DISPATCH_REPO CS CS_DIR CS_SSH CS_SSH_PROXY CS_SSH_KEY CS_SSH_PORT SYNC_EXCLUDE BACKEND CS_TARGET_DIR"

rb_read_file() {  # rb_read_file <path>: assign every known KEY=VALUE line
  local k v
  while IFS='=' read -r k v; do
    k="${k%%#*}"; k="$(echo "$k" | tr -d '[:space:]')"; [ -n "$k" ] || continue
    v="${v%%#*}"; v="$(echo "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case " $RB_KEYS " in
      *" $k "*) printf -v "$k" '%s' "$v" ;;
      *) echo "rbuild: $1: unknown key $k (ignored)" >&2 ;;
    esac
  done < "$1"
}

rb_load_config() {
  rb_need git; rb_need gh; rb_need jq
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  SRC_REPO="${RBUILD_REPO:-$(cd "$ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
  REPO_NAME="${SRC_REPO##*/}"
  MANIFEST_DIR="."; BIN="$REPO_NAME"; TARGET="x86_64-unknown-linux-musl"; FEATURES=""
  DISPATCH_REPO="Abdk4Moura/rbuild"; CS=""; CS_DIR=""; SYNC_EXCLUDE=""
  CS_SSH=""; CS_SSH_PROXY=""; CS_SSH_KEY=""; CS_SSH_PORT=""; BACKEND=""; CS_TARGET_DIR=""
  local user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/rbuild/config"
  [ -f "$user_cfg" ] && rb_read_file "$user_cfg"
  [ -f "$ROOT/.rbuild" ] && rb_read_file "$ROOT/.rbuild"
  local k; for k in $RB_KEYS; do
    local env="RBUILD_$k"; [ -n "${!env:-}" ] && printf -v "$k" '%s' "${!env}"
  done
  # Backend: a persistent ssh host when CS_SSH is set, else the codespace.
  # RBUILD_BACKEND=codespace keeps the codespace reachable from a box whose
  # user config points at an ssh host.
  case "${RBUILD_BACKEND:-}" in
    codespace) BACKEND=codespace ;;
    ssh) BACKEND=ssh; [ -n "$CS_SSH" ] || { echo "rbuild: RBUILD_BACKEND=ssh but CS_SSH is not set" >&2; exit 2; } ;;
    '') # BACKEND=codespace|ssh from a config file picks the default explicitly;
        # otherwise a configured CS_SSH host implies ssh.
        case "$BACKEND" in
          codespace|ssh) ;;
          '') if [ -n "$CS_SSH" ]; then BACKEND=ssh; else BACKEND=codespace; fi ;;
          *) echo "rbuild: BACKEND in config must be ssh or codespace (got $BACKEND)" >&2; exit 2 ;;
        esac ;;
    *) echo "rbuild: RBUILD_BACKEND must be ssh or codespace" >&2; exit 2 ;;
  esac
  export BACKEND
  if [ "$BACKEND" = ssh ]; then
    CS_SSH_KEY="${CS_SSH_KEY:-$HOME/.ssh/rbuild_ed25519}"; CS_SSH_PORT="${CS_SSH_PORT:-22}"
    # Default ~/rbuild/<repo>, resolved on the remote; a /workspaces/... path
    # is the codespace's mount (a project .rbuild written for it) and is
    # not carried over to a plain host.
    case "$CS_DIR" in ''|/workspaces/*) CS_DIR="~/rbuild/$(basename "$ROOT")" ;; esac
    # CS names the target for the cache, ssh config and lease files. Always
    # the sanitized host here: the project's CS is the codespace's name and
    # must keep its own files.
    CS="ssh-$(printf '%s' "${CS_SSH#*@}" | tr -c 'A-Za-z0-9._-' '_')"
  else
    # One remote checkout per LOCAL worktree, automatically: the remote dir is
    # <parent>/<worktree basename>, so parallel worktrees (feature branches, several
    # agents) never share a dir and never trip the sync ownership guard.
    # RBUILD_CS_DIR still overrides; the project's CS_DIR only supplies the parent.
    CS_DIR="$(dirname "${CS_DIR:-/workspaces/$REPO_NAME}")/$(basename "$ROOT")"
  fi
}
