# Architecture

This document describes the internal structure of the rocm-nightly-flake.

## Overview

```
flake.nix          Single-file flake: derivation, overlay, NixOS module, updater
flake.lock         Pinned inputs (nixpkgs, flake-utils)
.github/           CI, Dependabot, issue/PR templates, CODEOWNERS
```

The flake repackages AMD's ROCm nightly monolithic tarball (a ~13 GB archive of
pre-built binaries) into a Nix derivation. There is no source compilation; the
derivation unpacks, patches shebangs, and wraps binaries.

## Source flow

```
AMD nightly server                Nix store
  rocm.nightlies.amd.com           /nix/store/<hash>-rocm-nightly-gfx1151-bin
    therock-dist-linux-             ├── bin/         (wrapped executables)
      gfx1151-<version>.tar.gz     ├── opt/rocm/    (full unpacked tree)
            │                       ├── nix-support/ (setup-hook for buildInputs)
            │  fetchurl + unpack    └── share/licenses/
            └──────────────────────►
```

## flake.nix structure

### Top-level let bindings

| Binding          | Purpose                                       |
|------------------|-----------------------------------------------|
| `gpuarch`        | Target GPU architecture string (`gfx1151`)    |
| `version`        | Current ROCm nightly version                  |
| `srcHash`        | Content hash of the tarball (SRI format)       |
| `mkRocmNightly`  | `pkgs -> derivation` builder function         |

### `mkRocmNightly` derivation

Uses `stdenvNoCC` (no compiler needed). Key phases:

1. **unpack** - Extracts the tarbomb into a `source/` directory
2. **install** - Copies tree to `$out/opt/rocm`, creates `amdgcn` symlink,
   patches shebangs, wraps every executable in `bin/` with `ROCM_PATH`,
   `LD_LIBRARY_PATH`, and `PATH`
3. **setup-hook** - Writes `nix-support/setup-hook` so downstream derivations
   that use this as a `buildInput` get `ROCM_PATH` and `CMAKE_PREFIX_PATH`

Build phases that would break pre-built binaries are disabled (`dontStrip`,
`dontPatchELF`, `dontFixup`).

### Flake outputs

| Output                      | Description                                              |
|-----------------------------|----------------------------------------------------------|
| `packages.default`          | The ROCm nightly derivation                              |
| `packages.update`           | Shell script to bump `version` + `srcHash` in flake.nix  |
| `apps.default`              | Runs `rocminfo` (quick GPU detection test)               |
| `apps.update`               | Runs the updater script                                  |
| `checks.*`                  | Formatting, lint, dead code, module-eval, flake-meta       |
| `devShells.default`         | Shell with ROCm on `PATH` + dev tools                    |
| `formatter`                 | alejandra wrapper                                        |
| `overlays.default`          | Adds `rocm-nightly` to nixpkgs                           |
| `nixosModules.default`      | System-wide install with `/opt/rocm` symlink             |
| `lib`                       | Exposes `gpuarch`, `version`, `srcHash`, `mkRocmNightly` |

### NixOS module

When `services.rocmNightlyGfx1151.enable = true`:

- Adds the package to `environment.systemPackages`
- Creates `/opt/rocm` symlink via `systemd.tmpfiles`
- Configures `ld.so.conf.d` for library discovery
- Sets `ROCM_PATH`, `HIP_PATH` via `/etc/profile.d`

### Updater script

`nix run .#update` scrapes the AMD nightly index page, finds the latest tarball
for the configured `gpuarch`, prefetches it to compute the SRI hash, and
rewrites `version` + `srcHash` in `flake.nix` using a Python regex replacement.

### `passthru.tests`

The ROCm derivation includes `passthru.tests.output-structure` which validates the
built output: directory layout (`bin/`, `opt/rocm/`, `nix-support/`), setup-hook
content, wrapped binaries, amdgcn symlink, and license directory. Requires the
package to be built first (13 GB download).

```bash
nix build .#packages.x86_64-linux.default.tests.output-structure
```

## CI

| Workflow               | Trigger               | What it does                                      |
|------------------------|-----------------------|---------------------------------------------------|
| `ci.yml` (checks)     | push/PR to main       | Flake eval + lint + module-eval + AGENTS.md check  |
| `ci.yml` (security)   | push/PR to main       | gitleaks secret scanning + TODO/FIXME tracking     |
| `update-flake-lock.yml`| Weekly cron           | Updates `flake.lock` via PR                        |
| `release.yml`          | `v*` tag push         | Creates GitHub release with notes                  |

## Design decisions

- **No source build.** AMD publishes pre-built tarballs; compiling ROCm from
  source is a multi-hour ordeal requiring dozens of repos. Repackaging the
  tarball is the practical choice.
- **`dontPatchELF` / `dontFixup`.** The tarball's binaries have complex RPATH
  structures that break under Nix's standard fixup. Wrappers inject paths at
  runtime instead.
- **Single gpuarch.** The tarball is architecture-specific. Supporting multiple
  architectures means multiple tarballs with different hashes.
- **CI avoids builds.** The tarball is ~13 GB. CI only evaluates derivations
  and runs lightweight lint checks.
