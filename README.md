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

## Usage

```console
$ nix run github:Mic92/kiss-cache -- --help
Trim Nix binary caches according to GC roots

Usage: kiss-cache [-n|--dry-run] <CACHEDIR> <GCROOTS>...

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Directories of marker files naming store paths to keep

Options:
  -n, --dry-run  Do not actually delete files
  -h, --help     Print help
  -V, --version  Print version
```

## How it works

1. Read every plain file under each `GCROOTS` directory (recursively).
   Each line that parses as a `/nix/store/<hash>-<name>` path is a root.
   Symlinks are not followed.
2. For each root, parse `<CACHEDIR>/<hash>.narinfo` and recurse into its
   `References:` and `Deriver:` fields. The transitive closure is the set
   of reachable hashes.
3. Delete every `*.narinfo`, `*.ls` and `nar/*` file in `CACHEDIR` not
   reachable from any root.

Marker files can have any name (e.g. a CI job ID); only their content
matters. Lines that do not parse as a store path are ignored, so
unrelated files in a roots directory are harmless.

A persistent metadata cache at `<CACHEDIR>/.kiss-cache.closures` skips
re-parsing unchanged `.narinfo` files on repeated runs. It is safe to
delete.

Not pruned: `log/` (build logs, keyed by `.drv` name), `realisations/`
(content-addressed derivation outputs) and `debuginfo/` (separated
debug symbols). Their keys do not map back to a store hash without
extra parsing, so they accumulate. If you write them, clean them out of
band or open an issue.

## NixOS modules

The flake ships two NixOS modules and a `default` module that wires them
together:

- `services.kiss-cache` runs the pruner on a systemd timer.
- `services.kiss-cache-serve` serves the cache over HTTPS with mutual
  TLS via nginx, with optional WebDAV `PUT` for trusted writers.

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

Reading clients configure the substituter with Nix's `tls-certificate`
and `tls-private-key` store parameters:

```ini
substituters = https://cache.example.org?tls-certificate=/etc/ssl/reader.pem&tls-private-key=/etc/ssl/reader.key
```

Writers push and register a gcroot for the closure they pushed. Use
`compression=zstd`: it decompresses an order of magnitude faster than
the default xz, which is the bottleneck when substituting from a fast
local cache, and compresses nearly as well.

```console
$ store='https://cache.example.org?compression=zstd&secret-key=/etc/nix/cache-key&tls-certificate=writer.pem&tls-private-key=writer.key'
$ nix copy --to "$store" /nix/store/abc...-hello
$ echo /nix/store/abc...-hello | curl --cert writer.pem --key writer.key \
    -X PUT --data-binary @- "https://cache.example.org/gcroots/my-job"
```

Without the marker, the pushed closure is deleted on the next prune.

Set `gcRootMaxAge` to expire stale markers automatically. Writers must
re-`PUT` on each push to keep their closures alive:

```nix
services.kiss-cache-serve.gcRootMaxAge = "30d";
```

Set `fallbackCache` to chain through to an upstream cache: a local
miss is fetched from there and stored, so the next request for the
same path is a local hit.

```nix
services.kiss-cache-serve.fallbackCache = "https://cache.nixos.org";
```

Clients receive the upstream's signature unmodified; add its public
key to `trusted-public-keys` alongside this cache's own. Stored
entries are not registered as gcroots and are reclaimed by the next
prune unless reachable; they are refetched on demand.

## Without flakes

The package is a plain `callPackage`-able derivation and the modules
resolve their default package the same way:

```nix
# configuration.nix
let
  kiss-cache = builtins.fetchTarball
    "https://github.com/Mic92/kiss-cache/archive/main.tar.gz";
in
{
  imports = [ "${kiss-cache}/nixos" ];

  services.kiss-cache-serve = { ... };
  services.kiss-cache = { ... };
}
```

Or just the package:

```nix
environment.systemPackages = [
  (pkgs.callPackage "${kiss-cache}/package.nix" { })
];
```

Pin a specific revision with `fetchFromGitHub` + a hash in production.

## Signing

mTLS only proves a path came from the cache server. Nix store
signatures prove the path was *built* by someone whose key the client
trusts, which protects against a compromised cache server serving
tampered paths. They are independent layers; use both.

Generate a key pair:

```console
$ nix key generate-secret --key-name cache.example.org-1 > cache-key
$ nix key convert-secret-to-public < cache-key > cache-key.pub
$ cat cache-key.pub
cache.example.org-1:zR8...=
```

Deploy the secret key to every writer (e.g. via sops-nix). The
`secret-key` store parameter signs paths as they are pushed:

```
nix copy --to 'https://cache.example.org?secret-key=/etc/nix/cache-key&...' ...
```

Clients add the public key to `trusted-public-keys` (see the client
config in the next section). Nix refuses to substitute a path whose
signature does not match a trusted key.

If you set `fallbackCache`, clients also need the upstream's public
key, e.g. `cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`.

## Setting up mutual TLS

Both sides authenticate with a certificate: the server proves who it is
as in ordinary HTTPS, the client proves who it is by presenting a
certificate signed by a CA the server trusts. Possession of a private
key is the credential.

You need a private CA, a server certificate, and a client certificate
per host.

### CA

```console
$ openssl req -x509 -newkey ed25519 -nodes -days 3650 \
    -subj "/CN=My Nix Cache CA" \
    -keyout ca.key -out ca.pem
```

Deploy `ca.pem` (the public half) to the cache server as `clientCA`.
Keep `ca.key` offline; it only needs to exist where you sign new
certificates.

### Server certificate

This is what reading clients verify against, so it needs a Subject
Alternative Name matching the hostname they connect to. Use ACME / Let's
Encrypt if your clients are outside your control, or sign one with your
private CA and distribute `ca.pem` as the clients' trust root:

```console
$ openssl req -newkey ed25519 -nodes \
    -subj "/CN=cache.example.org" \
    -addext "subjectAltName=DNS:cache.example.org" \
    -keyout server.key -out server.csr
$ openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key \
    -days 365 -copy_extensions copy -out server.pem
```

Deploy `server.pem` / `server.key` as `sslCertificate` /
`sslCertificateKey`.

### Client certificates

One per host (or per role). The Common Name is what the server matches
against `writers`:

```console
$ openssl req -newkey ed25519 -nodes \
    -subj "/CN=builder-01" \
    -keyout builder-01.key -out builder-01.csr
$ openssl x509 -req -in builder-01.csr -CA ca.pem -CAkey ca.key \
    -days 365 -out builder-01.pem
```

Any certificate signed by the CA can read. Only those listed in
`writers` can push:

```nix
services.kiss-cache-serve.writers = [ "CN=builder-01" ];
```

### Client configuration

```nix
nix.settings = {
  substituters = [
    "https://cache.example.org?tls-certificate=/run/secrets/cache-client.pem&tls-private-key=/run/secrets/cache-client.key"
  ];
  trusted-public-keys = [ "cache.example.org-1:zR8...=" ];
  # Only needed if the server cert is signed by your private CA.
  ssl-cert-file = "/run/secrets/cache-ca.pem";
};
```

Deploy the private key with sops-nix or agenix; don't commit it.

### Rotation

Issue short-lived client certificates (`-days 90`) and reissue on a
timer. nginx checks expiry on every handshake, so an expired cert is
rejected with no extra infrastructure. To revoke a still-valid
certificate, rotate the CA and reissue everything, or set up a CRL via
`services.nginx.virtualHosts.<host>.extraConfig`:
`ssl_crl /path/to/crl.pem`.
