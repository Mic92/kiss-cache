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
        kiss-cache-update = ./nixos/kiss-cache-update.nix;
        kiss-cache-publish = ./nixos/kiss-cache-publish.nix;
        kiss-cache-serve-tor = ./nixos/kiss-cache-serve-tor.nix;
        kiss-cache-update-tor = ./nixos/kiss-cache-update-tor.nix;
        kiss-cache-publish-tor = ./nixos/kiss-cache-publish-tor.nix;
        kiss-cache-serve-oidc = ./nixos/kiss-cache-serve-oidc.nix;
        default = ./nixos/default.nix;
      };

      checks = eachSystem (
        pkgs:
        {
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) kiss-cache;
          # Bounded model check of the prune/upload concurrency design.
          # `expect` annotations make Alloy exit nonzero if any
          # invariant is violated or the documented bug disappears.
          alloy = pkgs.runCommand "kiss-cache-alloy" { nativeBuildInputs = [ pkgs.alloy6 ]; } ''
            alloy6 exec -o $out ${./spec/prune.als}
          '';
        }
        # The VM test only runs on Linux.
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          nixos = pkgs.callPackage ./nixos/test.nix {
            nixosModule = self.nixosModules.default;
          };
          nixos-tor = pkgs.callPackage ./nixos/test-tor.nix {
            nixosModule = self.nixosModules.default;
          };
          nixos-oidc = pkgs.callPackage ./nixos/test-oidc.nix {
            nixosModule = self.nixosModules.default;
          };
        }
      );
    };
}
