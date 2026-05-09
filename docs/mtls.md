# Setting up mutual TLS

Both sides authenticate with a certificate: the server proves who it is
as in ordinary HTTPS, the client proves who it is by presenting a
certificate signed by a CA the server trusts. Possession of a private
key is the credential.

You need a private CA, a server certificate, and a client certificate
per host.

## CA

```console
$ openssl req -x509 -newkey ed25519 -nodes -days 3650 \
    -subj "/CN=My Nix Cache CA" \
    -keyout ca.key -out ca.pem
```

Deploy `ca.pem` (the public half) to the cache server as `clientCA`.
Keep `ca.key` offline; it only needs to exist where you sign new
certificates.

## Server certificate

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

## Client certificates

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
services.kiss-cache.serve.writers = [ "CN=builder-01" ];
```

## Client configuration

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

## Rotation

Issue short-lived client certificates (`-days 90`) and reissue on a
timer. nginx checks expiry on every handshake, so an expired cert is
rejected with no extra infrastructure. To revoke a still-valid
certificate, rotate the CA and reissue everything, or set up a CRL via
`services.nginx.virtualHosts.<host>.extraConfig`:
`ssl_crl /path/to/crl.pem`.
