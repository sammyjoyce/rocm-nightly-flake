# Troubleshooting

Common issues and their solutions for the ROCm nightly flake.

## GPU detection failures

### `rocminfo` shows no agents

**Symptoms:** `rocminfo` runs but lists 0 GPU agents, or shows only the CPU agent.

**Causes:**
1. **Missing kernel driver.** The `amdgpu` kernel module must be loaded.
2. **Wrong GPU architecture.** This flake targets `gfx1151` (Strix Halo / RDNA 3.5). Other GPUs need a different tarball.
3. **Permission denied.** Your user may lack access to `/dev/kfd`.

**Solutions:**

```bash
# Check kernel module is loaded
lsmod | grep amdgpu

# Check device access
ls -la /dev/kfd /dev/dri/render*

# Add user to the video and render groups
sudo usermod -aG video,render $USER
# Log out and back in

# On NixOS, enable AMDGPU in your configuration:
hardware.amdgpu.enable = true;
# or at minimum:
boot.initrd.kernelModules = [ "amdgpu" ];
```

### `HSA_STATUS_ERROR_OUT_OF_RESOURCES`

**Cause:** The HSA runtime cannot allocate resources (often a firmware or IOMMU issue).

**Solutions:**
- Update your kernel (6.10+ recommended for RDNA 3.5).
- Try adding `iommu=pt` to kernel command line parameters.
- Check `dmesg | grep -i amdgpu` for firmware loading errors.

## Tarball download issues

### `hash mismatch` during `nix build`

**Cause:** The upstream tarball was replaced or the hash in `flake.nix` is stale.

**Solution:**

```bash
# Re-run the updater to get the current hash
nix run .#update

# Or for a specific version
nix run .#update -- --version 7.12.0a20260205
```

### Download is very slow or times out

**Cause:** The AMD nightly server can be slow. The tarball is approximately 13 GB.

**Solutions:**
- Use a Nix binary cache if one is available.
- Download manually and add to the Nix store:

```bash
url="https://rocm.nightlies.amd.com/tarball/therock-dist-linux-gfx1151-7.12.0a20260205.tar.gz"
nix store prefetch-file "$url"
```

### `nix run .#update` shows "no versions found"

**Cause:** The AMD nightly index page is unavailable or the tarball naming scheme changed.

**Solution:**
- Check https://rocm.nightlies.amd.com/tarball/ manually.
- Pass the version explicitly: `nix run .#update -- --version <VERSION>`

## ELF patching and binary errors

### `error while loading shared libraries`

**Cause:** A binary cannot find its runtime libraries. This is expected outside the wrapper environment.

**Solutions:**
- Use the wrapped binaries in `$out/bin/`, not the raw ones in `$out/opt/rocm/bin/`.
- If using `nix develop`, the `LD_LIBRARY_PATH` is set automatically.
- For NixOS module users, check that `/etc/profile.d/rocm-nightly-gfx1151.sh` is sourced.

### `Segfault` or `SIGILL` in ROCm libraries

**Cause:** Usually an architecture mismatch (running gfx1151 binaries on a different GPU).

**Solution:**
- Verify your GPU architecture: `rocminfo | grep gfx`
- This flake only supports `gfx1151`. For other architectures, you need a different tarball.

### `patchShebangs` warnings during build

**Cause:** Some scripts in the tarball have shebangs pointing to non-Nix paths (e.g., `/usr/bin/python3`). `patchShebangs` fixes these automatically.

**These warnings are informational and can be ignored.**

## NixOS module issues

### `/opt/rocm` does not exist

**Cause:** The tmpfiles rule has not run yet, or the module is not enabled.

**Solutions:**

```bash
# Verify the module is enabled
grep -r rocmNightlyGfx1151 /etc/nixos/

# Force tmpfiles rules to apply
sudo systemd-tmpfiles --create

# Check the symlink target
ls -la /opt/rocm
```

### `ROCM_PATH` not set after login

**Cause:** The `/etc/profile.d` script is not sourced in your shell.

**Solutions:**
- Log out and back in (or start a new login shell).
- Non-login shells do not source `/etc/profile.d`. Use `source /etc/profile.d/rocm-nightly-gfx1151.sh` manually.

## CI and development issues

### `nix flake check` fails locally but lint tools pass

**Cause:** The flake checks run formatters and linters against the Nix store copy of the source (`${self}`), not the working directory. Uncommitted changes are included in the dirty tree.

**Solution:**

```bash
# Format first
nix fmt

# Then check
nix flake check --show-trace
```

### Pre-commit hooks not running

**Cause:** Hooks were not installed (or `.git/hooks/pre-commit` was overwritten).

**Solution:**

```bash
# Enter dev shell (auto-installs hooks)
nix develop

# Or install manually
pre-commit install
```
