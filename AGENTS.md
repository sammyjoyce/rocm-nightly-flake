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
- **`dontStrip`, `dontPatchELF`, `dontFixup` are intentional.** The tarball binaries break under Nix's standard fixup. Wrappers handle paths at runtime.

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
