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

## Config

Three layers, each overriding the one before: `~/.config/rbuild/config`
(user-level, machine defaults), `.rbuild` at the source repo root
(per-project), then `RBUILD_<KEY>` environment variables. Flags override all
three. Same `KEY=VALUE` format everywhere:

    MANIFEST_DIR=cli                          # where the Cargo.toml is (default .)
    BIN=filament                              # binary to collect (default: repo name)
    TARGET=x86_64-unknown-linux-musl          # default target
    FEATURES=--features static                # passed verbatim
    CS=effective-spoon-pg59gwpxj6cxv5         # reserve codespace (rbuild cs)
    CS_DIR=/workspaces/filament               # checkout dir there
    SYNC_EXCLUDE=docs,frontend                # paths `rbuild cs sync/dev` skip
    CS_SSH=agboola@popos-guest                # persistent build host instead of the codespace
    CS_SSH_PROXY=filament forward --stdio popos-guest:22   # optional ProxyCommand
    CS_SSH_KEY=~/.ssh/rbuild_ed25519          # identity file (this is the default)
    CS_SSH_PORT=22

The `CS_SSH*` keys normally belong in the user file: which box does your
builds is a property of where you sit, not of the project.

## Use

    rbuild                                # current branch, project defaults
    rbuild --ref main --out ~/.local/bin  # drop the binary straight there
    rbuild --profile dev --test           # also run cargo test
    rbuild -- --locked                    # extra cargo args after --

`rbuild` builds what is on GitHub. Dirty or unpushed work on the current branch
makes it refuse; push first or pass `--force`. Output defaults to
`~/.cache/rbuild/<owner>-<repo>/` with a `BUILD_INFO` file (sha, target,
build seconds, run URL). Queue plus setup is about 20 seconds.

Where the time goes, measured on filament (musl release, 4-core runner):
cold cargo 297 s; with the target dir restored, only ~17 crates recompile yet
the Build step still takes ~200 s, because the release profile uses fat LTO
with one codegen unit and that final codegen + link cannot be cached. For
functional iteration use a lighter profile the crate defines
(`rbuild --profile measure` on filament: opt-level 1, no LTO); keep `release`
for anything you measure or ship.

Flags for measuring: `--no-cache` (every layer cold, throwaway namespaces),
`--no-target-cache` (skip layer 1, so the sccache/R2 layer is exercised alone).

    rbuild cs status
    rbuild cs run --ref my-branch         # up, build, fetch, down
    rbuild cs up && rbuild cs sh          # interactive
    rbuild cs sync                        # rsync uncommitted tree over
    rbuild cs dev                         # THE LOOP: sync + incremental dev build, timed
    rbuild cs dev --check                 # cargo check instead
    rbuild cs dev --fetch                 # and bring the debug binary back
    rbuild cs session 2h                  # keep the box warm for 2 h, then stop it
    rbuild cs session                     # lease status; `session end` stops now
    rbuild cs clean                       # free target/ dirs when the disk fills
    rbuild cs down                        # stop the meter

Rules for `cs`: one Codespace, never a second; `down` when done (the 30 min
idle timeout is the safety net, not the plan); stopped disks still count
against storage; 30 days idle deletes the Codespace and its caches, which
only costs one cold build since source lives in git.

### The edit/compile loop

`rbuild cs dev` rsyncs the working tree (uncommitted edits included, minus
`.git`, `target`, `node_modules` and `SYNC_EXCLUDE`) over one multiplexed ssh
connection and runs an incremental `cargo build --profile dev` on the warm
target dir, printing the seconds for each step. Measured on filament (4
cores): a real edit plus incremental build round trip is 10 to 13 s (cargo
5 to 7 s of that), a no-op iteration 7 s.

**Prewarm.** The first build after a Codespace resume took ~150 s instead of
~10 s because the page cache is cold: cargo's freshness check reads every
file under `target/`. `rbuild cs up` now starts a detached
`find target | xargs cat >/dev/null` on the box right after it comes up, so
the ~5 GB are back in RAM while you are still typing (`up --no-prewarm` to
skip). Small print: the login profile on the box leaves a dup of the ssh
stderr pipe on a high fd, and a backgrounded child that inherits it keeps
the ssh session open until it exits; the script closes every fd above 2
before detaching, which is why this returns at once.

**Session lease.** `rbuild cs session 2h` brings the box up, then leaves a
detached holder process on your machine that opens a trivial ssh command
every 4 minutes, logs each heartbeat to `~/.cache/rbuild/cs-<CS>.session.log`,
wakes the box if it stopped anyway, and runs `down` when the lease ends (or
on `rbuild cs session end`). The point: the 30 minute idle timeout counts
connections as activity, so within a lease every `dev` iteration is warm
and nothing you forget can burn more than the lease. The idle timeout itself
is not changeable on an existing Codespace: `gh codespace edit` has no flag
for it, and `PATCH /user/codespaces/<name>` with `idle_timeout_minutes`
returns 200 and silently keeps 30. Lease state is `~/.cache/rbuild/cs-<CS>.lease`
(`holder pid` and `end epoch`).

### A persistent host instead of the Codespace (ssh backend)

Set `CS_SSH=user@host` (normally in `~/.config/rbuild/config`):

    # ~/.config/rbuild/config
    CS_SSH=agboola@popos-guest
    CS_SSH_PROXY=filament forward --stdio popos-guest:22

and every `rbuild cs` verb targets that machine over plain ssh instead of the
Codespace: same `remote`, `sync`, `dev`, `fetch`, `build`, `sh`, `clean`,
`session`, same multiplexed connection, no `gh codespace` call anywhere.
`CS_SSH_PROXY` is a ProxyCommand for hosts you reach through something
(e.g. `filament forward --stdio popos-guest:22`), `CS_SSH_KEY` defaults to
`~/.ssh/rbuild_ed25519`, `CS_SSH_PORT` to 22. The checkout lives in
`~/rbuild/<repo>` on the host (a `CS_DIR` from a project `.rbuild` that
points into `/workspaces/` is ignored there, that is the Codespace's mount).
`rbuild cs up` on such a host installs rustup non-interactively if missing,
clones the repo, pins `stable` unless the project has a `rust-toolchain`
file, and installs mold only when `sudo -n true` works (otherwise it says
`mold: skipped (no passwordless sudo)` and links with the default linker).
`down` and the end of a session lease print that a persistent host has
nothing to stop.

The host's login shell must be silent for non-interactive sessions: rsync
speaks its protocol over the same channel, and one line of profile chatter
fails it with `protocol version mismatch -- is your shell clean?`. `rbuild cs
sync` recognizes that message, says so, and shows the offending output; the
fix is on the host (popos-guest had an unguarded `nvm use node` in
`config.fish`, silenced with `>/dev/null`). Filament daemons, or anything
else on the host, are not touched: rbuild only ever writes under
`~/rbuild/<repo>`, `~/.cargo` and `~/.rustup` there.

Measured on popos-guest (Pop!_OS, 4 cores, 7.8 GB with ~3 GB free for us,
no mold, reached through `filament forward`) on filament's dev profile:
`up` with the toolchain refresh 76 s; the first full build `dev -j 3` 285 s
(cargo 275 s, rsync 6 s); a no-op iteration 16 s (cargo 1 s, the rest rsync
walking the tree); a real one-line edit 24 s (cargo 18 s, sync 3 s); the
first `dev --check` after that edit 98 s, because check keeps its own
metadata and starts cold. Peak system memory in use during the full build
was 5.5 GB against a 4.8 GB baseline, so `-j 3` left headroom; on a 16 GB
box drop the flag.

`RBUILD_BACKEND=codespace rbuild cs ...` ignores `CS_SSH` for one invocation,
so the Codespace stays reachable from a box whose user config points at an
ssh host; `RBUILD_BACKEND=ssh` forces the other way. `rbuild cs status`
prints which backend is active. Cache, ssh config and lease files are per
target (`~/.cache/rbuild/cs-<codespace>.*` and `cs-ssh-<host>.*`), so a
lease on the Codespace and a loop on the ssh host do not interfere.

Private source repos: add a `SOURCE_TOKEN` repository secret here with
`contents:read` on the source repo.

## Shared compile cache (Cloudflare R2, free tier)

With an R2 bucket, sccache objects are shared across Actions, the Codespace
and any other machine, so even a cold runner is mostly cache hits. R2's free
tier is 10 GB-month of storage per account, no egress fees. One-time setup:

1. Get a token scoped to the bucket. Either run
   `scripts/mint-r2-token.sh` (uses `~/secret_keys/cloudflare_api_token` to
   mint a bucket-scoped account token, derives the S3 pair, stores it under
   `~/secret_keys/r2_sccache_*`, and does steps 2 and 4 for you), or in the
   Cloudflare dashboard: R2 → Manage API tokens → **Object Read & Write** on
   the one bucket. Note the Access Key ID, Secret Access Key, and Account ID.
   R2 needs a payment method on the account even inside the free tier;
   overage is about $0.015 per GB-month.
2. Hand them to the builder repo (never to the source repos):

       gh secret set R2_ACCESS_KEY_ID     -R Abdk4Moura/rbuild
       gh secret set R2_SECRET_ACCESS_KEY -R Abdk4Moura/rbuild
       gh variable set R2_ACCOUNT_ID      -R Abdk4Moura/rbuild --body <account id>
       gh variable set R2_BUCKET          -R Abdk4Moura/rbuild --body sccache   # optional

3. Create the bucket and its lifecycle rule (idempotent):

       gh workflow run cache-size.yml -R Abdk4Moura/rbuild -f mode=setup

4. For the Codespace, the same three as Codespaces user secrets, visible to the
   repo the Codespace belongs to (secrets are injected at start, so `rbuild cs
   down` then `up` once):

       gh secret set R2_ACCESS_KEY_ID     --user --app codespaces --repos Abdk4Moura/Egregoria
       gh secret set R2_SECRET_ACCESS_KEY --user --app codespaces --repos Abdk4Moura/Egregoria
       gh secret set R2_ACCOUNT_ID        --user --app codespaces --repos Abdk4Moura/Egregoria

**Staying under 10 GB.** One bucket, one prefix per source repo
(`<owner>/<repo>/`). Three controls, in order of importance:

- A lifecycle rule expires every object 14 days after upload
  (`R2_EXPIRE_DAYS` to change). sccache never evicts remote storage itself;
  this is what does it. A hot object is simply re-uploaded on its next compile.
- The weekly `cache-size` workflow measures the bucket, prints size per prefix
  in the run summary, and if it is over `R2_MAX_GB` (default 8) deletes the
  oldest objects until it is under 90% of the cap.
- Without working R2 secrets everything falls back to the per-repo GitHub
  Actions cache automatically. The workflow probes the bucket with a
  put-object first, because sccache aborts the build on a 401: a missing OR
  revoked token degrades, never breaks (learned the hard way with a revoked
  key).
- Two cache layers, so either can be down: `rust-cache` keeps the `target/`
  dir in the Actions cache (unchanged deps need no compile at all), and
  sccache (R2, else Actions cache) catches the rest. `rbuild --no-cache` is
  measurement mode: every layer cold, throwaway namespaces, nothing shared.

A full filament release build is roughly 1 to 2 GB of cache per target and
profile. R2 free operations (1M writes, 10M reads a month) are not a
constraint at hobby scale: a full build is a few thousand of each.
