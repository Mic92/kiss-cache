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
    in
    {
      packages = eachSystem (pkgs: rec {
        kiss-cache = pkgs.callPackage ./package.nix { };
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
        default = ./nixos/default.nix;
      };

      checks = eachSystem (
        pkgs:
        {
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) kiss-cache;
        }
        # The VM test only runs on Linux.
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nixos = pkgs.callPackage ./nixos/test.nix {
            nixosModule = self.nixosModules.default;
          };
        }
      );
    };
}
