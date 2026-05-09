# Periodically rebuild NixOS systems and publish them to a kiss-cache.
#
# The push side of a pull-based deployment: a builder rebuilds each
# configured system on a timer, `nix copy`s the closure into the
# cache, and PUTs the toplevel store path into a per-host gcroot
# marker. Targets running `services.kiss-cache-update` pick it up on
# their next poll. See docs/deployment.md.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kiss-cache-publish;
  local = cfg.cacheDir != null;

  # `?` parameters for `nix copy --to` and curl flags for the lock
  # and marker writes. Derived from the same options so they cannot
  # disagree.
  storeTls = lib.optionalString (
    cfg.tlsCertificate != null
  ) "&tls-certificate=${cfg.tlsCertificate}&tls-private-key=${cfg.tlsPrivateKey}";
  curlTls =
    lib.optional (cfg.tlsCertificate != null) [
      "--cert"
      cfg.tlsCertificate
      "--key"
      cfg.tlsPrivateKey
    ]
    ++ lib.optional (cfg.tlsCACertificate != null) [
      "--cacert"
      cfg.tlsCACertificate
    ];
  storeOpts = lib.optionalString (
    cfg.tlsCACertificate != null
  ) " --option ssl-cert-file ${cfg.tlsCACertificate}";
  signOpt = lib.optionalString (cfg.secretKeyFile != null) "&secret-key=${cfg.secretKeyFile}";

  store =
    if local then
      "file://${cfg.cacheDir}?compression=zstd${signOpt}"
    else
      "${cfg.cacheUrl}?compression=zstd${signOpt}${storeTls}";

  marker =
    sys:
    if local then "${cfg.cacheDir}/gcroots/${sys.marker}" else "${cfg.cacheUrl}/gcroots/${sys.marker}";

  # CLI: `kiss-cache-publish [MARKER...]`. No arguments publishes
  # everything; marker names publish only those. The push step runs
  # under `kiss-cache with-lock`, which takes a cooperative lock
  # against the pruner; see docs/pruner.md and spec/prune.als.
  publishScript = pkgs.writeShellApplication {
    name = "kiss-cache-publish";
    runtimeInputs = [
      config.nix.package
      pkgs.coreutils
      cfg.package
    ];
    text = ''
      all=(${lib.escapeShellArgs (map (s: s.marker) cfg.systems)})
      if [[ $# -eq 0 ]]; then
        want=("''${all[@]}")
      else
        for m in "$@"; do
          case " ''${all[*]} " in
            *" $m "*) ;;
            *) echo "unknown marker: $m (configured: ''${all[*]})" >&2; exit 2 ;;
          esac
        done
        want=("$@")
      fi

      selected() {
        local m
        for m in "''${want[@]}"; do [[ "$m" == "$1" ]] && return 0; done
        return 1
      }

      fail=0
      ${lib.concatMapStringsSep "\n" (sys: ''
        if selected ${lib.escapeShellArg sys.marker}; then
          echo "building ${sys.flakeRef}" >&2
          if out=$(nix build --no-link --print-out-paths${storeOpts} \
              ${lib.escapeShellArg sys.flakeRef}); then
            echo "pushing $out" >&2
            kiss-cache with-lock ${lib.escapeShellArg (marker sys)} "$out" \
              ${lib.escapeShellArgs (lib.flatten curlTls)} -- \
              nix copy${storeOpts} --to ${lib.escapeShellArg store} "$out"
          else
            echo "build failed: ${sys.flakeRef}" >&2
            fail=1
          fi
        fi
      '') cfg.systems}
      exit "$fail"
    '';
  };
in
{
  options.services.kiss-cache-publish = {
    enable = lib.mkEnableOption "rebuilding and publishing NixOS systems to a kiss-cache";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../package.nix { }";
      description = "The kiss-cache package providing `kiss-cache with-lock`.";
    };

    cacheUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://cache.example.org";
      description = ''
        Base URL of a remote kiss-cache, without trailing slash.
        Mutually exclusive with {option}`cacheDir`.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/nix-cache";
      description = ''
        Local cache directory when publish is colocated with
        `kiss-cache-serve`: closures are copied via `file://` and
        markers written directly, no HTTP round-trip. Mutually
        exclusive with {option}`cacheUrl`.
      '';
    };

    systems = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            flakeRef = lib.mkOption {
              type = lib.types.str;
              example = "github:example/infra#nixosConfigurations.web1.config.system.build.toplevel";
              description = ''
                Flake installable to build. Works for any flake URI
                including `git+https://`, `path:` and pinned revisions.
              '';
            };
            marker = lib.mkOption {
              type = lib.types.str;
              example = "web1";
              description = ''
                Name of the gcroot marker to publish under. Must match
                the target's `services.kiss-cache-update.marker`.
              '';
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          flakeRef = "github:example/infra#nixosConfigurations.web1.config.system.build.toplevel";
          marker = "web1";
        }
      ];
      description = "Systems to build and publish, one per target host.";
    };

    secretKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Nix store signing key. The cache stores whatever it is given;
        signatures are how clients tell a tampered path from a real
        one. `null` only if all clients trust unsigned paths.
      '';
    };

    tlsCertificate = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Writer client certificate for mTLS. `null` if the cache does
        not require client authentication.
      '';
    };

    tlsPrivateKey = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Private key for {option}`tlsCertificate`.";
    };

    tlsCACertificate = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        CA certificate the cache server's TLS certificate is verified
        against. `null` to use the system trust store.
      '';
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      example = "*-*-* 02:00:00";
      description = ''
        `systemd.time(7)` calendar expression for when to rebuild and
        publish.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.cacheUrl == null) != (cfg.cacheDir == null);
        message = "services.kiss-cache-publish: set exactly one of cacheUrl or cacheDir";
      }
      {
        assertion = (cfg.tlsCertificate == null) == (cfg.tlsPrivateKey == null);
        message = "services.kiss-cache-publish: tlsCertificate and tlsPrivateKey must be set together";
      }
      {
        # mTLS options have no effect for file:// access; catch the
        # inconsistency rather than ignore the options silently.
        assertion = local -> (cfg.tlsCertificate == null && cfg.tlsCACertificate == null);
        message = "services.kiss-cache-publish: TLS options have no effect with cacheDir";
      }
      {
        assertion = cfg.systems != [ ];
        message = "services.kiss-cache-publish.systems must not be empty";
      }
    ];

    environment.systemPackages = [ publishScript ];

    # When colocated with the pruner, the directly-written markers
    # are roots.
    services.kiss-cache.gcRoots = lib.mkIf (local && config.services.kiss-cache.enable) [
      "${cfg.cacheDir}/gcroots"
    ];
    systemd = {
      # Only create the gcroots dir if no other module already does
      # (kiss-cache-serve manages it with an age policy). A second `d`
      # rule with no age would shadow the policy and disable expiry.
      tmpfiles.rules = lib.mkIf (local && !(config.services.kiss-cache-serve.enable or false)) [
        "d ${cfg.cacheDir}/gcroots 0755 root root -"
      ];

      services.kiss-cache-publish = {
        description = "Rebuild and publish NixOS systems to kiss-cache";
        # When pruning runs on the same host, do not race a marker
        # rewrite against the GC root scan.
        before = lib.mkIf local [ "kiss-cache.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe publishScript;
          # Long builds; do not let the default timeout kill them.
          TimeoutStartSec = "infinity";
          # Builds may pull from the network; do not hammer on flake
          # eval failures.
          Restart = "no";
        };
      };

      timers.kiss-cache-publish = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "5m";
        };
      };
    };
  };
}
