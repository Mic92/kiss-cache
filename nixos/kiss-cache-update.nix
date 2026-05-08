# Pull the host's NixOS system closure from a kiss-cache and switch to it.
#
# CI builds the system, `nix copy`s the closure into the cache, and PUTs
# the toplevel store path into a gcroot marker (one per host). Targets
# poll that marker, realise the path through the cache and switch. The
# marker thus does double duty: it protects the closure from pruning and
# tells the host what to run.
#
# Adapted from nix-community/infra's modules/nixos/common/update.bash.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.kiss-cache-update;

  # The marker fetch (curl) and the substitution (nix-store) hit the
  # same cache; keep their TLS credentials derived from one option set
  # so they cannot disagree.
  curlTls =
    lib.optionalString (
      cfg.tlsCertificate != null
    ) " --cert ${cfg.tlsCertificate} --key ${cfg.tlsPrivateKey}"
    + lib.optionalString (cfg.tlsCACertificate != null) " --cacert ${cfg.tlsCACertificate}";
  # `ssl-cert-file` is a global Nix option, not a substituter URL
  # parameter; pass it via `--option`.
  storeTls = lib.optionalString (
    cfg.tlsCertificate != null
  ) "&tls-certificate=${cfg.tlsCertificate}&tls-private-key=${cfg.tlsPrivateKey}";
  storeOpts = lib.optionalString (
    cfg.tlsCACertificate != null
  ) " --option ssl-cert-file ${cfg.tlsCACertificate}";

  # Standalone CLI: `kiss-cache-update <switch|reboot> [MARKER_URL]`.
  # The action is required so a manual run is always explicit about
  # whether it may reboot the machine. The systemd unit passes
  # cfg.onBootChange. The marker URL defaults to the configured one;
  # override it to test a candidate system without publishing it.
  updateScript = pkgs.writeShellApplication {
    name = "kiss-cache-update";
    runtimeInputs = [
      config.nix.package
      config.systemd.package
      pkgs.coreutils # readlink, realpath, shuf, cat
      pkgs.curl
    ]
    ++ lib.optional cfg.kexec pkgs.kexec-tools;
    text = ''
      usage() {
        echo "usage: kiss-cache-update <switch|reboot> [MARKER_URL]" >&2
        exit 2
      }
      action="''${1:-}"
      [[ "$action" == switch || "$action" == reboot ]] || usage
      marker_url="''${2:-${cfg.cacheUrl}/gcroots/${cfg.marker}}"
      # The substituter is always the configured cache, even when an
      # override marker URL is passed: the override is for picking a
      # different system, not a different store.
      substituter=${lib.escapeShellArg "${cfg.cacheUrl}?priority=10${storeTls}"}

      # Take the first store-path line; ignore unrelated content. An
      # absent or empty marker means CI has not published yet; that is
      # not an error. Capture before grep rather than pipe: with
      # `pipefail`, `grep -m1` exiting early can SIGPIPE curl on a
      # marker large enough to need a second write, failing the whole
      # pipeline despite a successful match.
      content=$(curl --fail --silent --show-error --location${curlTls} "$marker_url" || true)
      target=$(grep -m1 '^/nix/store/' <<< "$content" || true)

      cancel_reboot() {
        if [[ -e /run/systemd/shutdown/scheduled ]]; then
          shutdown -c
          ${lib.optionalString cfg.kexec "kexec --unload || true"}
        fi
      }

      if [[ -z "$target" ]]; then
        echo "no system published at $marker_url" >&2
        exit 0
      fi
      if [[ "$(readlink /run/current-system)" == "$target" ]]; then
        cancel_reboot
        exit 0
      fi

      echo "realising $target" >&2
      nix-store --option narinfo-cache-negative-ttl 0 \
        --option extra-substituters "$substituter"${storeOpts} \
        --realise "$target"
      nix-env --profile /nix/var/nix/profiles/system --set "$target"

      # If the kernel, initrd or kernel params changed, a plain
      # `switch` cannot fully apply the new system. `kernel` and
      # `initrd` are symlinks: compare their resolved targets so a
      # rebuild that links to the same store path is not flagged.
      # `kernel-params` is a plain file: compare content. A missing
      # entry (e.g. no initrd) hashes the empty string on both sides.
      boot_fingerprint() {
        realpath -m "$1/kernel" "$1/initrd"
        cat "$1/kernel-params" 2>/dev/null || true
      }
      booted=$(boot_fingerprint "$(readlink /run/booted-system)")
      built=$(boot_fingerprint "$target")
      if [[ "$booted" != "$built" ]]; then
        case "$action" in
          reboot)
            /nix/var/nix/profiles/system/bin/switch-to-configuration boot
            ${lib.optionalString cfg.kexec ''
              if ! systemd-detect-virt --quiet; then
                kexec --load "$target/kernel" --initrd="$target/initrd" \
                  --append="$(cat "$target/kernel-params") init=$target/init"
              fi
            ''}
            if [[ ! -e /run/systemd/shutdown/scheduled ]]; then
              # Random delay so a fleet does not reboot in lockstep.
              shutdown -r "+$(shuf -i 5-60 -n 1)"
            fi
            ;;
          switch)
            echo "warning: $target needs a reboot; activating userspace only" >&2
            echo "warning: run 'switch-to-configuration boot' and reboot to apply fully" >&2
            /nix/var/nix/profiles/system/bin/switch-to-configuration switch
            ;;
        esac
      else
        cancel_reboot
        /nix/var/nix/profiles/system/bin/switch-to-configuration switch
      fi
    '';
  };
in
{
  options.services.kiss-cache-update = {
    enable = lib.mkEnableOption "pulling NixOS system updates from a kiss-cache";

    cacheUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://cache.example.org";
      description = "Base URL of the kiss-cache, without trailing slash.";
    };

    marker = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = ''
        Name of the gcroot marker to read the system store path from.
        The marker's first line that parses as a `/nix/store/...` path
        is realised and switched to. Empty file means no published
        system; the run exits without doing anything.
      '';
    };

    tlsCertificate = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Client certificate for mTLS to both the marker endpoint and the
        cache substituter. `null` if the cache does not require client
        authentication.
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

    interval = lib.mkOption {
      type = lib.types.str;
      default = "5m";
      description = ''
        Polling interval for the systemd timer, in `systemd.time(7)`
        span syntax. Applies as both `OnBootSec` and
        `OnUnitInactiveSec`.
      '';
    };

    onBootChange = lib.mkOption {
      type = lib.types.enum [
        "switch"
        "reboot"
      ];
      default = "switch";
      description = ''
        What to do when the new system's kernel, initrd or kernel
        parameters differ from the booted ones, so a plain `switch`
        cannot fully apply it:

        - `switch`: activate userspace anyway and log a warning. The
          bootloader is not touched; an operator must run
          `switch-to-configuration boot` and reboot to pick up the new
          kernel. Safest default: nothing changes the next boot behind
          your back.
        - `reboot`: install the new bootloader entry, then schedule a
          reboot a random 5–60 minutes out (so a fleet does not bounce
          in lockstep). Use {option}`kexec` to skip firmware re-init.

        Userspace-only changes always activate immediately with
        `switch`, regardless of this option.
      '';
    };

    kexec = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use `kexec` instead of a full firmware reboot when a reboot is
        required. Skipped inside virtual machines, where a full reboot
        is fast. Has no effect unless the run rebooted (timer with
        {option}`onBootChange` = `reboot`, or `kiss-cache-update
        reboot` from the CLI).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.tlsCertificate == null) == (cfg.tlsPrivateKey == null);
        message = "services.kiss-cache-update: tlsCertificate and tlsPrivateKey must be set together";
      }
    ];

    # The update service realises whatever store path the marker
    # names, then runs that closure's switch-to-configuration as root.
    # Nix store signatures are the only thing stopping a compromised
    # cache from taking over the host. Surface that risk if they are
    # turned off.
    warnings =
      lib.optional ((config.nix.settings.require-sigs or true) == false)
        "services.kiss-cache-update: nix.settings.require-sigs is off; a compromised cache could take over this host";

    environment.systemPackages = [ updateScript ];

    systemd.services.kiss-cache-update = {
      description = "Pull NixOS system update from kiss-cache";
      # Switching changes this very unit's definition; do not let a
      # mid-switch restart kill the activation script.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "30s";
        ExecStart = "${lib.getExe updateScript} ${cfg.onBootChange}";
      };
    };

    systemd.timers.kiss-cache-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = cfg.interval;
        OnUnitInactiveSec = cfg.interval;
      };
    };
  };
}
