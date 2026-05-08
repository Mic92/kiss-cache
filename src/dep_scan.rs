use std::{
    collections::VecDeque,
    sync::mpsc,
    thread::{self, available_parallelism},
};

use rustc_hash::FxHashSet;

use crate::binary_cache::{BinaryCache, NarInfo};
use crate::closure_cache;
use crate::progress::Phase;
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

    /// Walk the closure of all enqueued store hashes and return parsed
    /// metadata for every one whose narinfo exists in the cache (or is
    /// already in `closures`).
    ///
    /// Hashes already present in `closures` are answered with a cheap `stat()`
    /// instead of a full open + read + parse; the stat is needed so a narinfo
    /// deleted out of band does not keep its archive alive forever via the
    /// cache. The rest are read by a worker pool, since the cost is dominated
    /// by reading one `.narinfo` per hash and the kernel can serve those reads
    /// concurrently. The coordinator owns the visited set, dedups, and
    /// dispatches new hashes discovered in `References`/`Deriver`.
    pub fn scan(
        mut self,
        cache: &BinaryCache,
        closures: &closure_cache::Map,
        progress: &Phase,
    ) -> Vec<(StoreHash, NarInfo)> {
        let workers = available_parallelism().map_or(1, std::num::NonZero::get);
        // seen already holds all initially-enqueued hashes; the closure can
        // only grow from there. Reserving avoids repeated reallocation.
        let mut found = Vec::with_capacity(self.seen.len());
        let high_water = workers * 4;

        thread::scope(|scope| {
            // One bounded channel per worker, round-robined, so a slow
            // narinfo read cannot starve the pool. Bounded channels use
            // array-backed storage rather than allocating a node per send,
            // and the small per-worker backlog keeps receivers from parking,
            // which keeps futex wakes off the dispatch hot path.
            let (done_tx, done_rx) = mpsc::sync_channel::<(StoreHash, Option<NarInfo>)>(high_water);
            let mut work_txs = Vec::with_capacity(workers);
            for _ in 0..workers {
                // bool: true if the hash was a closure-cache hit and the
                // worker only needs to verify the narinfo still exists.
                let (work_tx, work_rx) = mpsc::sync_channel::<(StoreHash, bool)>(4);
                work_txs.push(work_tx);
                let done_tx = done_tx.clone();
                scope.spawn(move || {
                    while let Ok((hash, cached)) = work_rx.recv() {
                        let info = if cached {
                            // The coordinator already has the parsed metadata;
                            // all the worker needs to do is confirm the file
                            // was not deleted out of band.
                            cache.narinfo_exists(hash).then(NarInfo::default)
                        } else {
                            cache.get_info_by_hash(hash).ok()
                        };
                        if done_tx.send((hash, info)).is_err() {
                            return;
                        }
                    }
                });
            }
            drop(done_tx);

            let mut in_flight = 0usize;
            let mut next_worker = 0usize;
            loop {
                while in_flight < high_water
                    && let Some(hash) = self.queue.pop_front()
                {
                    let cached = closures.contains_key(&hash);
                    if work_txs[next_worker % workers]
                        .send((hash, cached))
                        .is_err()
                    {
                        return;
                    }
                    next_worker += 1;
                    in_flight += 1;
                }
                if in_flight == 0 {
                    break;
                }

                let Ok((hash, result)) = done_rx.recv() else {
                    break;
                };
                in_flight -= 1;
                progress.set_length(self.seen.len() as u64);
                progress.set_position((self.seen.len() - self.queue.len() - in_flight) as u64);
                if result.is_none() {
                    continue;
                }
                // Workers return a placeholder NarInfo for confirmed cache
                // hits; the real metadata is in `closures`.
                let info = closures.get(&hash).cloned().or(result);
                let Some(info) = info else { continue };
                for hash in info.references.iter().chain(&info.deriver) {
                    self.enqueue(*hash);
                }
                found.push((hash, info));
            }
            // Closing the work channels makes workers exit their recv loop.
            drop(work_txs);
        });

        found
    }
}
