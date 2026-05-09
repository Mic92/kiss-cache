# OIDC bearer-token authentication

`services.kiss-cache.serve-oidc` lets CI systems that issue short-lived OIDC
tokens — most commonly GitHub Actions — push to the cache without
holding a long-lived client certificate. nginx validates the JWT
against the issuer's JWKS in an embedded njs module before letting the
request through.

`Authorization` is a header, so this is mutually exclusive with mTLS;
use one or the other per virtual host.

## Cache server

```nix
services.kiss-cache.serve-oidc = {
  enable = true;
  cacheDir = "/var/lib/nix-cache";
  hostName = "cache.example.org";
  sslCertificate = "/etc/ssl/cache.pem";
  sslCertificateKey = "/etc/ssl/cache.key";
  audience = "https://cache.example.org";
  readSubjects = [ "repo:example/*" ];
  writeSubjects = [ "repo:example/infra:ref:refs/heads/main" ];
};
```

GitHub Actions subjects encode the repository and trigger:

- `repo:owner/name:ref:refs/heads/main` — pushes to `main`.
- `repo:owner/name:environment:production` — deployments to an
  environment.
- `repo:owner/name:pull_request` — PR builds.

`*` matches any segment, so `repo:example/*` allows every repository
in the `example` org.

## Workflow side

```yaml
permissions:
  id-token: write   # needed to mint OIDC tokens

jobs:
  push:
    runs-on: ubuntu-latest
    steps:
      - id: token
        uses: actions/github-script@v7
        with:
          script: |
            const t = await core.getIDToken("https://cache.example.org");
            core.setSecret(t);
            core.setOutput("token", t);
      - run: |
          # Build first so the upload starts with a fresh token.
          system=$(nix build --no-link --print-out-paths .#...toplevel)
          nix run github:Mic92/kiss-cache -- with-lock \
            --bearer "${{ steps.token.outputs.token }}" \
            https://cache.example.org/gcroots/web1 "$system" -- \
            nix copy --to "https://cache.example.org" "$system" \
              --option access-tokens "cache.example.org=${{ steps.token.outputs.token }}"
```

The wrapper takes a cooperative lock against the pruner before
pushing; see [pruner.md](pruner.md#concurrent-writes). `--bearer`
adds the `Authorization` header to the lock and marker requests and
exports the token to the wrapped command as `$KISS_CACHE_TOKEN`.

> **Token lifetime.** GitHub Actions ID tokens expire 5 minutes
> after they are minted, and neither nix nor kiss-cache can refresh
> a token mid-`nix copy`. Keep the publish small (push the system
> closure, not your whole CI store), and build first so the token
> is only minted right before the upload. If you regularly exceed
> 5 minutes, use the mTLS vhost instead — client certificates do
> not expire on a request timescale.

Set `audience` to the cache's URL so a token minted for one service
cannot be replayed against another.

## Limitations

- The njs module supports RS256/RS384/RS512 (GitHub's algorithms). ES
  curves are not implemented because njs's WebCrypto cannot import a
  raw ECDSA signature as of njs 0.9.
- nginx must be able to resolve and reach the JWKS URL. The
  `resolvers` option defaults to `networking.nameservers` (or
  systemd-resolved's stub) and must be set explicitly when neither is
  available.
- Tokens are validated per request; high request volume costs an
  RSA verify each time. For substituter workloads (many small narinfo
  fetches) consider issuing a longer-lived cookie/cert instead.
