# Serve the binary cache behind OIDC bearer-token authentication.
#
# Designed for CI systems that issue short-lived OIDC tokens, e.g.
# GitHub Actions: a workflow requests a token from
# `token.actions.githubusercontent.com` with this cache as the
# audience, sends it as `Authorization: Bearer ...`, and nginx
# validates the JWT against the issuer's JWKS in an njs module before
# letting the request through. Stateless: no session, no database.
#
# Read and write access are gated by *subject* allowlists. GitHub
# subjects look like `repo:owner/name:ref:refs/heads/main` or
# `repo:owner/name:environment:production`; `*` matches any segment.
#
# `Authorization` cannot carry an mTLS client cert, so this module
# replaces (rather than extends) `kiss-cache-serve`. Use one or the
# other per virtual host.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kiss-cache-serve-oidc;

  davCommon = ''
    create_full_put_path on;
    dav_access user:rw group:r all:r;
    client_body_temp_path ${cfg.cacheDir}/.tmp;
  '';
in
{
  options.services.kiss-cache-serve-oidc = {
    enable = lib.mkEnableOption "serving a Nix binary cache with OIDC bearer-token authentication";

    cacheDir = lib.mkOption {
      type = lib.types.path;
      example = "/var/lib/nix-cache";
      description = "Binary cache directory to serve. See `services.kiss-cache-serve.cacheDir`.";
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

    priority = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = ''
        Substituter priority advertised in `nix-cache-info`. Lower
        wins; the default 30 makes this cache preferred over
        cache.nixos.org's 40.
      '';
    };

    issuer = lib.mkOption {
      type = lib.types.str;
      default = "https://token.actions.githubusercontent.com";
      description = "OIDC issuer (`iss` claim) the cache trusts.";
    };

    jwksUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://token.actions.githubusercontent.com/.well-known/jwks";
      description = "JWKS endpoint to fetch the issuer's signing keys from.";
    };

    audience = lib.mkOption {
      type = lib.types.str;
      example = "https://cache.example.org";
      description = ''
        Required `aud` claim. Workflows must request the token with
        this audience so a token minted for one service cannot be
        replayed against another.
      '';
    };

    readSubjects = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "repo:example/*" ];
      description = ''
        `sub` claims allowed to read, with `*` matching any segment.
      '';
    };

    writeSubjects = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "repo:example/infra:ref:refs/heads/main" ];
      description = ''
        `sub` claims allowed to write. Be specific: a wildcard write
        subject lets any matching workflow poison the cache.
      '';
    };

    resolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        # Prefer the host's own resolver: the public ones would leak
        # every JWKS fetch to a third party and break on hosts without
        # direct egress.
        if config.networking.nameservers != [ ] then
          config.networking.nameservers
        else if config.services.resolved.enable then
          [ "127.0.0.53" ]
        else
          [ ];
      defaultText = lib.literalExpression "networking.nameservers, or 127.0.0.53 with resolved";
      description = ''
        DNS servers nginx uses to resolve {option}`jwksUrl`. nginx
        cannot read `/etc/resolv.conf`, so the resolver must be
        configured explicitly. Required when {option}`jwksUrl` is not
        a literal IP address.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.readSubjects != [ ];
        message = "services.kiss-cache-serve-oidc.readSubjects must not be empty";
      }
      {
        assertion = cfg.writeSubjects != [ ];
        message = "services.kiss-cache-serve-oidc.writeSubjects must not be empty";
      }
      {
        # nginx resolves jwksUrl at request time; without a resolver
        # it logs `no resolver defined` and every auth fails. A
        # numeric host (testing, internal proxy) needs none.
        assertion =
          cfg.resolvers != [ ]
          || builtins.match "https?://[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+([:/].*)?" cfg.jwksUrl != null;
        message = "services.kiss-cache-serve-oidc.resolvers must not be empty when jwksUrl is not a literal IP";
      }
    ];

    services.nginx = {
      enable = true;
      additionalModules = [ pkgs.nginxModules.njs ];
      # `js_import` must be at http scope, and njs's `ngx.fetch` needs
      # an explicit resolver: nginx does not consult /etc/resolv.conf.
      appendHttpConfig = ''
        js_import kiss_cache_oidc from ${./oidc-auth.js};
        js_import kiss_cache_lock from ${./lock-guard.js};
        js_set $kiss_cache_prune_locked kiss_cache_lock.pruneLockHeld;
      ''
      + lib.optionalString (cfg.resolvers != [ ]) ''
        resolver ${lib.concatStringsSep " " cfg.resolvers} valid=300s;
      '';
      virtualHosts.${cfg.hostName} = {
        forceSSL = true;
        inherit (cfg) sslCertificate sslCertificateKey;
        root = cfg.cacheDir;
        # nginx evaluates `set` per request; the subject lists are JSON
        # strings so njs can parse them. The auth endpoint picks a list
        # by inspecting the parent request's method.
        extraConfig = ''
          set $oidc_jwks_url "${cfg.jwksUrl}";
          set $oidc_issuer "${cfg.issuer}";
          set $oidc_audience "${cfg.audience}";
          set $oidc_read_subjects '${builtins.toJSON cfg.readSubjects}';
          set $oidc_write_subjects '${builtins.toJSON cfg.writeSubjects}';
          set $kiss_cache_lock_dir ${cfg.cacheDir}/gcroots/.lock;
          location = /__kiss_cache_oidc_auth {
            internal;
            js_content kiss_cache_oidc.auth;
          }
        '';
        locations = {
          "/" = {
            extraConfig = ''
              expires max;
              add_header Cache-Control immutable;
              auth_request /__kiss_cache_oidc_auth;
              dav_methods PUT;
              ${davCommon}
              client_max_body_size 0;
            '';
          };
          # `return` runs in the rewrite phase and short-circuits the
          # access phase, so `auth_request` would never fire. Serve a
          # static file instead.
          "= /nix-cache-info" = {
            alias = pkgs.writeText "nix-cache-info" ''
              StoreDir: /nix/store
              WantMassQuery: 1
              Priority: ${toString cfg.priority}
            '';
            extraConfig = ''
              auth_request /__kiss_cache_oidc_auth;
              default_type text/plain;
            '';
          };
          "/gcroots/".extraConfig = ''
            auth_request /__kiss_cache_oidc_auth;
            dav_methods PUT DELETE;
            ${davCommon}
            client_max_body_size 4k;
            expires off;
            add_header Cache-Control no-store;
          '';
          # Lock PUTs are refused while the pruner is running.
          # See lock-guard.js and kiss-cache-serve.nix.
          "/gcroots/.lock/".extraConfig = ''
            auth_request /__kiss_cache_oidc_auth;
            if ($kiss_cache_prune_locked) {
              return 503 "cache is being pruned, retry later\n";
            }
            dav_methods PUT DELETE;
            ${davCommon}
            client_max_body_size 1k;
            expires off;
            add_header Cache-Control no-store;
          '';
        };
      };
    };

    systemd.services.nginx.serviceConfig.ReadWritePaths = [ cfg.cacheDir ];
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheDir}/.tmp 0700 ${config.services.nginx.user} ${config.services.nginx.group} -"
      "d ${cfg.cacheDir}/gcroots 0755 ${config.services.nginx.user} ${config.services.nginx.group} -"
      "d ${cfg.cacheDir}/gcroots/.lock 0755 ${config.services.nginx.user} ${config.services.nginx.group} m:1h"
    ];

    services.kiss-cache.gcRoots = lib.mkIf config.services.kiss-cache.enable [
      "${cfg.cacheDir}/gcroots"
    ];
  };
}
