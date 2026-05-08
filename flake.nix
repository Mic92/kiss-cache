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
          pname = "nix-cache-cut";
          version = (lib.importTOML ./Cargo.toml).package.version;
          src = lib.cleanSource ./.;
          cargoLock.lockFile = ./Cargo.lock;
          nativeCheckInputs = [ pkgs.clippy ];
          postCheck = ''
            cargo clippy --all --all-features --tests -- \
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
            mainProgram = "nix-cache-cut";
          };
        };
    in
    {
      packages = eachSystem (pkgs: rec {
        nix-cache-cut = mkPackage pkgs;
        default = nix-cache-cut;
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
        nix-cache-cut = ./nixos/nix-cache-cut.nix;
        nix-cache-serve = ./nixos/nix-cache-serve.nix;
        default =
          { config, pkgs, ... }:
          let
            serve = config.services.nix-cache-serve;
          in
          {
            imports = [
              ./nixos/nix-cache-cut.nix
              ./nixos/nix-cache-serve.nix
            ];
            services.nix-cache-cut = {
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
        nix-cache-cut = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system: lib.hydraJob self.packages.${system}.default
        );
        tests = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
          system: lib.hydraJob self.checks.${system}.nixos
        );
      };
    };
}
