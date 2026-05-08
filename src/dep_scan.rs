use std::collections::VecDeque;

use indicatif::ProgressBar;
use rustc_hash::FxHashSet;

use crate::binary_cache::{BinaryCache, Info};
use crate::store_hash::StoreHash;

pub struct DependencyScanner {
    queue: VecDeque<StoreHash>,
    seen: FxHashSet<StoreHash>,
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
            seen: FxHashSet::default(),
        }
    }

    pub fn enqueue(&mut self, hash: StoreHash) {
        if self.seen.insert(hash) {
            self.queue.push_back(hash);
        }
    }

    /// Walk the closure of all enqueued store hashes and return the parsed
    /// `Info` for every one whose narinfo exists in the cache.
    pub fn scan(mut self, cache: &mut BinaryCache, progress: &ProgressBar) -> Vec<Info> {
        // seen already holds all initially-enqueued paths; the closure can
        // only grow from there. Reserving avoids repeated reallocation.
        let mut found = Vec::with_capacity(self.seen.len());
        while let Some(hash) = self.queue.pop_front() {
            progress.set_position((self.seen.len() - self.queue.len()) as u64);
            progress.set_length(self.seen.len() as u64);

            let Ok(info) = cache.get_info_by_hash(hash) else {
                continue;
            };
            for hash in info.references().chain(info.deriver()) {
                self.enqueue(hash);
            }
            found.push(info);
        }
        found
    }
}
