# kiss-cache

A self-hosted Nix binary cache: nginx serves a flat directory of
`*.narinfo` and `nar/*` files behind mutual TLS, builders push with
`nix copy --to https://...`, and a systemd timer prunes everything not
reachable from a GC root. No database, no daemon, no cache server
process to keep alive.

[cache-shootout](https://github.com/Mic92/cache-shootout) found this
layout to be the fastest of the binary cache options it benchmarked. It
is also the simplest: a Nix binary cache is an immutable,
content-addressed key-value store, which is exactly what a static file
server is good at. kiss-cache supplies the two things nginx alone is
missing: pruning and per-client write access.

The pruner can also be used standalone against any binary cache
directory. It deletes by reachability from GC roots, like
`nix-collect-garbage`, rather than by age like
[lheckemann's cache-gc](https://github.com/lheckemann/cache-gc).

A fork of [Astro's nix-cache-cut](https://github.com/astro/nix-cache-cut),
which introduced the GC-root-based approach. Adds a persistent metadata
cache, parallel scanning, NixOS modules for serving over mTLS, and
HTTP-pushable GC roots.

## How it works

The pruner reads marker files under one or more roots directories;
each line naming a `/nix/store/...` path is a GC root. It walks the
transitive closure through `References:` and `Deriver:` fields in the
`.narinfo` files, and deletes everything in the cache not reachable
from a root. Roots are registered by writers — CI pushes a closure
and `PUT`s a marker file — or by hand. See
[docs/pruner.md](docs/pruner.md) for the full algorithm.

## Documentation

- [Pruner](docs/pruner.md) — what gets deleted, what gets kept, how
  the pruner coordinates with concurrent uploads, and how to run
  `kiss-cache` standalone.
- [NixOS modules](docs/nixos-modules.md) — pruner timer, nginx + mTLS
  serving, signing, importing without flakes.
- [Mutual TLS setup](docs/mtls.md) — CA, server and client
  certificates, rotation.
- [Pull-based system updates](docs/deployment.md) — use a gcroot
  marker as a deployment channel and `kiss-cache-update` to switch.
- [Tor hidden services](docs/tor.md) — serve the cache as Tor v3
  onions with client authorization as the access control.
- [OIDC bearer tokens](docs/oidc.md) — authenticate CI workflows
  (GitHub Actions, etc.) without distributing client certificates.

## Quick start (NixOS)

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
            writers = [ "CN=builder-01" ];
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

See [docs/mtls.md](docs/mtls.md) for generating the certificates and
[docs/nixos-modules.md](docs/nixos-modules.md) for the full option
reference.
