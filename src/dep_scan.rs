use std::{
    collections::{HashSet, VecDeque},
    path::PathBuf,
};

use indicatif::ProgressBar;

use crate::binary_cache::{BinaryCache, Info};

pub struct DependencyScanner {
    queue: VecDeque<PathBuf>,
    seen: HashSet<PathBuf>,
}

impl Default for DependencyScanner {
    fn default() -> Self {
        Self::new()
    }
}

impl DependencyScanner {
    #[must_use]
    pub fn new() -> Self {
        DependencyScanner {
            queue: VecDeque::with_capacity(1),
            seen: HashSet::new(),
        }
    }

    pub fn enqueue(&mut self, path: PathBuf) {
        if self.seen.insert(path.clone()) {
            self.queue.push_back(path);
        }
    }

    /// Walk the closure of all enqueued store paths and return the parsed
    /// `Info` for every one whose narinfo exists in the cache.
    pub fn scan(mut self, cache: &mut BinaryCache, progress: &ProgressBar) -> Vec<Info> {
        // seen already holds all initially-enqueued paths; the closure can
        // only grow from there. Reserving avoids repeated reallocation.
        let mut found = Vec::with_capacity(self.seen.len());
        while let Some(path) = self.queue.pop_front() {
            progress.set_position((self.seen.len() - self.queue.len()) as u64);
            progress.set_length(self.seen.len() as u64);

            let Ok(info) = cache.get_info_by_store_path(&path) else {
                continue;
            };
            for reference in info.references() {
                self.enqueue(PathBuf::from("/nix/store").join(reference));
            }
            if let Some(deriver) = info.deriver() {
                self.enqueue(PathBuf::from("/nix/store").join(deriver));
            }
            found.push(info);
        }
        found
    }
}
