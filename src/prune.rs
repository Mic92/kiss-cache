use std::{
    collections::HashSet,
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

/// How often to rebuild progress-bar message strings. Indicatif redraws at
/// most ~15 times a second; formatting more often than that is wasted work.
const MSG_INTERVAL: u64 = 256;

use indicatif::{HumanBytes, ProgressBar};
use walkdir::WalkDir;

use crate::{binary_cache, dep_scan, gcroots};

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
    // Scan garbage-collector roots
    let mut gcroots = gcroots::GcRoots::new();
    for gcroot in &config.gcroots {
        gcroots.enqueue(gcroot);
    }
    let store_hashes = gcroots.scan(&progress.gcroots);
    progress.gcroots.finish();

    // Scan gcroots dependencies
    let mut cache = binary_cache::BinaryCache::new(&config.cache_dir);
    let mut scanner = dep_scan::DependencyScanner::new();
    for hash in store_hashes {
        scanner.enqueue(hash);
    }
    let infos = scanner.scan(&mut cache, &progress.scanner);
    progress.scanner.finish();

    // Statistics
    let (mut file_size, mut nar_size) = (0u64, 0u64);
    // Set of files to keep
    progress.keep.set_length(infos.len() as u64);
    // Both sweep passes walk a single directory level and compare each
    // entry against a keep-set. Keying on the file name alone avoids
    // hashing the (identical) cache directory prefix on every membership
    // check, and avoids storing it thousands of times.
    let mut keep_infos: HashSet<OsString> = HashSet::with_capacity(infos.len());
    let mut keep_archives: HashSet<OsString> = HashSet::with_capacity(infos.len());
    let cache_path = cache.path.clone();
    for info in infos {
        progress.keep.inc(1);
        // A truncated or hand-edited narinfo must not abort the run, but it
        // also must not be treated as fully accounted for: keep its .narinfo
        // (it is still reachable) but warn and skip statistics/archive
        // tracking for the missing fields.
        if let Some(name) = info.url().and_then(|url| Path::new(url).file_name()) {
            keep_archives.insert(name.to_owned());
        } else {
            eprintln!("Malformed narinfo (missing URL): {}", info.path.display());
        }
        file_size += info.file_size();
        nar_size += info.nar_size();
        if let Some(name) = info.path.file_name() {
            keep_infos.insert(name.to_owned());
        }
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

    let rm_narinfo_size = sweep(&cache_path, &progress.rm_narinfo, config.dry_run, |entry| {
        let path = entry.path();
        path.extension().is_some_and(|ext| ext == "narinfo")
            && !keep_infos.contains(entry.file_name())
    });
    drop(keep_infos);
    progress
        .rm_narinfo
        .finish_with_message(format!("{}", HumanBytes(rm_narinfo_size)));

    let rm_nar_size = sweep(
        &cache_path.join("nar"),
        &progress.rm_nar,
        config.dry_run,
        |entry| !keep_archives.contains(entry.file_name()),
    );
    drop(keep_archives);
    progress
        .rm_nar
        .finish_with_message(format!("{}", HumanBytes(rm_nar_size)));
}

/// Walk `dir` (depth 1) and delete every entry for which `should_delete`
/// returns true. Returns total size of matched files. Honors `dry_run`.
fn sweep(
    dir: &Path,
    progress: &ProgressBar,
    dry_run: bool,
    should_delete: impl Fn(&walkdir::DirEntry) -> bool,
) -> u64 {
    let mut total = 0;
    progress.set_length(0);
    for entry in WalkDir::new(dir).min_depth(1).max_depth(1) {
        // An entry can become unreadable mid-scan (concurrent deletion,
        // permissions); skip rather than abort the sweep.
        let entry = match entry {
            Ok(entry) => entry,
            Err(e) => {
                eprintln!("Cannot read cache entry: {e}");
                continue;
            }
        };
        if !should_delete(&entry) {
            continue;
        }
        let path = entry.path();
        progress.inc_length(1);

        // entry.metadata() reuses the stat WalkDir already did; do not
        // round-trip through the kernel a second time per file.
        if let Ok(meta) = entry.metadata() {
            total += meta.len();
            if progress.position().is_multiple_of(MSG_INTERVAL) {
                progress.set_message(format!("{}", HumanBytes(total)));
            }
        } else {
            eprintln!("Cannot stat {}", path.display());
        }

        if !dry_run && let Err(e) = fs::remove_file(path) {
            eprintln!("Cannot remove {}: {}", path.display(), e);
        }

        progress.inc(1);
    }
    total
}
