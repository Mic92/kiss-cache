{
  config,
  lib,
  ...
}:
let
  cfg = config.services.kiss-cache;
in
{
  options.services.kiss-cache = {
    enable = lib.mkEnableOption "periodic pruning of a Nix binary cache against GC roots";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The kiss-cache package to use.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      example = "/var/lib/nix-cache";
      description = ''
        Path to the binary cache directory containing `*.narinfo` files and a
        `nar/` subdirectory. Files unreachable from any GC root are deleted.
      '';
    };

    gcRoots = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ "/nix/var/nix/gcroots" ];
      description = ''
        Garbage collector root directories. Anything reachable from a symlink
        under these paths (transitively, via References and Deriver) is kept.
        Plain files whose name is `<hash>-<name>` are also treated as roots,
        so writers pushing over HTTP can register roots with a marker file.
      '';
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      example = "daily";
      description = ''
        How often to prune, in `systemd.time(7)` calendar event format.
      '';
    };

    dryRun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Log what would be deleted without actually deleting anything.
        Useful for validating GC root coverage before enabling pruning.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.kiss-cache = {
      description = "Prune Nix binary cache against GC roots";
      # Don't race the Nix daemon's own GC while it may be rewriting roots.
      after = [ "nix-gc.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs (
          [ (lib.getExe cfg.package) ]
          ++ lib.optional cfg.dryRun "--dry-run"
          ++ [ cfg.cacheDir ]
          ++ cfg.gcRoots
        );
        # Pruning never needs to write outside the cache directory.
        ReadWritePaths = [ cfg.cacheDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        # Long-running on large caches; don't let the default timeout kill it.
        TimeoutStartSec = "infinity";
      };
    };

    systemd.timers.kiss-cache = {
      description = "Periodically prune Nix binary cache";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
