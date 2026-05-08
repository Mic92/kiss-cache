{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      mkPackage =
        pkgs:
        pkgs.rustPlatform.buildRustPackage {
          pname = "kiss-cache";
          version = (lib.importTOML ./Cargo.toml).package.version;
          src = lib.cleanSource ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeCheckInputs = [ pkgs.clippy ];
          # Benches are not built or linted in CI: criterion is only useful
          # interactively, and building it doubles the dependency closure.
          cargoTestFlags = [
            "--lib"
            "--bins"
            "--tests"
          ];
          postCheck = ''
            cargo clippy --lib --bins --tests -- \
              -D clippy::pedantic \
              -D warnings \
              -A clippy::module-name-repetitions \
              -A clippy::too-many-lines \
              -A clippy::cast-possible-wrap \
              -A clippy::cast-possible-truncation
          '';
          meta = {
            description = "Trim Nix binary caches according to GC roots";
            license = lib.licenses.mit;
            mainProgram = "kiss-cache";
          };
        };
    in
    {
      packages = eachSystem (pkgs: rec {
        kiss-cache = mkPackage pkgs;
        default = kiss-cache;
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            cargo
            rustc
            rustfmt
            clippy
            rust-analyzer
          ];
          RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
        };
      });

      nixosModules = {
        kiss-cache = ./nixos/kiss-cache.nix;
        kiss-cache-serve = ./nixos/kiss-cache-serve.nix;
        default =
          { config, pkgs, ... }:
          let
            serve = config.services.kiss-cache-serve;
          in
          {
            imports = [
              ./nixos/kiss-cache.nix
              ./nixos/kiss-cache-serve.nix
            ];
            services.kiss-cache = {
              package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              # When serving with writers, their PUT marker files are roots.
              gcRoots = lib.mkIf (serve.enable && serve.writers != [ ]) [ "${serve.cacheDir}/gcroots" ];
            };
          };
      };

      checks = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          nixos = pkgs.callPackage ./nixos/test.nix {
            nixosModule = self.nixosModules.default;
          };
        }
      );

      hydraJobs = {
        kiss-cache = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system: lib.hydraJob self.packages.${system}.default
        );
        tests = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system: lib.hydraJob self.checks.${system}.nixos
        );
      };
    };
}
