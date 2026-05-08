# Serve a local file:// binary cache over HTTPS with mutual TLS.
#
# Clients must present a certificate signed by `clientCA`. Configure them with
# Nix's `tls-certificate` and `tls-private-key` store parameters:
#
#   substituters = https://cache.example.org?tls-certificate=/path/to/client.pem&tls-private-key=/path/to/client.key
#
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.kiss-cache-serve;
in
{
  options.services.kiss-cache-serve = {
    enable = lib.mkEnableOption "serving a Nix binary cache over HTTPS with mutual TLS";

    cacheDir = lib.mkOption {
      type = lib.types.path;
      example = "/var/lib/nix-cache";
      description = ''
        Binary cache directory to serve. Must contain `*.narinfo` files and a
        `nar/` subdirectory.
      '';
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      example = "cache.example.org";
      description = "Virtual host name the cache is served under.";
    };

    sslCertificate = lib.mkOption {
      type = lib.types.path;
      description = "Server TLS certificate in PEM format.";
    };

    sslCertificateKey = lib.mkOption {
      type = lib.types.path;
      description = "Server TLS private key in PEM format.";
    };

    clientCA = lib.mkOption {
      type = lib.types.path;
      description = ''
        CA certificate used to verify client certificates. Only clients
        presenting a certificate signed by this CA may fetch from the cache.
      '';
    };

    writers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "CN=hydra,O=Example" ];
      description = ''
        Distinguished Names (`ssl_client_s_dn`) of client certificates
        allowed to upload to the cache via WebDAV PUT. Empty list disables
        writes; the cache is read-only.

        Push from a writer with:

        ```
        nix copy --to 'https://cache.example.org?tls-certificate=writer.pem&tls-private-key=writer.key' /nix/store/...
        ```

        To keep a pushed closure from being pruned, also `PUT` a marker
        file to `gcroots/<name>` whose content is the store path(s) to
        keep, one per line. The marker name is yours to choose (e.g. a
        CI job ID):

        ```
        echo /nix/store/... | curl --cert writer.pem --key writer.key \
          -X PUT --data-binary @- https://cache.example.org/gcroots/my-job
        ```
      '';
    };

    gcRootMaxAge = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "30d";
      description = ''
        Delete gcroot marker files older than this age, in
        `tmpfiles.d(5)` age format. The next prune then reclaims any
        cache entries that were only reachable through expired markers.
        Writers must re-`PUT` markers periodically (e.g. on every push)
        to keep their closures alive.

        Cleanup runs from `systemd-tmpfiles-clean.timer` (daily by
        default). Set to `null` to keep markers forever.
      '';
    };

    fallbackCache = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://cache.nixos.org";
      description = ''
        Upstream binary cache to proxy on local miss. The fetched response
        is also stored in `cacheDir`, so the next request for the same path
        is served locally. Stored entries are not registered as GC roots and
        are deleted on the next prune unless reachable from one; this is
        intentional, as they can be refetched on the next miss.

        Clients fetching through the proxy receive the upstream's signature
        unmodified. Add the upstream's public key to `trusted-public-keys`
        alongside this cache's own key.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open port 443 in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.nginx = {
      enable = true;
      # ssl_client_s_dn is only available in `if`/`map`, so the writer ACL is
      # implemented as a map from DN to a boolean and checked per request.
      appendHttpConfig = lib.mkIf (cfg.writers != [ ]) ''
        map $ssl_client_s_dn $nix_cache_writer {
          default 0;
          ${lib.concatMapStringsSep "\n  " (dn: "\"${dn}\" 1;") cfg.writers}
        }
      '';
      virtualHosts.${cfg.hostName} = {
        forceSSL = true;
        inherit (cfg) sslCertificate sslCertificateKey;
        root = cfg.cacheDir;
        extraConfig = ''
          ssl_client_certificate ${cfg.clientCA};
          ssl_verify_client on;
        '';
        locations = {
          "/".extraConfig = ''
            # narinfo and nar files are content-addressed and immutable.
            expires max;
            add_header Cache-Control immutable;
          ''
          + lib.optionalString (cfg.fallbackCache != null) ''
            # On a 404 from the static handler, retry against the upstream.
            # Unlike try_files, error_page only fires after the content phase
            # has run, so a PUT for a not-yet-existing file is still created
            # by dav_methods rather than forwarded to the upstream.
            error_page 404 = @fallback;
          ''
          + lib.optionalString (cfg.writers != [ ]) ''
            # WebDAV PUT for `nix copy --to https://...`. Reads are open to
            # any mTLS client; writes only to certificates in `writers`.
            set $deny_write 0;
            if ($request_method !~ ^(GET|HEAD)$) {
              set $deny_write 1;
            }
            if ($nix_cache_writer = 1) {
              set $deny_write 0;
            }
            if ($deny_write = 1) {
              return 403;
            }
            dav_methods PUT;
            create_full_put_path on;
            dav_access user:rw group:r all:r;
            # nginx writes the upload to a temp file then rename()s it into
            # place; keeping the temp dir on the same filesystem makes that
            # rename atomic and avoids a copy.
            client_body_temp_path ${cfg.cacheDir}/.tmp;
            client_max_body_size 0;
          '';
          "= /nix-cache-info".extraConfig = ''
            default_type text/plain;
            return 200 "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n";
          '';
          # On local miss, fetch from the upstream cache and store the result
          # at the same path so the next request is a local hit. proxy_store
          # is not subject to expiry, which matches the immutability of
          # content-addressed cache entries; stale entries are reclaimed by
          # the pruner like any other unreachable file.
          "@fallback" = lib.mkIf (cfg.fallbackCache != null) {
            extraConfig = ''
              internal;
              proxy_pass ${cfg.fallbackCache};
              proxy_set_header Host ${builtins.head (builtins.match "https?://([^/]+).*" cfg.fallbackCache)};
              proxy_ssl_server_name on;
              proxy_store on;
              proxy_store_access user:rw group:r all:r;
              proxy_temp_path ${cfg.cacheDir}/.tmp;
              # The upstream responds 404 for paths it does not have either.
              # Do not store error pages.
              proxy_intercept_errors off;
            '';
          };
          # Marker files registering remote gcroots (see `writers` doc).
          # Writers PUT/DELETE markers; any authenticated client may GET
          # them, so target machines can use a marker as their profile
          # pointer (see `services.kiss-cache-update`).
          "/gcroots/" = lib.mkIf (cfg.writers != [ ]) {
            extraConfig = ''
              # Same write ACL as `/`: any authenticated client may GET a
              # marker (used as a profile pointer by kiss-cache-update),
              # only writers may PUT or DELETE.
              set $deny_write 0;
              if ($request_method !~ ^(GET|HEAD)$) {
                set $deny_write 1;
              }
              if ($nix_cache_writer = 1) {
                set $deny_write 0;
              }
              if ($deny_write = 1) {
                return 403;
              }
              dav_methods PUT DELETE;
              create_full_put_path on;
              dav_access user:rw group:r all:r;
              client_body_temp_path ${cfg.cacheDir}/.tmp;
              client_max_body_size 4k;
              # Markers change on every push; do not let nix's HTTP cache
              # serve stale ones.
              expires off;
              add_header Cache-Control no-store;
            '';
          };
        };
      };
    };

    systemd.tmpfiles.rules = lib.mkIf (cfg.writers != [ ] || cfg.fallbackCache != null) (
      [
        "d ${cfg.cacheDir}/.tmp 0700 ${config.services.nginx.user} ${config.services.nginx.group} -"
      ]
      ++ lib.optional (cfg.writers != [ ]) (
        let
          # Age by mtime only: writers refresh markers with PUT, which updates
          # mtime. The default age-by also checks ctime, which a backup restore
          # or rsync resets, accidentally extending a marker's lifetime.
          age = if cfg.gcRootMaxAge == null then "-" else "m:${cfg.gcRootMaxAge}";
        in
        "d ${cfg.cacheDir}/gcroots 0755 ${config.services.nginx.user} ${config.services.nginx.group} ${age}"
      )
    );

    # NixOS hardens nginx with ProtectSystem=strict; both WebDAV PUT and
    # proxy_store need an explicit grant to write into the cache directory.
    systemd.services.nginx.serviceConfig.ReadWritePaths = lib.mkIf (
      cfg.writers != [ ] || cfg.fallbackCache != null
    ) [ cfg.cacheDir ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 443 ];
  };
}
