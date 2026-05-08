use indicatif::ProgressBar;
use std::{
    collections::{HashSet, VecDeque},
    fs,
    path::PathBuf,
};
use walkdir::WalkDir;

use crate::store_hash::StoreHash;

pub struct GcRoots {
    queue: VecDeque<PathBuf>,
    seen: HashSet<PathBuf>,
    store_hashes: HashSet<StoreHash>,
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
            queue: VecDeque::with_capacity(1),
            seen: HashSet::new(),
            store_hashes: HashSet::new(),
        }
    }

    pub fn enqueue<P: Into<PathBuf>>(&mut self, path: P) {
        let path = path.into();
        if let Some(hash) = StoreHash::from_store_path(&path) {
            self.store_hashes.insert(hash);
        } else if !path.starts_with("/nix/store") && self.seen.insert(path.clone()) {
            // Garbage roots that point at /nix/store but lack a hash (e.g.
            // /nix/store itself) yield no StoreHash; ignore them rather than
            // recursing into the store.
            self.queue.push_back(path);
        }
    }

    #[must_use]
    pub fn scan(mut self, progress: &ProgressBar) -> HashSet<StoreHash> {
        while let Some(path) = self.queue.pop_front() {
            progress.set_position((self.seen.len() - self.queue.len()) as u64);
            progress.set_length(self.seen.len() as u64);

            for entry in WalkDir::new(path).follow_links(false).into_iter().flatten() {
                if !entry.path_is_symlink() {
                    continue;
                }
                // The symlink may vanish between WalkDir's stat and our
                // read_link; skip it rather than aborting the whole sweep.
                let Ok(target) = fs::read_link(entry.path()) else {
                    eprintln!("Cannot read symlink {}", entry.path().display());
                    continue;
                };
                // Relative symlink targets are relative to the symlink's
                // parent directory, not the process CWD. min_depth(0) means
                // entry can be the WalkDir root itself, which may have no
                // parent; fall back to enqueueing the relative path verbatim.
                let target = match (target.is_absolute(), entry.path().parent()) {
                    (false, Some(parent)) => parent.join(target),
                    _ => target,
                };
                self.enqueue(target);
            }
        }

        self.store_hashes
    }
}
