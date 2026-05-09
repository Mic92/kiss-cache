# Pull-based system updates

The gcroot marker can double as a deployment channel. A builder
rebuilds the NixOS system, pushes its closure and writes the toplevel
store path into a per-host marker. The target polls that marker,
realises the path through the cache and switches to it.

## Publishing

From CI or any shell:

```console
$ system=$(nix build --no-link --print-out-paths .#nixosConfigurations.web1.config.system.build.toplevel)
$ nix run github:Mic92/kiss-cache -- with-lock \
    https://cache.example.org/gcroots/web1 "$system" \
    --cert writer.pem --key writer.key --cacert ca.pem -- \
    nix copy --to "$store" "$system"
```

The wrapper takes a cooperative lock that keeps a concurrent prune
from sweeping a shared dependency between `nix copy` and the marker
landing, then PUTs the marker. See
[docs/pruner.md](pruner.md#concurrent-writes).

Or use `services.kiss-cache.publish`, which handles the lock
automatically and rebuilds on a timer. One builder publishes any number of systems; targets
subscribe to their marker:

```nix
services.kiss-cache.publish = {
  enable = true;
  cacheUrl = "https://cache.example.org";
  schedule = "*-*-* 02:00:00";
  secretKeyFile = "/run/keys/cache-key";
  tlsCertificate = "/etc/ssl/writer.pem";
  tlsPrivateKey = "/etc/ssl/writer.key";
  systems = [
    {
      flakeRef = "github:example/infra#nixosConfigurations.web1.config.system.build.toplevel";
      marker = "web1";
    }
    {
      flakeRef = "github:example/infra#nixosConfigurations.web2.config.system.build.toplevel";
      marker = "web2";
    }
  ];
};
```

A `kiss-cache-publish [MARKER...]` CLI is on PATH for manual
rebuilds. With no arguments it publishes every configured system;
with marker names it publishes only those:

```console
$ kiss-cache-publish web1 web2
```

When the publisher runs on the cache server itself, set `cacheDir`
instead of `cacheUrl`: closures copy via `file://` and markers are
written directly, no HTTP, no writer certificate.

```nix
services.kiss-cache.publish = {
  enable = true;
  cacheDir = "/var/lib/nix-cache";
  secretKeyFile = "/run/keys/cache-key";
  systems = [ ... ];
};
```

## Subscribing

On the target:

```nix
services.kiss-cache.update = {
  enable = true;
  cacheUrl = "https://cache.example.org";
  marker = "web1";  # default: networking.hostName
  tlsCertificate = "/etc/ssl/reader.pem";
  tlsPrivateKey = "/etc/ssl/reader.key";
  interval = "5m";
};
```

If the new system needs a different kernel, initrd or kernel
parameters, the default behaviour is to activate userspace and log a
warning rather than touch the bootloader behind your back. Set
`onBootChange = "reboot"` (and optionally `kexec = true`) to install
the bootloader entry and schedule a randomised reboot.

The module also installs a `kiss-cache-update <switch|reboot>
[MARKER_URL]` CLI for manual invocation. The action is required so an
operator at a shell is always explicit about whether the run may
reboot the machine; the optional marker URL lets you test a candidate
system before publishing it to the host's default marker:

```console
$ kiss-cache-update switch https://cache.example.org/gcroots/web1-canary
```

