# Pruner

`kiss-cache` deletes binary cache entries not reachable from any GC
root. The NixOS `services.kiss-cache` module wraps it in a systemd
timer; the binary also runs standalone against any
`*.narinfo` + `nar/` directory.

## Algorithm

1. Read every plain file under each `GCROOTS` directory (recursively).
   Each line that parses as a `/nix/store/<hash>-<name>` path is a root.
   Symlinks are not followed; dotfiles (e.g. `.lock/`) are skipped.
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

## Concurrent writes

A prune that races a `nix copy` into the same cache can delete a
shared dependency between the writer's `queryValidPaths` snapshot
(which says the dependency is present) and its marker landing (which
would have rooted it). The result is a narinfo whose `References:`
points at a deleted entry — clients fail to substitute.

Writers and the pruner therefore coordinate through a lock directory
at `<GCROOTS>/.lock/`, restic-style:

- A writer PUTs `<GCROOTS>/.lock/<id>` (any content) before its first
  upload, refreshes it every 5 minutes, and DELETEs it after the
  marker lands.
- The pruner waits until no fresh lock remains, creates its own lock,
  re-reads the directory (to catch a writer that raced in), and only
  then sweeps.
- A lock older than 30 minutes is ignored: it belongs to a crashed
  holder. Refreshing keeps a long upload's lock fresh.

The pruner gives up after `--lock-wait` seconds (default 600) if
locks do not drain; the systemd timer retries on its next trigger.

CI scripts that publish without `services.kiss-cache-publish` must
follow the same protocol. A writer that skips it cannot corrupt
anything else, but its own pushed closures may end up with dangling
references if a prune races the upload.

Use `kiss-cache with-lock`, which handles the protocol's fiddly
parts (failing safe if the lock cannot be taken, the refresh loop,
request timeouts):

```sh
nix run github:Mic92/kiss-cache -- with-lock \
  https://cache.example.org/gcroots/web1 "$system" \
  --cert writer.pem --key writer.key --cacert ca.pem -- \
  nix copy --to "$store" "$system"
```

See `kiss-cache with-lock --help` for the protocol it implements if
you need to do it by hand (e.g. without curl). The protocol is
bounded model checked in [`spec/prune.als`](../spec/prune.als).

## Standalone

Pass `-n` to dry-run first.

```console
$ mkdir roots && echo /nix/store/abc...-hello > roots/keep
$ nix run github:Mic92/kiss-cache -- prune -n /var/cache/nix roots
```

```
Usage: kiss-cache prune [-n|--dry-run] [--lock-wait <SECS>] <CACHEDIR> <GCROOTS>...

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Directories of marker files naming store paths to keep

Options:
  -n, --dry-run         Do not actually delete files
      --lock-wait SECS  How long to wait for in-flight uploads [default: 600]
  -h, --help            Print help
```
