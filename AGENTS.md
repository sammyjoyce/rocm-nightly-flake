# AGENTS.md - rocm-nightly-flake

## Project overview

Nix flake that repackages AMD's ROCm nightly monolithic tarball for gfx1151
(Radeon 8060S, RDNA 3.5). Single-file flake with a derivation, overlay, NixOS
module, and updater script. See [ARCHITECTURE.md](./ARCHITECTURE.md) for details.

## Repository layout

```
flake.nix              All Nix code: derivation, overlay, NixOS module, updater, devShell
flake.lock             Pinned nixpkgs + flake-utils
ARCHITECTURE.md        Internal design and data flow
TROUBLESHOOTING.md     Runbooks for common issues
README.md              User-facing docs
CONTRIBUTING.md        Contributor guide
.github/               CI, Dependabot, issue/PR templates, CODEOWNERS, labels
.pre-commit-config.yaml  Local hooks: alejandra, statix, deadnix
.editorconfig          Editor settings
```

## Build commands

```bash
# Evaluate flake (no download/build, fast)
nix flake check --no-build

# Run all lint checks (formatting, statix, deadnix)
nix flake check

# Format
nix fmt

# Enter dev shell (needs ROCm package built or cached)
nix develop

# Build ROCm package (downloads ~13 GB tarball)
nix build

# Update ROCm version + hash
nix run .#update

# Update with explicit version
nix run .#update -- --version 7.12.0a20260205

# Update flake inputs
nix flake update
```

## Conventions

### Code style

- Formatter: alejandra (enforced via `nix fmt` and CI)
- Linter: statix (anti-pattern detection)
- Dead code: deadnix
- All three run as pre-commit hooks and CI checks

### Key constraints

- **Never add a CI step that downloads or builds the ROCm tarball.** It is ~13 GB. CI must stay lightweight (eval + lint only).
- **Single file.** All Nix code lives in `flake.nix`. Do not split into multiple files unless it grows past ~500 lines.
- **No source compilation.** The derivation repackages pre-built binaries. Do not add build phases.
- **`dontStrip`, `dontPatchELF`, `dontFixup` are intentional.** Nix's standard ELF fixups (especially RPATH/RUNPATH rewriting) can break the tarball. We only patch the ELF interpreter (PT_INTERP) to Nix's dynamic linker so executables run on NixOS; wrappers still inject env at runtime.

### Version updates

The `version` and `srcHash` variables at the top of `flake.nix` are the only
values that change on ROCm updates. Use `nix run .#update` to bump them
automatically.

### Testing

Validation levels (from fastest to most thorough):

1. `nix flake check --no-build` - Evaluate all derivations and module config (no downloads, seconds)
2. `nix flake check` - Evaluate + run lint checks + module-eval + flake-meta (no tarball, seconds)
3. `nix build .#packages.x86_64-linux.default.tests.output-structure` - Validate built output directories, wrappers, setup-hook (requires tarball, ~13 GB download)
4. `nix run .` - Run `rocminfo` to verify GPU detection (requires tarball + GPU)

### Releases

Tag with `v<rocm-version>` (e.g., `v7.12.0a20260205`) to trigger a GitHub
release with auto-generated notes.

## Common tasks for agents

### Bump ROCm nightly version

1. Run `nix run .#update` (or `nix run .#update -- --version X`)
2. Verify: `nix flake check --no-build`
3. Commit with message: `chore: update ROCm nightly to <version>`

### Fix lint issues

1. `nix run nixpkgs#statix -- check .` to see issues
2. `nix run nixpkgs#statix -- fix .` to auto-fix (review changes)
3. `nix run nixpkgs#deadnix -- .` to find dead code
4. `nix fmt` to reformat

### Add a flake output

Add it inside the `eachSystem` block (for per-system outputs) or in the `//`
merge block (for system-independent outputs like overlays and modules).

## Compound engineering learnings

Lessons extracted from recent development threads. Each entry prevents a
previously encountered mistake from recurring.

### Overlay vs. direct package reference (for consumers)

This flake exposes `overlays.default`. Consumers using the overlay pattern
(`rocm-nightly.overlays.default`) get the package injected into their `pkgs`
set, which is ergonomic but can cause evaluation errors if the consumer's
nixpkgs diverges significantly from ours (hash mismatches, missing
dependencies). The safer consumer pattern is a direct package reference:

```nix
# In consumer's module (e.g. inside nix2):
inputs.rocm-nightly.packages.${pkgs.system}.default
```

When writing examples in README or docs, show **both** patterns and note the
trade-off: overlays are convenient, direct references are more robust.

### Nix shell escaping in CI workflows

On NixOS self-hosted runners, `nix develop -c bash -lc '...'` silently breaks
because the login shell (`-l`) re-initializes `PATH` and wipes the `nix develop`
environment. Use a non-login shell instead:

```yaml
# Bad — login shell wipes nix develop PATH
nix develop -c bash -lc 'some-tool ...'

# Good — non-login shell preserves environment
nix develop --command bash -euo pipefail -c 'some-tool ...'
```

This does not affect our current CI (which runs on `ubuntu-latest` with
`nix flake check`), but matters if we ever add self-hosted runner steps.

### Nix string interpolation for shell arrays

Inside `writeShellApplication` or `writeShellScript` text blocks, shell
`${var}` is interpolated by Nix. To get a literal shell expansion:

```nix
# Wrong — Nix tries to interpolate
"${args[@]}"

# Right — escaped for Nix string context
"''${args[@]}"
```

The update script in `flake.nix` already handles this correctly, but keep it in
mind when adding new shell scripts.

### CI infrastructure noise vs. real failures

When GitHub Actions jobs fail instantly and simultaneously while local
`nix flake check --no-build` and `nix fmt` pass cleanly, the failures are
almost always infrastructure noise (runner provisioning, Nix installer hiccups),
not code regressions. Verify locally first, then re-run the workflow before
investigating further.

### deadnix catches unused arguments after refactors

When a refactor removes usage of a function argument (e.g., removing a
`lib.optionals` guard makes `lib` unused in a lambda), `deadnix` will flag it.
Always run `nix flake check` (which includes the deadnix check) after any
refactor, even seemingly trivial ones.

### Git hangs in non-interactive (agent) contexts

On the NixOS host running this repo's self-hosted GitHub runner, `git commit`
and `git rebase --continue` can hang indefinitely when invoked by agents or
background processes. The cause is `$EDITOR`/`$VISUAL` pointing to `nvim`,
which blocks waiting for a TTY that doesn't exist.

**Diagnosis:** If git appears stuck, check `ps aux | grep git` for zombie
`nvim` processes editing `COMMIT_EDITMSG`.

**Prevention for agents:** Always pass `--no-edit` or set
`GIT_EDITOR=true` when running git commands non-interactively:

```bash
# In agent scripts or CI
GIT_EDITOR=true git rebase --continue
git commit --no-edit -m "message"
```

The host now uses a smart editor wrapper that detects TTY and exits cleanly
in non-interactive contexts, but agents should still be explicit.

### Disable gc.auto for concurrent agent workloads

When multiple agents or GitHub runner jobs operate on repos simultaneously,
git's opportunistic `gc.auto` causes lock contention (`gc.pid` lock files)
that manifests as hangs or errors. The host is now configured with
`gc.auto = 0` and scheduled maintenance via a systemd timer instead. If
adding new CI steps or agent workflows, never re-enable automatic GC.

### Flake eval cache invalidation

Nix caches flake evaluation based on the staged git tree hash. If evaluation
seems stale after editing `flake.nix`, run `git add flake.nix` to invalidate
the cache. For persistent staleness, clear the eval cache:

```bash
rm -rf ~/.cache/nix/eval-cache-v1/
# or pass inline:
nix flake check --option eval-cache false
```

### Compound engineering efficiency gating

Check `git log --oneline --since="24 hours ago"` before searching threads for
compounding. If no commits exist since the last compound commit, skip thread
analysis — there is nothing to compound. This prevents no-op cascades of
empty meta-threads during dormant periods.
