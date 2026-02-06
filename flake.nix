{
  description = "ROCm nightly monolithic install (gfx1151) packaged as a Nix flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }: let
    gpuarch = "gfx1151";
    version = "7.12.0a20260205";
    srcHash = "sha256-6pkPZ5vD7Q9oQ3797cwA30y9/GNAku39BQiqko59j7o=";

    mkRocmNightly = pkgs: let
      inherit (pkgs) lib;
      pythonEnv = pkgs.python3.withPackages (ps: [ps.pyelftools]);
      gccLibPath = lib.makeLibraryPath [pkgs.stdenv.cc.cc.lib];
      pname = "rocm-nightly-${gpuarch}-bin";

      rocmDrv = pkgs.stdenvNoCC.mkDerivation {
        inherit pname version;

        src = pkgs.fetchurl {
          url = "https://rocm.nightlies.amd.com/tarball/therock-dist-linux-${gpuarch}-${version}.tar.gz";
          hash = srcHash;
        };

        dontStrip = true;
        separateDebugInfo = false;
        dontPatchELF = true;
        dontFixup = true;
        dontConfigure = true;
        dontBuild = true;

        # Tarball is a tarbomb (multiple top-level dirs: bin, lib, include, ...).
        # Extract into a single directory so the default unpack phase is happy.
        sourceRoot = "source";
        unpackCmd = ''
          mkdir -p source
          tar xzf "$curSrc" -C source
        '';

        nativeBuildInputs = [
          pkgs.makeWrapper
          pythonEnv
        ];

        installPhase = ''
                      runHook preInstall

                      mkdir -p "$out/opt/rocm"

                      cp -a --no-preserve=ownership ./* "$out/opt/rocm/"

                      if [ -d "$out/opt/rocm/lib/llvm/amdgcn" ] && [ ! -e "$out/opt/rocm/amdgcn" ]; then
                        ln -s "lib/llvm/amdgcn" "$out/opt/rocm/amdgcn"
                      fi

                      patchShebangs "$out/opt/rocm"

                      mkdir -p "$out/share/licenses/${pname}"
                      if [ -f "$out/opt/rocm/LICENSE" ]; then
                        ln -s "$out/opt/rocm/LICENSE" "$out/share/licenses/${pname}/LICENSE"
                      elif [ -f "$out/opt/rocm/LICENSE.txt" ]; then
                        ln -s "$out/opt/rocm/LICENSE.txt" "$out/share/licenses/${pname}/LICENSE"
                      fi

                      mkdir -p "$out/bin"
                      if [ -d "$out/opt/rocm/bin" ]; then
                        for prog in "$out/opt/rocm/bin/"*; do
                          if [ -f "$prog" ] && [ -x "$prog" ]; then
                            makeWrapper "$prog" "$out/bin/$(basename "$prog")" \
                              --set-default ROCM_PATH "$out/opt/rocm" \
                              --set-default ROCM_HOME "$out/opt/rocm" \
                              --set-default HIP_PATH "$out/opt/rocm" \
                              --prefix PATH : "$out/opt/rocm/bin" \
                              --prefix LD_LIBRARY_PATH : "$out/opt/rocm/lib:$out/opt/rocm/lib64:${gccLibPath}"
                          fi
                        done
                      fi

                      # When used as a build input, expose the install root in a standard way.
                      mkdir -p "$out/nix-support"
                      cat > "$out/nix-support/setup-hook" <<EOF
          export ROCM_PATH="$out/opt/rocm"
          export ROCM_HOME="\$ROCM_PATH"
          export HIP_PATH="\$ROCM_PATH"
          addToSearchPath CMAKE_PREFIX_PATH "\$ROCM_PATH"
          EOF

                      runHook postInstall
        '';

        # Tests that validate the built output (require downloading the tarball).
        # Run manually: nix build .#packages.x86_64-linux.default.tests.output-structure
        passthru.tests = {
          output-structure = pkgs.runCommand "test-rocm-output-structure" {} ''
            pkg="${rocmDrv}"

            echo "=== Output structure tests ==="

            echo "Checking opt/rocm directory..."
            test -d "$pkg/opt/rocm"

            echo "Checking bin directory..."
            test -d "$pkg/bin"

            echo "Checking nix-support directory..."
            test -d "$pkg/nix-support"
            test -f "$pkg/nix-support/setup-hook"

            echo "Checking setup-hook content..."
            grep -q 'ROCM_PATH=' "$pkg/nix-support/setup-hook"
            grep -q 'CMAKE_PREFIX_PATH' "$pkg/nix-support/setup-hook"
            grep -q 'HIP_PATH=' "$pkg/nix-support/setup-hook"

            echo "Checking wrapped binaries exist..."
            count=0
            for f in "$pkg/bin/"*; do
              if [ -f "$f" ] && [ -x "$f" ]; then
                count=$((count + 1))
              fi
            done
            test "$count" -gt 0 || { echo "FAIL: no executables in bin/"; exit 1; }
            echo "Found $count wrapped executables"

            echo "Checking amdgcn symlink..."
            if [ -d "$pkg/opt/rocm/lib/llvm/amdgcn" ]; then
              test -L "$pkg/opt/rocm/amdgcn" || { echo "FAIL: amdgcn symlink missing"; exit 1; }
            fi

            echo "Checking license directory..."
            test -d "$pkg/share/licenses"

            echo "=== All output structure tests passed ==="
            touch $out
          '';
        };

        meta = with lib; {
          description = "AMD ROCm Nightly Release (${gpuarch}) - Monolithic install";
          homepage = "https://rocm.nightlies.amd.com";
          platforms = ["x86_64-linux"];
          license = with licenses; [
            mit
            unfreeRedistributable
          ];
          mainProgram = "rocminfo";
        };
      };
    in
      rocmDrv;
  in
    flake-utils.lib.eachSystem ["x86_64-linux"] (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        rocmPkg = mkRocmNightly pkgs;
        gccLibPath = pkgs.lib.makeLibraryPath [pkgs.stdenv.cc.cc.lib];

        updateScript = pkgs.writeShellApplication {
          name = "update-rocm-nightly";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.curl
            pkgs.jq
            pkgs.nix
            pkgs.python3
          ];
          text = ''
                        set -euo pipefail

                        usage() {
                          cat <<'USAGE'
            update-rocm-nightly [--version VERSION] [--dry-run] [--update-lock]

            Updates version + srcHash in flake.nix.

            Options:
              --version VERSION   Set an explicit ROCm nightly version (e.g. 7.12.0a20260205)
              --dry-run           Print the chosen version + hash but do not modify files
              --update-lock       Run `nix flake update` after updating flake.nix

            Notes:
              - If --version is omitted, the latest version for the current gpuarch is chosen
                by scraping https://rocm.nightlies.amd.com/tarball/
              - Prefetching downloads the full tarball (large)
            USAGE
                        }

                        rocm_version=""
                        dry_run=0
                        update_lock=0

                        while [ $# -gt 0 ]; do
                          case "$1" in
                            --version)
                              if [ $# -lt 2 ]; then
                                echo "error: --version requires an argument" >&2
                                exit 2
                              fi
                              rocm_version="$2"
                              shift 2
                              ;;
                            --dry-run)
                              dry_run=1
                              shift
                              ;;
                            --update-lock)
                              update_lock=1
                              shift
                              ;;
                            -h|--help)
                              usage
                              exit 0
                              ;;
                            *)
                              echo "error: unknown argument: $1" >&2
                              usage >&2
                              exit 2
                              ;;
                          esac
                        done

                        flake_path="flake.nix"
                        if [ ! -f "$flake_path" ]; then
                          echo "error: $flake_path not found (run from the repo root)" >&2
                          exit 1
                        fi
                        if [ ! -w "$flake_path" ]; then
                          echo "error: $flake_path not writable" >&2
                          exit 1
                        fi

                        gpuarch="${gpuarch}"
                        index_url="https://rocm.nightlies.amd.com/tarball/"

                        if [ -z "$rocm_version" ]; then
                          echo "Fetching latest nightly version for gpuarch=$gpuarch..." >&2
                          rocm_version="$(
                            curl -fsSL "$index_url" \
                              | python3 -c 'import re,sys; arch=sys.argv[1]; html=sys.stdin.read(); pat=f"therock-dist-linux-{re.escape(arch)}-([0-9][0-9A-Za-z.]+)[.]tar[.]gz"; vers=re.findall(pat, html); vers or sys.exit(f"no versions found for {arch}"); print(max(vers, key=lambda v: int(re.search(r"([0-9]{8})$", v).group(1))))' \
                                  "$gpuarch"
                          )"
                        fi

                        url="https://rocm.nightlies.amd.com/tarball/therock-dist-linux-$gpuarch-$rocm_version.tar.gz"

                        echo "Prefetching: $url" >&2
                        src_hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -r .hash)"

                        echo "version=$rocm_version"
                        echo "srcHash=$src_hash"

                        if [ "$dry_run" -eq 1 ]; then
                          exit 0
                        fi

                        python3 - "$flake_path" "$rocm_version" "$src_hash" <<'PY'
            import re
            import sys
            from pathlib import Path

            path = Path(sys.argv[1])
            version = sys.argv[2]
            src_hash = sys.argv[3]

            text = path.read_text(encoding="utf-8")

            text, n_version = re.subn(
                r'(^\s*version\s*=\s*")[^"]*(";)',
                rf'\1{version}\2',
                text,
                flags=re.M,
            )
            text, n_hash = re.subn(
                r'(^\s*srcHash\s*=\s*")[^"]*(";)',
                rf'\1{src_hash}\2',
                text,
                flags=re.M,
            )

            if n_version != 1 or n_hash != 1:
                raise SystemExit(f"unexpected replacements: version={n_version} srcHash={n_hash}")

            path.write_text(text, encoding="utf-8")
            PY

                        echo "Updated $flake_path" >&2

                        if [ "$update_lock" -eq 1 ]; then
                          nix flake update
                        fi
          '';
        };

        formatterWrapper = pkgs.writeShellApplication {
          name = "fmt";
          runtimeInputs = [pkgs.alejandra];
          text = ''
            set -euo pipefail
            cd "$PRJ_ROOT"

            if [ $# -eq 0 ]; then
              exec alejandra .
            else
              exec alejandra "$@"
            fi
          '';
        };
      in {
        packages = {
          rocm-nightly-gfx1151-bin = rocmPkg;
          rocm-nightly = rocmPkg;
          update = updateScript;
          default = rocmPkg;
        };

        apps = {
          default = {
            type = "app";
            program = "${rocmPkg}/bin/rocminfo";
            meta = {
              description = "ROCm GPU/driver info via rocminfo";
            };
          };

          update = {
            type = "app";
            program = "${updateScript}/bin/update-rocm-nightly";
            meta = {
              description = "Update flake.nix to the latest ROCm nightly (version + hash)";
            };
          };
        };

        checks = {
          formatting =
            pkgs.runCommand "check-formatting" {
              nativeBuildInputs = [pkgs.alejandra];
            } ''
              alejandra -c ${self}
              touch $out
            '';
          statix =
            pkgs.runCommand "check-statix" {
              nativeBuildInputs = [pkgs.statix];
            } ''
              statix check ${self}
              touch $out
            '';
          deadnix =
            pkgs.runCommand "check-deadnix" {
              nativeBuildInputs = [pkgs.deadnix];
            } ''
              deadnix --fail ${self}
              touch $out
            '';

          # Validates the NixOS module evaluates without errors (no tarball download).
          module-eval = let
            testConfig = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  nixpkgs.config.allowUnfree = true;
                  boot.loader.grub.enable = false;
                  fileSystems."/".device = "none";
                  system.stateVersion = "24.11";
                  services.rocmNightlyGfx1151.enable = true;
                }
              ];
            };
          in
            pkgs.runCommand "check-module-eval" {} ''
              test "${builtins.toString testConfig.config.services.rocmNightlyGfx1151.enable}" = "1"
              echo "NixOS module evaluates successfully"
              touch $out
            '';

          # Validates derivation metadata at eval time (no tarball download).
          flake-meta = pkgs.runCommand "check-flake-meta" {} ''
            test "${rocmPkg.pname}" = "rocm-nightly-${gpuarch}-bin"
            test "${rocmPkg.version}" = "${version}"
            test "${rocmPkg.meta.mainProgram}" = "rocminfo"
            echo "Flake metadata validated"
            touch $out
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            rocmPkg
            pkgs.statix
            pkgs.deadnix
            pkgs.pre-commit
          ];
          shellHook = ''
            export ROCM_PATH=${rocmPkg}/opt/rocm
            export ROCM_HOME=$ROCM_PATH
            export HIP_PATH=$ROCM_PATH
            export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:${gccLibPath}:$LD_LIBRARY_PATH

            echo "ROCm nightly (${version}, ${gpuarch}) available at: $ROCM_PATH" >&2

            if [ -f .pre-commit-config.yaml ] && command -v pre-commit &>/dev/null; then
              if [ ! -f .git/hooks/pre-commit ] || ! grep -q "pre-commit" .git/hooks/pre-commit 2>/dev/null; then
                pre-commit install -q || true
              fi
            fi
          '';
        };

        formatter = formatterWrapper;
      }
    )
    // {
      lib = {
        inherit gpuarch version srcHash mkRocmNightly;
      };

      overlays.default = final: _prev: let
        pkg = mkRocmNightly final;
      in {
        rocm-nightly-gfx1151-bin = pkg;
        rocm-nightly = pkg;
      };

      nixosModules.default = {
        config,
        lib,
        pkgs,
        ...
      }: let
        cfg = config.services.rocmNightlyGfx1151;
      in {
        options.services.rocmNightlyGfx1151 = {
          enable = lib.mkEnableOption "ROCm nightly (${gpuarch}) monolithic install exposed at /opt/rocm";

          package = lib.mkOption {
            type = lib.types.nullOr lib.types.package;
            default = null;
            description = ''
              Package to expose at /opt/rocm.
              If null, this module builds the ROCm nightly package from the tarball.
            '';
          };
        };

        config = lib.mkIf cfg.enable (
          let
            pkg =
              if cfg.package != null
              then cfg.package
              else mkRocmNightly pkgs;

            gccLibPath = lib.makeLibraryPath [pkgs.stdenv.cc.cc.lib];
          in {
            environment = {
              systemPackages = [pkg];
              etc = {
                "ld.so.conf.d/rocm-nightly-${gpuarch}.conf".text = ''
                  /opt/rocm/lib
                  /opt/rocm/lib64
                '';
                "profile.d/rocm-nightly-${gpuarch}.sh".text = ''
                  export ROCM_PATH=/opt/rocm
                  export ROCM_HOME=/opt/rocm
                  export HIP_PATH=/opt/rocm
                  export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib64:${gccLibPath}:$LD_LIBRARY_PATH
                '';
              };
            };

            systemd.tmpfiles.rules = [
              "L+ /opt/rocm - - - - ${pkg}/opt/rocm"
            ];
          }
        );
      };
    };
}
