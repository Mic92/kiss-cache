use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

use rustc_hash::FxHashSet;
use std::ffi::OsStr;

/// How often to rebuild progress-bar message strings. Indicatif redraws at
/// most ~15 times a second; formatting more often than that is wasted work.
const MSG_INTERVAL: u64 = 256;

/// `<hash>.narinfo` as an `OsString`, built without `format!`.
fn narinfo_name(hash: StoreHash) -> OsString {
    let mut s = OsString::with_capacity(32 + 8);
    s.push(hash.as_str());
    s.push(".narinfo");
    s
}

use indicatif::{HumanBytes, ProgressBar};

use crate::{binary_cache, closure_cache, dep_scan, gcroots, store_hash::StoreHash};

/// Inputs to a pruning run.
pub struct Config {
    pub dry_run: bool,
    pub cache_dir: PathBuf,
    pub gcroots: Vec<PathBuf>,
}

/// Progress reporters for each phase. Pass [`Progress::hidden`] for headless
/// runs (tests, benchmarks).
pub struct Progress {
    pub gcroots: ProgressBar,
    pub scanner: ProgressBar,
    pub keep: ProgressBar,
    pub rm_narinfo: ProgressBar,
    pub rm_nar: ProgressBar,
}

impl Progress {
    #[must_use]
    pub fn hidden() -> Self {
        Progress {
            gcroots: ProgressBar::hidden(),
            scanner: ProgressBar::hidden(),
            keep: ProgressBar::hidden(),
            rm_narinfo: ProgressBar::hidden(),
            rm_nar: ProgressBar::hidden(),
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

    let (mut file_size, mut nar_size) = (0u64, 0u64);
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
        progress.keep.inc(1);
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
        nar_size += info.nar_size;
        keep_infos.insert(narinfo_name(hash));
        // Rebuilding the message string per item is more expensive than the
        // bookkeeping it reports on. Only re-format when the bar will
        // actually redraw.
        if progress.keep.position().is_multiple_of(MSG_INTERVAL) {
            progress.keep.set_message(format!(
                "{} in {} archive files",
                HumanBytes(nar_size),
                HumanBytes(file_size)
            ));
        }
    }
    progress.keep.finish_with_message(format!(
        "{} in {} archive files",
        HumanBytes(nar_size),
        HumanBytes(file_size)
    ));

    let rm_narinfo_size = sweep(&cache_path, &progress.rm_narinfo, config.dry_run, |name| {
        name.as_encoded_bytes().ends_with(b".narinfo") && !keep_infos.contains(name)
    });
    drop(keep_infos);
    progress
        .rm_narinfo
        .finish_with_message(format!("{}", HumanBytes(rm_narinfo_size)));

    let rm_nar_size = sweep(
        &cache_path.join("nar"),
        &progress.rm_nar,
        config.dry_run,
        |name| !keep_archives.contains(name),
    );
    drop(keep_archives);
    progress
        .rm_nar
        .finish_with_message(format!("{}", HumanBytes(rm_nar_size)));
}

/// Walk `dir` (one level deep) and delete every entry for which
/// `should_delete` returns true given its file name. Returns total size of
/// matched files. Honors `dry_run`.
///
/// Uses `read_dir` directly rather than walkdir: the predicate only needs the
/// basename, and walkdir materializes a full `PathBuf` for every entry it
/// yields, which is most of its cost on a cache directory with millions of
/// files. The full path is only built for the handful of entries we actually
/// delete.
fn sweep(
    dir: &Path,
    progress: &ProgressBar,
    dry_run: bool,
    should_delete: impl Fn(&OsStr) -> bool,
) -> u64 {
    let mut total = 0;
    progress.set_length(0);
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            eprintln!("Cannot read directory {}: {e}", dir.display());
            return 0;
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
            if progress.position().is_multiple_of(MSG_INTERVAL) {
                progress.set_message(format!("{}", HumanBytes(total)));
            }
        } else {
            eprintln!("Cannot stat {}", path.display());
        }

        if !dry_run && let Err(e) = fs::remove_file(&path) {
            eprintln!("Cannot remove {}: {}", path.display(), e);
        }

        progress.inc(1);
    }
    total
}
