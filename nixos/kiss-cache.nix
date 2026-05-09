{
  config,
  lib,
  pkgs,
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
      default = pkgs.callPackage ../package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ../package.nix { }";
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
      description = ''
        Garbage collector root directories. Each plain file under these
        paths is a marker file containing one or more store paths, one
        per line. Anything reachable from a marked path (transitively,
        via References and Deriver) is kept.
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

    lockWait = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = ''
        Seconds to wait for in-flight uploads to drain before pruning.
        Writers take a cooperative lock in `gcroots/.lock/`; the
        pruner waits until none is fresh. After this budget the run
        fails (and the timer retries on its next trigger).
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
          [
            (lib.getExe cfg.package)
            "prune"
          ]
          ++ lib.optional cfg.dryRun "--dry-run"
          ++ [
            "--lock-wait"
            (toString cfg.lockWait)
          ]
          ++ [ cfg.cacheDir ]
          ++ cfg.gcRoots
        );
        # Writes the lock file under gcroots/, deletes from cacheDir.
        ReadWritePaths = [ cfg.cacheDir ] ++ cfg.gcRoots;
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
