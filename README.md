# kiss-cache

Yet another garbage collector for Nix binary caches.

This one runs with a list of GC roots just like your ordinary
`nix-collect-garbage`. It does not operate time-based to expire old
files like [lheckemann's
cache-gc](https://github.com/lheckemann/cache-gc).

A fork of [Astro's nix-cache-cut](https://github.com/astro/nix-cache-cut),
which introduced the GC-root-based approach. This fork adds a
persistent metadata cache, parallel scanning, NixOS modules for
serving over mTLS, and HTTP-pushable GC roots.

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

Writers push and register a gcroot for the closure they pushed.
Use `compression=zstd`: it decompresses an order of magnitude faster
than the default xz, which in practice is the bottleneck when
substituting from a fast local cache, and compresses well enough that
the size difference is small.

```console
$ store='https://cache.example.org?compression=zstd&tls-certificate=writer.pem&tls-private-key=writer.key'
$ nix copy --to "$store" /nix/store/abc...-hello
$ curl --cert writer.pem --key writer.key -X PUT --data-binary @/dev/null \
    "https://cache.example.org/gcroots/$(basename /nix/store/abc...-hello)"
```

Without the marker, the pushed closure is deleted on the next prune
unless it is reachable from one of the cache server's local GC roots.

## Why nginx and a flat file layout?

A Nix binary cache is an immutable, content-addressed key-value store.
The simplest thing that can possibly serve one is a static file server,
and [cache-shootout](https://github.com/Mic92/cache-shootout) found
nginx serving a flat directory to be the fastest of the options
benchmarked. kiss-cache is the missing pruning and access-control half
of that setup: nginx serves and accepts pushes, kiss-cache cleans up,
and neither needs a database, a daemon, or anything to crash.

## Setting up mutual TLS

Mutual TLS (mTLS) means both sides authenticate with a certificate: the
server proves who it is (as in ordinary HTTPS), and the client proves
who *it* is by presenting a certificate signed by a CA the server
trusts. There are no shared passwords or tokens to leak — possession of
a private key is the credential, and revocation is removing the cert
from the CA's trust (or letting it expire).

This section sets up a private CA, a server certificate, and per-host
client certificates. All commands use `openssl`.

### 1. Create the CA

The CA signs every other certificate. Its private key is the root of
trust — keep it offline or at least off the cache server.

```console
$ openssl req -x509 -newkey ed25519 -nodes -days 3650 \
    -subj "/CN=My Nix Cache CA" \
    -keyout ca.key -out ca.pem
```

Deploy `ca.pem` (the public half) to the cache server as `clientCA`.
Never deploy `ca.key` anywhere except where you sign new certificates.

### 2. Create the server certificate

The server certificate is what reading clients verify against, so it
needs a Subject Alternative Name matching the hostname they connect to.
Use a publicly trusted certificate (e.g. via ACME / Let's Encrypt) if
your clients are outside your control, or sign one with your private CA
if you also distribute `ca.pem` to clients as their trust root:

```console
$ openssl req -newkey ed25519 -nodes \
    -subj "/CN=cache.example.org" \
    -addext "subjectAltName=DNS:cache.example.org" \
    -keyout server.key -out server.csr
$ openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key \
    -days 365 -copy_extensions copy -out server.pem
```

Deploy `server.pem` and `server.key` to the cache server as
`sslCertificate` / `sslCertificateKey`.

### 3. Create client certificates

Issue one certificate per host (or per role). The Common Name is what
the server uses to decide who may write, so make it identifiable:

```console
$ openssl req -newkey ed25519 -nodes \
    -subj "/CN=builder-01" \
    -keyout builder-01.key -out builder-01.csr
$ openssl x509 -req -in builder-01.csr -CA ca.pem -CAkey ca.key \
    -days 365 -out builder-01.pem
```

Deploy `builder-01.pem` and `builder-01.key` to the builder host. Any
certificate signed by the CA can read; only those whose distinguished
name is listed in `services.kiss-cache-serve.writers` can push:

```nix
services.kiss-cache-serve.writers = [ "CN=builder-01" ];
```

### 4. Configure the client

On a NixOS machine that should fetch from the cache:

```nix
nix.settings = {
  substituters = [
    "https://cache.example.org?tls-certificate=/run/secrets/cache-client.pem&tls-private-key=/run/secrets/cache-client.key"
  ];
  trusted-public-keys = [ "cache.example.org:..." ];
  # Only needed if the server cert is signed by your private CA.
  ssl-cert-file = "/run/secrets/cache-ca.pem";
};
```

Use a secrets manager (sops-nix, agenix) to deploy the private key with
`0600` permissions; do not commit it to your configuration repo.

### Rotation and revocation

Issue short-lived client certificates (`-days 90`) and reissue on a
timer. nginx checks expiry on every handshake, so an expired cert is
immediately rejected with no extra infrastructure. If you need to
revoke a still-valid certificate, replace `ca.pem` with a new CA and
reissue every client certificate, or add CRL support via
`services.nginx.virtualHosts.<host>.extraConfig` with
`ssl_crl /path/to/crl.pem`.
