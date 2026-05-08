# Combined module: imports both kiss-cache (pruner) and kiss-cache-serve
# (nginx + mTLS) and wires them together. Importable directly without flakes:
#
#   imports = [ (builtins.fetchTarball "https://github.com/Mic92/kiss-cache/archive/main.tar.gz" + "/nixos") ];
#
{ config, lib, ... }:
let
  serve = config.services.kiss-cache-serve;
in
{
  imports = [
    ./kiss-cache.nix
    ./kiss-cache-serve.nix
    ./kiss-cache-update.nix
    ./kiss-cache-publish.nix
    ./kiss-cache-serve-tor.nix
    ./kiss-cache-update-tor.nix
    ./kiss-cache-publish-tor.nix
    ./kiss-cache-serve-oidc.nix
  ];

  # When serving with writers, their PUT marker files are roots.
  services.kiss-cache.gcRoots = lib.mkIf (serve.enable && serve.writers != [ ]) [
    "${serve.cacheDir}/gcroots"
  ];
}
