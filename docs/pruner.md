# Pruner

`kiss-cache` deletes binary cache entries not reachable from any GC
root. The NixOS `services.kiss-cache` module wraps it in a systemd
timer; the binary also runs standalone against any
`*.narinfo` + `nar/` directory.

## Algorithm

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

## Standalone

Pass `-n` to dry-run first.

```console
$ mkdir roots && echo /nix/store/abc...-hello > roots/keep
$ nix run github:Mic92/kiss-cache -- -n /var/cache/nix roots
```

```
Usage: kiss-cache [-n|--dry-run] <CACHEDIR> <GCROOTS>...

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Directories of marker files naming store paths to keep

Options:
  -n, --dry-run  Do not actually delete files
  -h, --help     Print help
  -V, --version  Print version
```
