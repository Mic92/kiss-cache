# NixOS modules

The flake ships several NixOS modules and a `default` module that wires
them together:

- `services.kiss-cache` runs the pruner on a systemd timer.
- `services.kiss-cache.serve` serves the cache over HTTPS with mutual
  TLS via nginx, with optional WebDAV `PUT` for trusted writers.
- `services.kiss-cache.update` polls a gcroot marker and switches the
  system to the closure it names; see [deployment.md](deployment.md).
- `services.kiss-cache.publish` rebuilds NixOS systems on a timer and
  pushes them to the cache; see [deployment.md](deployment.md).
- `services.kiss-cache.serve-tor`, `services.kiss-cache.update-tor`
  and `services.kiss-cache.publish-tor` route everything over Tor;
  see [tor.md](tor.md).
- `services.kiss-cache.serve-oidc` authenticates clients with OIDC
  bearer tokens instead of mTLS; see [oidc.md](oidc.md).

See the [README quick start](../README.md#quick-start-nixos) for the
flake skeleton.

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
$ nix run github:Mic92/kiss-cache -- with-lock \
    https://cache.example.org/gcroots/my-job /nix/store/abc...-hello \
    --cert writer.pem --key writer.key --cacert ca.pem -- \
    nix copy --to "$store" /nix/store/abc...-hello
```

Without the marker, the pushed closure is deleted on the next prune.
The wrapper takes a cooperative lock against the pruner before
pushing; see [pruner.md](pruner.md#concurrent-writes).

Set `gcRootMaxAge` to expire stale markers automatically. Writers must
re-`PUT` on each push to keep their closures alive:

```nix
services.kiss-cache.serve.gcRootMaxAge = "30d";
```

Set `fallbackCache` to chain through to an upstream cache: a local
miss is fetched from there and stored, so the next request for the
same path is a local hit.

```nix
services.kiss-cache.serve.fallbackCache = "https://cache.nixos.org";
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

  services.kiss-cache.serve = { ... };
  services.kiss-cache = { ... };
  services.kiss-cache.update = { ... };
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

Clients add the public key to `trusted-public-keys` (see
[mtls.md](mtls.md#client-configuration)). Nix refuses to substitute a path whose
signature does not match a trusted key.

If you set `fallbackCache`, clients also need the upstream's public
key, e.g. `cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=`.

