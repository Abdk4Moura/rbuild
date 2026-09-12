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
    rbuild cs clean                       # free target/ dirs when the disk fills
    rbuild cs down                        # stop the meter

Rules for `cs`: one Codespace, never a second; `down` when done (the 30 min
idle timeout is the safety net, not the plan); stopped disks still count
against storage; 30 days idle deletes the Codespace and its caches, which
only costs one cold build since source lives in git.

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
