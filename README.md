# rbuild

Compile Rust binaries somewhere other than your small dev box, consistently.

Two paths, one default and one reserve:

- **`rbuild`** dispatches the `build` workflow in this repo, which checks out
  any of your public repos at a ref, builds on GitHub's free 4-core runner, and
  hands the binary back as an artifact. Free, no quota, nothing to switch off.
  Runs live here, so the source repo's Actions view stays CI-only.
- **`rbuild cs`** manages one reserve Codespace for the things Actions cannot
  do: an edit/compile loop, debugging, a live binary. Metered (120 core-hours
  a month on Free), so it never creates a Codespace, reuses one you name, and
  always gives you a `down`.

## Install

    git clone https://github.com/Abdk4Moura/rbuild ~/rbuild && ~/rbuild/install.sh

Needs `gh` logged in with `repo`, `workflow` and (for `cs`) `codespace` scopes,
plus `jq`. `gh auth refresh -s codespace` adds the last one.

## Per-project config

A `.rbuild` file at the source repo root, `KEY=VALUE`:

    MANIFEST_DIR=cli                          # where the Cargo.toml is (default .)
    BIN=filament                              # binary to collect (default: repo name)
    TARGET=x86_64-unknown-linux-musl          # default target
    FEATURES=--features static                # passed verbatim
    CS=effective-spoon-pg59gwpxj6cxv5         # reserve codespace (rbuild cs)
    CS_DIR=/workspaces/filament               # checkout dir there

`RBUILD_<KEY>` env vars override the file; flags override both.

## Use

    rbuild                                # current branch, project defaults
    rbuild --ref main --out ~/.local/bin  # drop the binary straight there
    rbuild --profile dev --test           # also run cargo test
    rbuild -- --locked                    # extra cargo args after --

`rbuild` builds what is on GitHub. Dirty or unpushed work on the current branch
makes it refuse; push first or pass `--force`. Output defaults to
`~/.cache/rbuild/<owner>-<repo>/` with a `BUILD_INFO` file (sha, target,
build seconds, run URL). Expect about a minute of queue and setup before cargo
starts; that floor is why the Codespace exists.

    rbuild cs status
    rbuild cs run --ref my-branch         # up, build, fetch, down
    rbuild cs up && rbuild cs sh          # interactive
    rbuild cs sync                        # rsync uncommitted tree over
    rbuild cs clean                       # free target/ dirs when the disk fills
    rbuild cs down                        # stop the meter

Rules for `cs`: one Codespace, never a second; `down` when done (the 30 min
idle timeout is the safety net, not the plan); stopped disks still count
against storage; 30 days idle deletes the Codespace and its caches, which
only costs one cold build since source lives in git.

Private source repos: add a `SOURCE_TOKEN` repository secret here with
`contents:read` on the source repo.
