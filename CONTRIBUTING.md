# Contributing

Thanks for helping improve this flake.

## What this repo is

This repo packages AMD's ROCm **nightly monolithic tarball** ("therock" dist) for **gfx1151** as a Nix flake.

- The flake code in this repo is MIT licensed (see `LICENSE`).
- The upstream ROCm nightly tarball is **redistributable but not open source** (see AMD's tarball licensing).

## Development prerequisites

- Nix with flakes enabled

## Common tasks

### Format

```bash
nix fmt

# Check formatting (used in CI)
nix fmt -- -c .
```

### Evaluate flake outputs (no builds)

```bash
nix flake check --no-build
```

### Update ROCm nightly (version + hash)

```bash
# Select latest gfx1151 nightly + rewrite flake.nix
nix run .#update

# Pin an explicit version
nix run .#update -- --version 7.12.0a20260205
```

Note: updating requires downloading the full tarball to compute the content hash.

### Update nixpkgs / flake inputs

```bash
nix flake update
```

## Pull requests

- Keep CI **lightweight** (avoid anything that downloads/builds the full ROCm tarball).
- Prefer small, focused commits.
- Run:
  - `nix fmt -- -c .`
  - `nix flake check --no-build`

## Reporting issues

Please include:
- host OS / distro
- GPU model + reported `gfx` arch
- `nix --version`
- the command you ran and the output (use `nix log` if needed)
