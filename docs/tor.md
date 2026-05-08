# Tor hidden services

Serve the cache as Tor v3 onions instead of (or alongside) the
clearnet mTLS vhost. Two onions split read and write access: each
onion's descriptor is encrypted so only clients holding an authorized
key can resolve the address. The .onion transport is end-to-end
encrypted, so nginx serves plain HTTP on Unix sockets that only Tor
can reach.

Each client holds an x25519 keypair: the **public** key goes in the
server's `readClients`/`writeClients`, the **private** key stays on
the client for Tor to decrypt the descriptor with. Generate one per
client:

```console
$ openssl genpkey -algorithm x25519 -out reader1.pem
$ openssl pkey -in reader1.pem -pubout -outform DER | tail -c32 | base32 | tr -d =
F2OBO...   # reader1's public key
$ openssl pkey -in reader1.pem -outform DER | tail -c32 | base32 | tr -d =
MG6XS...   # reader1's private key
```

Cache server: list every client's public key under the onion(s) it
may reach. A writer needs both, since a writer also reads:

```nix
services.kiss-cache-serve-tor = {
  enable = true;
  cacheDir = "/var/lib/nix-cache";
  # reader1 and writer1 may read.
  readClients = [
    "descriptor:x25519:F2OBO..."  # reader1
    "descriptor:x25519:K7AHQ..."  # writer1
  ];
  # Only writer1 may write.
  writeClients = [ "descriptor:x25519:K7AHQ..." ];
};
```

The onion addresses appear in
`/var/lib/tor/onion/kiss-cache-{read,write}/hostname` after the first
start.

Reader (target machine), paired with `kiss-cache-update`:

```nix
services.kiss-cache-update.enable = true;
services.kiss-cache-update-tor = {
  enable = true;
  onion = "<contents of kiss-cache-read/hostname>";
  # File containing reader1's *private* key:
  #   descriptor:x25519:MG6XS...
  clientAuthFile = "/run/keys/onion-auth";
};
```

Builder, paired with `kiss-cache-publish`:

```nix
services.kiss-cache-publish = {
  enable = true;
  systems = [ ... ];
};
services.kiss-cache-publish-tor = {
  enable = true;
  onion = "<contents of kiss-cache-write/hostname>";
  # File containing this writer's *private* key.
  clientAuthFile = "/run/keys/onion-auth";
};
```

For manual `nix copy` and `curl` over Tor, set
`ALL_PROXY=socks5h://127.0.0.1:9050` after configuring
`services.tor.client.onionServices.<write-onion>.clientAuthorizations`.

