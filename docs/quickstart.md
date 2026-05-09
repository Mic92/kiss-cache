# Quick start

This walks through standing up a cache, pushing to it, and reading
from it. It uses mutual TLS, the simplest auth scheme to set up
end-to-end. Swap in [Tor](tor.md) or [OIDC](oidc.md) later if your
clients can't hold a client cert.

## 1. Generate certificates

A private CA signs one server cert and one client cert per host:

```console
$ openssl req -x509 -newkey ed25519 -nodes -days 3650 \
    -subj "/CN=My Nix Cache CA" -keyout ca.key -out ca.pem
$ for host in cache builder-01 web1; do
    openssl req -newkey ed25519 -nodes -subj "/CN=$host" \
      -keyout $host.key -out $host.csr
    openssl x509 -req -in $host.csr -CA ca.pem -CAkey ca.key \
      -days 365 -copy_extensions copy -out $host.pem
  done
```

The server cert (`cache.pem`) needs a `subjectAltName` matching its
hostname; see [mtls.md](mtls.md#server-certificate). Client certs
(`builder-01.pem`, `web1.pem`) only need a CN.

## 2. Generate a signing key

mTLS proves a path came from the cache server. A Nix store signature
proves it was *built* by a key the reader trusts, protecting against
a compromised server serving tampered paths. Generate one key per
cache:

```console
$ nix key generate-secret --key-name cache.example.org-1 > cache-key
$ nix key convert-secret-to-public < cache-key > cache-key.pub
```

Deploy `cache-key` to every writer; readers get the public key.

## 3. Deploy the cache

```nix
{
  inputs.kiss-cache.url = "github:Mic92/kiss-cache";

  outputs = { self, nixpkgs, kiss-cache }: {
    nixosConfigurations.cache = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        kiss-cache.nixosModules.default
        {
          services.kiss-cache = {
            # Pruner: keep only what a gcroot marker reaches.
            enable = true;
            cacheDir = "/var/lib/nix-cache";
            schedule = "daily";
            # nginx + mTLS front. Holders of a CA-signed client cert
            # can read; only listed CNs can write.
            serve = {
              enable = true;
              cacheDir = "/var/lib/nix-cache";
              hostName = "cache.example.org";
              sslCertificate = "/run/keys/cache.pem";
              sslCertificateKey = "/run/keys/cache.key";
              clientCA = "/run/keys/ca.pem";
              writers = [ "CN=builder-01" ];
            };
          };
        }
      ];
    };
  };
}
```

Deploy `cache.pem`, `cache.key` and `ca.pem` to the cache host via
your secrets tool of choice.

## 4. Push from a builder

```console
$ store="https://cache.example.org?tls-certificate=builder-01.pem&tls-private-key=builder-01.key&secret-key=cache-key&compression=zstd"
$ system=$(nix build --no-link --print-out-paths .#nixosConfigurations.web1.config.system.build.toplevel)
$ nix run github:Mic92/kiss-cache -- with-lock \
    https://cache.example.org/gcroots/web1 "$system" \
    --cacert ca.pem --cert builder-01.pem --key builder-01.key -- \
    nix copy --to "$store" "$system"
```

The `secret-key` store parameter signs each path as it is pushed.
`with-lock` PUTs a gcroot marker that keeps `$system` from being
pruned, and takes a cooperative lock so a concurrent prune cannot
delete a shared dependency mid-upload. See
[pruner.md](pruner.md#concurrent-writes).

To push automatically on a timer, use `services.kiss-cache.publish`;
see [deployment.md](deployment.md).

## 5. Read from a client

```nix
nix.settings = {
  substituters = [
    "https://cache.example.org?tls-certificate=/run/keys/web1.pem&tls-private-key=/run/keys/web1.key"
  ];
  trusted-public-keys = [ "cache.example.org-1:..." ];  # cache-key.pub
  ssl-cert-file = "/run/keys/ca.pem";  # trust the private CA
};
```

Nix refuses to substitute a path whose signature does not match a
trusted key. That's it: the pruner runs daily and deletes everything
not reachable from a `gcroots/*` marker.

## Next steps

- [Push and switch automatically](deployment.md) with
  `kiss-cache-publish` and `kiss-cache-update`.
- [Authenticate CI with OIDC](oidc.md) instead of distributing
  client certs to every workflow.
- [Hide the cache behind Tor](tor.md) if it must not be publicly
  routable.
