use std::{
    collections::VecDeque,
    sync::mpsc,
    thread::{self, available_parallelism},
};

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
    ///
    /// The cost is dominated by opening and reading one `.narinfo` per store
    /// hash, which the kernel can serve concurrently. Workers parse files in
    /// parallel; the coordinator owns `seen`, dedups, and dispatches new
    /// hashes discovered in `References`/`Deriver`.
    pub fn scan(mut self, cache: &BinaryCache, progress: &ProgressBar) -> Vec<Info> {
        let workers = available_parallelism().map_or(1, std::num::NonZero::get);
        if workers <= 1 {
            return self.scan_serial(cache, progress);
        }

        // seen already holds all initially-enqueued hashes; the closure can
        // only grow from there. Reserving avoids repeated reallocation.
        let mut found = Vec::with_capacity(self.seen.len());

        thread::scope(|scope| {
            // One channel per worker; the coordinator round-robins dispatches
            // and never gives a worker more than two outstanding items, so a
            // slow narinfo read cannot starve the rest of the pool.
            let (done_tx, done_rx) = mpsc::channel::<Option<Info>>();
            let mut work_txs = Vec::with_capacity(workers);
            for _ in 0..workers {
                let (work_tx, work_rx) = mpsc::channel::<StoreHash>();
                work_txs.push(work_tx);
                let done_tx = done_tx.clone();
                scope.spawn(move || {
                    while let Ok(hash) = work_rx.recv() {
                        let info = cache.get_info_by_hash(hash).ok();
                        if done_tx.send(info).is_err() {
                            return;
                        }
                    }
                });
            }
            drop(done_tx);

            let mut in_flight = 0usize;
            let mut next_worker = 0usize;
            let high_water = workers * 2;
            loop {
                while in_flight < high_water
                    && let Some(hash) = self.queue.pop_front()
                {
                    if work_txs[next_worker % workers].send(hash).is_err() {
                        return;
                    }
                    next_worker += 1;
                    in_flight += 1;
                }
                if in_flight == 0 {
                    break;
                }

                let Ok(result) = done_rx.recv() else { break };
                in_flight -= 1;
                progress.set_length(self.seen.len() as u64);
                progress.set_position((self.seen.len() - self.queue.len() - in_flight) as u64);
                let Some(info) = result else { continue };
                for hash in info.references().chain(info.deriver()) {
                    self.enqueue(hash);
                }
                found.push(info);
            }
            // Closing the work channels makes workers exit their recv loop.
            drop(work_txs);
        });

        found
    }

    fn scan_serial(mut self, cache: &BinaryCache, progress: &ProgressBar) -> Vec<Info> {
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
