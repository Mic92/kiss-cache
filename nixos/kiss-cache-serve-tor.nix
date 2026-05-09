# Serve the binary cache as Tor v3 hidden services.
#
# Two onions: a read-only one whose descriptor is decryptable by every
# client key, and a writable one limited to writer keys. Tor's v3
# client authorization replaces mTLS as the access control: clients
# without an authorized key cannot even resolve the onion address. The
# .onion transport is end-to-end encrypted, so nginx serves plain HTTP
# on loopback only; reuse `kiss-cache-serve` for clearnet/mTLS access
# instead of (or alongside) this module.
#
# Generate a client keypair with:
#
#   openssl genpkey -algorithm x25519 -out client.pem
#   # public key (server side, `readClients`/`writeClients`):
#   openssl pkey -in client.pem -pubout -outform DER | tail -c32 | base32 | tr -d =
#   # private key (client side, see `kiss-cache-update-tor.nix`):
#   openssl pkey -in client.pem -outform DER | tail -c32 | base32 | tr -d =
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kiss-cache.serve-tor;

  # Unix sockets so nginx never exposes a loopback port: only tor (via
  # BindPaths into its own RootDirectory) and nginx can connect. The
  # directory is shared between the two units; sockets are created by
  # nginx and bind-mounted into tor's namespace.
  socketDir = "/run/kiss-cache-tor";
  readSocket = "${socketDir}/read.sock";
  writeSocket = "${socketDir}/write.sock";

  davCommon = ''
    create_full_put_path on;
    dav_access user:rw group:r all:r;
    client_body_temp_path ${cfg.cacheDir}/.tmp;
  '';
in
{
  options.services.kiss-cache.serve-tor = {
    enable = lib.mkEnableOption "serving a Nix binary cache over Tor hidden services";

    cacheDir = lib.mkOption {
      type = lib.types.path;
      example = "/var/lib/nix-cache";
      description = "Binary cache directory to serve. See `services.kiss-cache.serve.cacheDir`.";
    };

    priority = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        Substituter priority advertised in `nix-cache-info`. Lower
        wins; the default 30 makes this cache preferred over
        cache.nixos.org's 40.
      '';
    };

    readClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "descriptor:x25519:F2OBO4MTBHVRJ6NBYPWY4XAJZYCPCVQTASXHJGYYDNP35JYLG6FA" ];
      description = ''
        Clients authorized to read. One `descriptor:x25519:<base32>`
        public key per client; the matching private key goes on the
        client's machine (see `services.kiss-cache.update-tor`). Empty
        list disables client authorization for the read onion: anyone
        who learns the address can read.
      '';
    };

    writeClients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "descriptor:x25519:K7AHQAERNAITEBRIEHPISMHXXLPQYE3TPCDTVHURE2RT7D7CLB7Q" ];
      description = ''
        Clients authorized to write, same format as
        {option}`readClients`. Writers should appear in *both* lists
        if they also need to read. Must not be empty: an
        unauthenticated write onion would let anyone with the address
        poison the cache.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.writeClients != [ ];
        message = "services.kiss-cache.serve-tor.writeClients must not be empty";
      }
    ];

    services = {
      tor = {
        enable = true;
        relay.onionServices = {
          kiss-cache-read = {
            version = 3;
            map = [
              {
                port = 80;
                target.unix = readSocket;
              }
            ];
            authorizedClients = cfg.readClients;
          };
          kiss-cache-write = {
            version = 3;
            map = [
              {
                port = 80;
                target.unix = writeSocket;
              }
            ];
            authorizedClients = cfg.writeClients;
          };
        };
      };

      # When the pruner is enabled on this host, the write onion's
      # markers are roots.
      kiss-cache.gcRoots = lib.mkIf config.services.kiss-cache.enable [
        "${cfg.cacheDir}/gcroots"
      ];

      nginx = {
        enable = true;
        additionalModules = [ pkgs.nginxModules.njs ];
        appendHttpConfig = ''
          js_import kiss_cache_lock from ${./lock-guard.js};
          js_set $kiss_cache_prune_locked kiss_cache_lock.pruneLockHeld;
        '';
        virtualHosts = {
          # Read-only: serve narinfo/nar and gcroot markers, no DAV.
          kiss-cache-tor-read = {
            listen = [ { addr = "unix:${readSocket}"; } ];
            root = cfg.cacheDir;
            locations = {
              "/".extraConfig = ''
                expires max;
                add_header Cache-Control immutable;
              '';
              "= /nix-cache-info".extraConfig = ''
                default_type text/plain;
                return 200 "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: ${toString cfg.priority}\n";
              '';
              "/gcroots/".extraConfig = ''
                expires off;
                add_header Cache-Control no-store;
              '';
            };
          };
          # Read-write: same plus DAV PUT for `nix copy --to` and
          # PUT/DELETE on /gcroots/.
          kiss-cache-tor-write = {
            listen = [ { addr = "unix:${writeSocket}"; } ];
            root = cfg.cacheDir;
            extraConfig = ''
              set $kiss_cache_lock_dir ${cfg.cacheDir}/gcroots/.lock;
            '';
            locations = {
              "/".extraConfig = ''
                expires max;
                add_header Cache-Control immutable;
                dav_methods PUT;
                ${davCommon}
                client_max_body_size 0;
              '';
              "= /nix-cache-info".extraConfig = ''
                default_type text/plain;
                return 200 "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: ${toString cfg.priority}\n";
              '';
              "/gcroots/".extraConfig = ''
                expires off;
                add_header Cache-Control no-store;
                dav_methods PUT DELETE;
                ${davCommon}
                client_max_body_size 4k;
              '';
              # Lock PUTs are refused while the pruner is running.
              # See lock-guard.js and kiss-cache-serve.nix.
              "/gcroots/.lock/".extraConfig = ''
                if ($kiss_cache_prune_locked) {
                  return 503 "cache is being pruned, retry later\n";
                }
                expires off;
                add_header Cache-Control no-store;
                dav_methods PUT DELETE;
                ${davCommon}
                client_max_body_size 1k;
              '';
            };
          };
        };
      };
    };

    systemd = {
      # nginx writes uploads to a temp file then renames into place;
      # the temp dir must be on the same filesystem.
      tmpfiles.rules = [
        "d ${cfg.cacheDir}/.tmp 0700 ${config.services.nginx.user} ${config.services.nginx.group} -"
        "d ${cfg.cacheDir}/gcroots 0755 ${config.services.nginx.user} ${config.services.nginx.group} -"
        "d ${cfg.cacheDir}/gcroots/.lock 0755 ${config.services.nginx.user} ${config.services.nginx.group} m:1h"
        # Tor connects to the sockets as the `tor` user; group-writable
        # sockets in a tor-group dir let it without granting world access.
        "d ${socketDir} 0750 ${config.services.nginx.user} tor -"
      ];

      # tor.service runs in its own RootDirectory; bind the socket dir
      # into its namespace. The dir is created by tmpfiles before
      # either unit starts, so the bind never refers to a non-existent
      # path.
      services.tor.serviceConfig.BindPaths = [ socketDir ];
      services.nginx.serviceConfig = {
        # Group-readable sockets so the `tor` group can connect.
        UMask = lib.mkDefault "0007";
        # NixOS hardens nginx with ProtectSystem=strict; WebDAV PUT
        # needs an explicit grant to write into the cache directory.
        ReadWritePaths = [ cfg.cacheDir ];
      };
    };
  };
}
