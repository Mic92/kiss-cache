use indicatif::ProgressBar;
use std::{
    collections::{HashSet, VecDeque},
    fs,
    path::PathBuf,
};
use walkdir::WalkDir;

pub struct GcRoots {
    queue: VecDeque<PathBuf>,
    seen: HashSet<PathBuf>,
    store_paths: HashSet<PathBuf>,
}

impl Default for GcRoots {
    fn default() -> Self {
        Self::new()
    }
}

impl GcRoots {
    pub fn new() -> Self {
        GcRoots {
            queue: VecDeque::with_capacity(1),
            seen: HashSet::new(),
            store_paths: HashSet::new(),
        }
    }

    fn add_store_path(&mut self, mut path: PathBuf) {
        let components = path.components().count();
        for _ in 4..components {
            path.pop();
        }
        self.store_paths.insert(path);
    }

    pub fn enqueue<P: Into<PathBuf>>(&mut self, path: P) {
        let path = path.into();
        if path.starts_with("/nix/store") {
            self.add_store_path(path);
        } else if self.seen.insert(path.clone()) {
            self.queue.push_back(path);
        }
    }

    pub fn scan(mut self, progress: &ProgressBar) -> HashSet<PathBuf> {
        while let Some(path) = self.queue.pop_front() {
            progress.set_position((self.seen.len() - self.queue.len()) as u64);
            progress.set_length(self.seen.len() as u64);

            for entry in WalkDir::new(path).follow_links(false).into_iter().flatten() {
                if entry.path_is_symlink() {
                    let target = fs::read_link(entry.path()).expect("read_link");
                    self.enqueue(target);
                }
            }
        }

        self.store_paths
    }
}
