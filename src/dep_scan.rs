use std::{
    collections::{HashSet, VecDeque},
    path::PathBuf,
};

use indicatif::ProgressBar;

use crate::binary_cache::BinaryCache;

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

    pub fn scan(mut self, cache: &mut BinaryCache, progress: &ProgressBar) -> HashSet<PathBuf> {
        while let Some(path) = self.queue.pop_front() {
            progress.set_position((self.seen.len() - self.queue.len()) as u64);
            progress.set_length(self.seen.len() as u64);

            if let Ok(info) = cache.get_info_by_store_path(&path) {
                for reference in info.references() {
                    let path = PathBuf::from("/nix/store").join(reference);
                    self.enqueue(path);
                }
                if let Some(deriver) = info.deriver() {
                    let path = PathBuf::from("/nix/store").join(deriver);
                    self.enqueue(path);
                }
            }
        }

        self.seen
    }
}
