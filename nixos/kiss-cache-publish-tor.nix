# Publish to a kiss-cache .onion.
#
# Configures Tor client authorization for the cache's write onion and
# routes both `nix copy` and the marker `PUT` through the SOCKS proxy.
# See `kiss-cache-update-tor.nix` for the read side.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.kiss-cache.publish-tor;
  socks = "127.0.0.1:${toString cfg.socksPort}";
in
{
  options.services.kiss-cache.publish-tor = {
    enable = lib.mkEnableOption "publishing NixOS systems to a kiss-cache .onion";

    onion = lib.mkOption {
      type = lib.types.str;
      example = "exampleexampleexampleexampleexampleexampleexampleexample.onion";
      description = "The cache's write onion address, with the `.onion` suffix.";
    };

    clientAuthFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing this client's x25519 private key for the
        onion's client authorization, in the format
        `descriptor:x25519:<base32-private-key>`. `null` if the cache
        does not require client authorization (not recommended for a
        write onion).
      '';
    };

    socksPort = lib.mkOption {
      type = lib.types.port;
      default = 9050;
      description = "Tor SOCKS proxy port. Must match the local Tor client.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tor = {
      enable = true;
      client = {
        enable = true;
        onionServices = lib.mkIf (cfg.clientAuthFile != null) {
          ${cfg.onion}.clientAuthorizations = [ cfg.clientAuthFile ];
        };
      };
    };

    services.kiss-cache.publish.cacheUrl = lib.mkDefault "http://${cfg.onion}";

    # Route both `nix copy` and the marker `PUT` through Tor's SOCKS
    # proxy. `socks5h` resolves the .onion inside the proxy; a plain
    # `socks5` URL would leak the hostname to local DNS.
    systemd.services.kiss-cache-publish.environment = {
      ALL_PROXY = "socks5h://${socks}";
      http_proxy = "socks5h://${socks}";
    };
  };
}
