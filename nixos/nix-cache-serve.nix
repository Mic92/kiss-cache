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
  cfg = config.services.nix-cache-serve;
in
{
  options.services.nix-cache-serve = {
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

        To keep a pushed closure from being pruned, also `PUT` an empty
        marker file to `gcroots/<hash>-<name>`:

        ```
        curl --cert writer.pem --key writer.key -X PUT --data-binary @/dev/null \
          https://cache.example.org/gcroots/$(basename /nix/store/...)
        ```
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
        sslCertificate = cfg.sslCertificate;
        sslCertificateKey = cfg.sslCertificateKey;
        root = cfg.cacheDir;
        extraConfig = ''
          ssl_client_certificate ${cfg.clientCA};
          ssl_verify_client on;
        '';
        locations."/" = {
          extraConfig = ''
            # narinfo and nar files are content-addressed and immutable.
            expires max;
            add_header Cache-Control immutable;
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
        };
        locations."= /nix-cache-info".extraConfig = ''
          default_type text/plain;
          return 200 "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n";
        '';
        # Marker files registering remote gcroots (see `writers` doc). The
        # pruner reads this directory; nginx never serves its contents.
        locations."/gcroots/" = lib.mkIf (cfg.writers != [ ]) {
          extraConfig = ''
            if ($nix_cache_writer != 1) {
              return 403;
            }
            dav_methods PUT DELETE;
            create_full_put_path on;
            dav_access user:rw group:r all:r;
            client_body_temp_path ${cfg.cacheDir}/.tmp;
            client_max_body_size 4k;
          '';
        };
      };
    };

    systemd.tmpfiles.rules = lib.mkIf (cfg.writers != [ ]) [
      "d ${cfg.cacheDir}/.tmp 0700 ${config.services.nginx.user} ${config.services.nginx.group} -"
      "d ${cfg.cacheDir}/gcroots 0755 ${config.services.nginx.user} ${config.services.nginx.group} -"
    ];

    # NixOS hardens nginx with ProtectSystem=strict; the WebDAV PUT path
    # needs an explicit grant to write into the cache directory.
    systemd.services.nginx.serviceConfig.ReadWritePaths = lib.mkIf (cfg.writers != [ ]) [
      cfg.cacheDir
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 443 ];
  };
}
