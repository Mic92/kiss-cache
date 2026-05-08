use indicatif::ProgressBar;
use rustc_hash::FxHashSet;
use std::{
    collections::VecDeque,
    fs,
    path::{Path, PathBuf},
};

use crate::store_hash::StoreHash;

pub struct GcRoots {
    queue: VecDeque<PathBuf>,
    seen: FxHashSet<PathBuf>,
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
            queue: VecDeque::with_capacity(1),
            seen: FxHashSet::default(),
            store_hashes: FxHashSet::default(),
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

    /// Walk all enqueued roots, follow indirect roots (directories and
    /// symlink chains), and return the set of store hashes they point at.
    #[must_use]
    pub fn scan(mut self, progress: &ProgressBar) -> FxHashSet<StoreHash> {
        while let Some(path) = self.queue.pop_front() {
            progress.set_position((self.seen.len() - self.queue.len()) as u64);
            progress.set_length(self.seen.len() as u64);

            // The path can vanish or become unreadable between being
            // enqueued and being visited; skip rather than abort.
            let Ok(meta) = fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_symlink() {
                self.follow_symlink(&path);
            } else if meta.is_dir() {
                self.recurse_into(&path);
            }
            // Plain files (e.g. lock files under gcroots/profiles) carry no
            // root information.
        }

        self.store_hashes
    }

    fn follow_symlink(&mut self, path: &Path) {
        let Ok(target) = fs::read_link(path) else {
            eprintln!("Cannot read symlink {}", path.display());
            return;
        };
        // Relative symlink targets are relative to the symlink's parent
        // directory, not the process CWD. A root path may have no parent;
        // fall back to enqueueing the relative target verbatim.
        let target = match (target.is_absolute(), path.parent()) {
            (false, Some(parent)) => parent.join(target),
            _ => target,
        };
        self.enqueue(target);
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
