use rustc_hash::FxHashSet;
use std::{
    collections::VecDeque,
    fs,
    path::{Path, PathBuf},
};

use crate::{progress::Phase, store_hash::StoreHash};

/// Collects store hashes from a tree of marker files.
///
/// A marker file is a plain file whose content is one or more
/// `/nix/store/<hash>-<name>` paths, one per line. The file name is not
/// interpreted: writers pick whatever is convenient (e.g. a CI job ID).
/// Lines that do not parse as a store path are ignored so unrelated files
/// in a roots directory are harmless.
///
/// Directories are recursed into. Symlinks are not followed: the gcroots
/// tree is populated only by HTTP `PUT` of regular files, and following
/// symlinks would let a marker escape it.
pub struct GcRoots {
    queue: VecDeque<PathBuf>,
    seen: usize,
    store_hashes: FxHashSet<StoreHash>,
}

impl Default for GcRoots {
    fn default() -> Self {
        Self::new()
    }
}

impl GcRoots {
    #[must_use]
    pub fn new() -> Self {
        GcRoots {
            queue: VecDeque::new(),
            seen: 0,
            store_hashes: FxHashSet::default(),
        }
    }

    pub fn enqueue<P: Into<PathBuf>>(&mut self, path: P) {
        self.queue.push_back(path.into());
    }

    #[must_use]
    pub fn scan(mut self, progress: &Phase) -> FxHashSet<StoreHash> {
        while let Some(path) = self.queue.pop_front() {
            self.seen += 1;
            progress.set_position(self.seen as u64);
            progress.set_length((self.seen + self.queue.len()) as u64);

            // Entries can vanish between readdir and visit; skip rather
            // than abort.
            let Ok(meta) = fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_dir() {
                self.recurse_into(&path);
            } else if meta.is_file() {
                self.read_marker_file(&path);
            }
        }

        self.store_hashes
    }

    fn read_marker_file(&mut self, path: &Path) {
        let Ok(content) = fs::read_to_string(path) else {
            eprintln!("Cannot read marker file {}", path.display());
            return;
        };
        for line in content.lines() {
            if let Some(hash) = StoreHash::from_store_path(Path::new(line.trim())) {
                self.store_hashes.insert(hash);
            }
        }
    }

    fn recurse_into(&mut self, dir: &Path) {
        let Ok(entries) = fs::read_dir(dir) else {
            eprintln!("Cannot read directory {}", dir.display());
            return;
        };
        for entry in entries.flatten() {
            self.enqueue(entry.path());
        }
    }
}
