use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

use rustc_hash::FxHashSet;
use std::ffi::OsStr;

/// `<hash>.ls` as an `OsString`, built without `format!`.
fn listing_name(hash: StoreHash) -> OsString {
    let mut s = OsString::with_capacity(35);
    s.push(hash.as_str());
    s.push(".ls");
    s
}

/// `<hash>.narinfo` as an `OsString`, built without `format!`.
fn narinfo_name(hash: StoreHash) -> OsString {
    let mut s = OsString::with_capacity(32 + 8);
    s.push(hash.as_str());
    s.push(".narinfo");
    s
}

use crate::{
    binary_cache, closure_cache, dep_scan, gcroots, progress::Phase, store_hash::StoreHash,
};

/// Inputs to a pruning run.
pub struct Config {
    pub dry_run: bool,
    pub cache_dir: PathBuf,
    pub gcroots: Vec<PathBuf>,
}

/// Progress reporters for each phase. Pass [`Progress::hidden`] for headless
/// runs (tests, benchmarks).
pub struct Progress {
    pub gcroots: Phase,
    pub scanner: Phase,
    pub keep: Phase,
    pub rm_narinfo: Phase,
    pub rm_nar: Phase,
}

impl Progress {
    #[must_use]
    pub fn new(dry_run: bool) -> Self {
        Progress {
            gcroots: Phase::new("Scanning GC roots"),
            scanner: Phase::new("Scanning dependencies"),
            keep: Phase::new("Retaining archives"),
            rm_narinfo: Phase::new(if dry_run {
                "[dry-run] Deleting .narinfo files"
            } else {
                "Deleting .narinfo files"
            }),
            rm_nar: Phase::new(if dry_run {
                "[dry-run] Deleting .nar files"
            } else {
                "Deleting .nar files"
            }),
        }
    }

    #[must_use]
    pub fn hidden() -> Self {
        Progress {
            gcroots: Phase::hidden(),
            scanner: Phase::hidden(),
            keep: Phase::hidden(),
            rm_narinfo: Phase::hidden(),
            rm_nar: Phase::hidden(),
        }
    }
}

/// Run a full prune: scan GC roots, walk the closure, delete unreachable
/// narinfo and nar files. Honors `config.dry_run`.
pub fn run(config: &Config, progress: &Progress) {
    let mut gcroots = gcroots::GcRoots::new();
    for gcroot in &config.gcroots {
        gcroots.enqueue(gcroot);
    }
    let store_hashes = gcroots.scan(&progress.gcroots);
    progress.gcroots.finish();

    let cache = binary_cache::BinaryCache::new(&config.cache_dir);
    let closure_cache_path = closure_cache::default_path(&config.cache_dir);
    let closures = closure_cache::load(&closure_cache_path);
    let mut scanner = dep_scan::DependencyScanner::new();
    for hash in store_hashes {
        scanner.enqueue(hash);
    }
    let infos = scanner.scan(&cache, &closures, &progress.scanner);
    drop(closures);
    progress.scanner.finish();
    if !config.dry_run
        && let Err(e) = closure_cache::save(&closure_cache_path, infos.iter().map(|(h, i)| (*h, i)))
    {
        eprintln!("Cannot write closure cache: {e}");
    }

    let mut file_size = 0u64;
    progress.keep.set_length(infos.len() as u64);
    // Both sweep passes walk a single directory level and compare each
    // entry against a keep-set. Keying on the file name alone avoids
    // hashing the (identical) cache directory prefix on every membership
    // check, and avoids storing it thousands of times.
    let mut keep_infos: FxHashSet<OsString> =
        FxHashSet::with_capacity_and_hasher(infos.len(), rustc_hash::FxBuildHasher);
    let mut keep_archives: FxHashSet<OsString> =
        FxHashSet::with_capacity_and_hasher(infos.len(), rustc_hash::FxBuildHasher);
    let cache_path = cache.path.clone();
    for (hash, info) in infos {
        // A truncated or hand-edited narinfo must not abort the run, but it
        // also must not be treated as fully accounted for: keep its .narinfo
        // (it is still reachable) but warn and skip statistics/archive
        // tracking for the missing fields.
        if let Some(name) = info
            .url
            .as_deref()
            .and_then(|url| Path::new(url).file_name())
        {
            keep_archives.insert(name.to_owned());
        } else {
            eprintln!("Malformed narinfo (missing URL): {hash}.narinfo");
        }
        file_size += info.file_size;
        keep_infos.insert(narinfo_name(hash));
        // NAR listings (`<hash>.ls`, written by `nix store ls --json` and
        // some tooling) share the narinfo's key. Treat them as part of the
        // entry so they do not accumulate as orphans.
        keep_infos.insert(listing_name(hash));
        progress.keep.set_bytes(file_size);
        progress.keep.inc(1);
    }
    progress.keep.finish();

    sweep(&cache_path, &progress.rm_narinfo, config.dry_run, |name| {
        let n = name.as_encoded_bytes();
        (n.ends_with(b".narinfo") || n.ends_with(b".ls")) && !keep_infos.contains(name)
    });
    drop(keep_infos);
    progress.rm_narinfo.finish();

    sweep(
        &cache_path.join("nar"),
        &progress.rm_nar,
        config.dry_run,
        |name| !keep_archives.contains(name),
    );
    drop(keep_archives);
    progress.rm_nar.finish();
}

/// Walk `dir` (one level deep) and delete every entry for which
/// `should_delete` returns true given its file name. Honors `dry_run`.
///
/// Uses `read_dir` directly rather than walkdir: the predicate only needs the
/// basename, and walkdir materializes a full `PathBuf` for every entry it
/// yields, which is most of its cost on a cache directory with millions of
/// files. The full path is only built for the handful of entries we actually
/// delete.
fn sweep(dir: &Path, progress: &Phase, dry_run: bool, should_delete: impl Fn(&OsStr) -> bool) {
    let mut total = 0;
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            eprintln!("Cannot read directory {}: {e}", dir.display());
            return;
        }
    };
    for entry in entries {
        // An entry can become unreadable mid-scan (concurrent deletion,
        // permissions); skip rather than abort the sweep.
        let entry = match entry {
            Ok(entry) => entry,
            Err(e) => {
                eprintln!("Cannot read cache entry: {e}");
                continue;
            }
        };
        if !should_delete(&entry.file_name()) {
            continue;
        }
        let path = entry.path();
        progress.inc_length(1);

        if let Ok(meta) = entry.metadata() {
            total += meta.len();
            progress.set_bytes(total);
        } else {
            eprintln!("Cannot stat {}", path.display());
        }

        if !dry_run && let Err(e) = fs::remove_file(&path) {
            eprintln!("Cannot remove {}: {}", path.display(), e);
        }

        progress.inc(1);
    }
}
