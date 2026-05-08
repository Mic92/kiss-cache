# kiss-cache

Yet another garbage collector for Nix binary caches.

This one runs with a list of GC roots just like your ordinary
`nix-collect-garbage`. It does not operate time-based to expire old
files like [lheckemann's
cache-gc](https://github.com/lheckemann/cache-gc).

## Usage

```console
$ nix run github:Mic92/kiss-cache -- --help
Trim Nix binary caches according to GC roots

Usage: kiss-cache [-n|--dry-run] <CACHEDIR> [GCROOTS...]

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Garbage collector roots [default: /nix/var/nix/gcroots]

Options:
  -n, --dry-run  Do not actually delete files
  -h, --help     Print help
  -V, --version  Print version
```

## How it works

1. Recursively follow symlinks under each `GCROOTS` directory until they
   reach a `/nix/store/<hash>-<name>` path. Those are the roots.
2. For each root, parse `<CACHEDIR>/<hash>.narinfo` and recurse into its
   `References:` and `Deriver:` fields. The transitive closure is the set
   of reachable hashes.
3. Delete every `*.narinfo` and `nar/*` file in `CACHEDIR` not reachable
   from any root.

Plain files in a gcroots directory whose basename is `<hash>-<name>` are
also treated as roots, so processes that cannot create symlinks (e.g.
remote builders pushing via HTTP `PUT`) can register roots by uploading
an empty marker file.

A persistent metadata cache at `<CACHEDIR>/.kiss-cache.closures`
speeds up repeated runs by skipping the parse of unchanged `.narinfo`
files. It is written after every non-dry-run pass and is safe to delete.

## NixOS modules

The flake ships two NixOS modules and a `default` module that wires them
together:

- **`services.kiss-cache`** — runs the pruner on a systemd timer.
- **`services.kiss-cache-serve`** — serves the cache over HTTPS with
  mutual TLS via nginx, with optional WebDAV `PUT` for trusted writers.

```nix
{
  inputs.kiss-cache.url = "github:Mic92/kiss-cache";

  outputs = { self, nixpkgs, kiss-cache }: {
    nixosConfigurations.cache = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        kiss-cache.nixosModules.default
        {
          services.kiss-cache-serve = {
            enable = true;
            cacheDir = "/var/lib/nix-cache";
            hostName = "cache.example.org";
            sslCertificate = "/etc/ssl/cache.pem";
            sslCertificateKey = "/etc/ssl/cache.key";
            clientCA = "/etc/ssl/clients-ca.pem";
            writers = [ "CN=hydra" ];
          };
          services.kiss-cache = {
            enable = true;
            cacheDir = "/var/lib/nix-cache";
            schedule = "daily";
          };
        }
      ];
    };
  };
}
```

Reading clients configure the substituter with Nix's `tls-certificate`
and `tls-private-key` store parameters:

```ini
substituters = https://cache.example.org?tls-certificate=/etc/ssl/reader.pem&tls-private-key=/etc/ssl/reader.key
```

Writers push and register a gcroot for the closure they pushed:

```console
$ store='https://cache.example.org?tls-certificate=writer.pem&tls-private-key=writer.key'
$ nix copy --to "$store" /nix/store/abc...-hello
$ curl --cert writer.pem --key writer.key -X PUT --data-binary @/dev/null \
    "https://cache.example.org/gcroots/$(basename /nix/store/abc...-hello)"
```

Without the marker, the pushed closure is deleted on the next prune
unless it is reachable from one of the cache server's local GC roots.
