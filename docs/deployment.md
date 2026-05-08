# Pull-based system updates

The gcroot marker can double as a deployment channel. CI builds the
NixOS system, pushes its closure and writes the toplevel store path
into a per-host marker. The target polls that marker, realises the
path through the cache and switches to it.

```console
$ system=$(nix build --no-link --print-out-paths .#nixosConfigurations.web1.config.system.build.toplevel)
$ nix copy --to "$store" "$system"
$ echo "$system" | curl --cert writer.pem --key writer.key \
    -X PUT --data-binary @- "https://cache.example.org/gcroots/web1"
```

On the target:

```nix
services.kiss-cache-update = {
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

