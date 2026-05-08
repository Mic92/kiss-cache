# Reach a kiss-cache .onion from the target side.
#
# Configures Tor client authorization for the cache's read onion and
# routes both the marker fetch and `nix-store --realise` through Tor's
# SOCKS proxy. The .onion transport is end-to-end encrypted so no TLS
# is layered on top.
#
# Generate the client keypair and pass the private key here; the
# matching public key goes into `services.kiss-cache-serve-tor.readClients`
# on the cache. See that module's header for the openssl one-liners.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.kiss-cache-update-tor;
  socks = "127.0.0.1:${toString cfg.socksPort}";
in
{
  options.services.kiss-cache-update-tor = {
    enable = lib.mkEnableOption "pulling NixOS system updates from a kiss-cache .onion";

    onion = lib.mkOption {
      type = lib.types.str;
      example = "exampleexampleexampleexampleexampleexampleexampleexample.onion";
      description = "The cache's read onion address, with the `.onion` suffix.";
    };

    clientAuthFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File containing this client's x25519 private key for the
        onion's client authorization, in the format
        `descriptor:x25519:<base32-private-key>`. `null` if the cache
        does not require client authorization.
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

    services.kiss-cache-update.cacheUrl = lib.mkDefault "http://${cfg.onion}";

    # Route both curl (marker fetch) and nix-store (substitution)
    # through the SOCKS proxy. `socks5h` resolves the .onion inside the
    # proxy; a plain `socks5` URL would leak the hostname to local DNS.
    systemd.services.kiss-cache-update.environment = {
      ALL_PROXY = "socks5h://${socks}";
      # `--option proxy` is not honoured by all Nix versions; the
      # environment variable works for both curl and Nix's libcurl.
      http_proxy = "socks5h://${socks}";
    };
  };
}
