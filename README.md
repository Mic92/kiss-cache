# kiss-cache

A self-hosted Nix binary cache: nginx serves a flat directory of
`*.narinfo` and `nar/*` files behind mutual TLS, builders push with
`nix copy --to https://...`, and a systemd timer prunes everything not
reachable from a GC root. No database, no daemon, no cache server
process to keep alive.

## Quick start

Server:

```nix
imports = [ kiss-cache.nixosModules.default ];
services.kiss-cache = {
  enable = true;                # pruner timer
  cacheDir = "/var/lib/nix-cache";
  serve = {
    enable = true;              # nginx + mTLS
    cacheDir = "/var/lib/nix-cache";
    hostName = "cache.example.org";
    sslCertificate = "/run/keys/cache.pem";
    sslCertificateKey = "/run/keys/cache.key";
    clientCA = "/run/keys/ca.pem";
    writers = [ "CN=builder-01" ];
  };
};
```

Builder:

```console
$ nix run github:Mic92/kiss-cache -- with-lock \
    https://cache.example.org/gcroots/web1 "$system" \
    --cacert ca.pem --cert builder-01.pem --key builder-01.key -- \
    nix copy --to "$store" "$system"
```

**[Full walkthrough →](docs/quickstart.md)** — generating certs and
signing keys, the flake skeleton, pushing, configuring readers.

## Why

[cache-shootout](https://github.com/Mic92/cache-shootout) found this
layout to be the fastest of the binary cache options it benchmarked. It
is also the simplest: a Nix binary cache is an immutable,
content-addressed key-value store, which is exactly what a static file
server is good at. kiss-cache supplies the two things nginx alone is
missing: pruning and per-client write access.

The pruner reads marker files under one or more `gcroots/`
directories; each line naming a `/nix/store/...` path is a GC root.
It walks the transitive closure through `References:` in the
`.narinfo` files and deletes everything not reachable from a root.
Roots are registered by writers: CI pushes a closure and `PUT`s a
marker. Like `nix-collect-garbage` but for a binary cache.

A fork of [Astro's nix-cache-cut](https://github.com/astro/nix-cache-cut),
which introduced the GC-root-based approach. Adds a persistent metadata
cache, parallel scanning, NixOS modules for serving over mTLS, and
HTTP-pushable GC roots.

## Documentation

**Getting started**
- [Quick start](docs/quickstart.md) — generate certs, deploy, push,
  read.
- [NixOS option reference](docs/nixos-modules.md) — every module and
  option, including signing and importing without flakes.

**Authentication** — pick one per cache, or run several vhosts:
- [Mutual TLS](docs/mtls.md) — the default. CA, server and client
  certificates, rotation. Best for a known fleet of machines.
- [OIDC bearer tokens](docs/oidc.md) — for CI workflows (GitHub
  Actions etc.) that already mint short-lived identity tokens. No
  certs to distribute.
- [Tor hidden services](docs/tor.md) — onion client authorization as
  the access control. For caches that must not be publicly routable.

**Operations**
- [Pruner](docs/pruner.md) — the GC algorithm, what gets kept, how
  the pruner coordinates with concurrent uploads, standalone use.
- [Pull-based system updates](docs/deployment.md) — use a gcroot
  marker as a deployment channel, push with `kiss-cache-publish`,
  switch with `kiss-cache-update`.
