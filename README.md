# ROCm Nightly Flake (gfx1151)

Nix flake packaging of the [ROCm nightly monolithic tarball](https://rocm.nightlies.amd.com) for AMD Strix Halo (Radeon 8060S, RDNA 3.5, gfx1151).

## Quick start

```bash
# Test GPU detection
nix run github:sammy/rocm-nightly-flake

# Enter dev shell with ROCm on PATH
nix develop github:sammy/rocm-nightly-flake

# Build the package
nix build github:sammy/rocm-nightly-flake
```

## NixOS module

```nix
# flake.nix
{
  inputs.rocm-nightly.url = "github:sammy/rocm-nightly-flake";

  outputs = { self, nixpkgs, rocm-nightly, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        rocm-nightly.nixosModules.default
        {
          services.rocmNightlyGfx1151.enable = true;
        }
      ];
    };
  };
}
```

The module:
- Installs the ROCm package to the system profile
- Creates `/opt/rocm` symlink via tmpfiles
- Sets `ROCM_PATH`, `ROCM_HOME`, `HIP_PATH` in `/etc/profile.d`
- Configures `ld.so.conf.d` for library discovery

## Overlay

```nix
{
  inputs.rocm-nightly.url = "github:sammy/rocm-nightly-flake";

  outputs = { self, nixpkgs, rocm-nightly, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        { nixpkgs.overlays = [ rocm-nightly.overlays.default ]; }
        # pkgs.rocm-nightly-gfx1151-bin (and pkgs.rocm-nightly) are now available
      ];
    };
  };
}
```

## Updating

### Update ROCm nightly tarball (version + hash)

This repo includes an updater app:

```bash
# Pick the latest gfx1151 nightly from https://rocm.nightlies.amd.com/tarball/ and rewrite flake.nix
nix run .#update

# Or pin an explicit version
nix run .#update -- --version 7.12.0a20260205

# Preview without modifying files
nix run .#update -- --dry-run
```

Note: prefetching downloads the full tarball (large).

### Update flake inputs (nixpkgs, flake-utils)

```bash
nix flake update
```

### Format

```bash
nix fmt
```

## What's included

- ROCm runtime (HSA, HIP)
- ROCm libraries (rocBLAS, hipBLAS, hipBLASLt, MIOpen, rocFFT, etc.)
- ROCm tools (rocminfo, rocm-smi, rocprof, hipcc)
- LLVM/Clang toolchain with AMDGPU backend
- 679 wrapped binaries with proper `ROCM_PATH` and `LD_LIBRARY_PATH`
- Total size: ~13 GB
