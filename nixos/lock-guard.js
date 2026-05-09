// Reject lock PUTs while the pruner holds a fresh lock. This is the
// `not freshExclusive` precondition on the uploader's lock-create
// step in `spec/prune.als`: a writer that takes its lock while a
// prune is mid-sweep is invisible to the pruner (it already
// snapshotted), so its `nix copy` could skip a path the sweep
// deletes. Refusing the lock PUT until the prune finishes makes the
// writer's whole upload run against a post-prune cache.
//
// Server-side: a writer that talks to the cache without
// `kiss-cache-with-lock` cannot accidentally bypass the protocol.
// Lock DELETE is never refused so a writer can always release.
//
// Wired as a `js_set` variable so the check runs during the rewrite
// phase, before nginx's DAV content handler.

import fs from "fs";

// Locks older than this are stale and ignored. Mirrors
// kiss_cache::lock::STALE_AFTER.
const STALE_MS = 30 * 60 * 1000;

function pruneLockHeld(r) {
  if (r.method !== "PUT") return "";
  let names;
  try {
    names = fs.readdirSync(r.variables.kiss_cache_lock_dir);
  } catch (e) {
    // Missing lock directory means no locks.
    return "";
  }
  const now = Date.now();
  for (let i = 0; i < names.length; i++) {
    const name = names[i];
    if (!name.startsWith("prune-")) continue;
    let st;
    try {
      st = fs.statSync(r.variables.kiss_cache_lock_dir + "/" + name);
    } catch (e) {
      continue;
    }
    if (now - st.mtimeMs < STALE_MS) return "1";
  }
  return "";
}

export default { pruneLockHeld };
