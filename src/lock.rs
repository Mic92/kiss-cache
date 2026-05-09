//! Restic-style cooperative locking via `gcroots/.lock/`.
//!
//! Writers and the pruner each hold a lock file while running.
//! A fresh lock from another holder blocks; a stale one (crashed
//! holder) is ignored. `WebDAV` has no test-and-set, so both sides
//! create-then-recheck and back off on conflict. Safety is verified
//! in `spec/prune.als`; liveness is probabilistic.

use std::{
    fs, io,
    path::{Path, PathBuf},
    process,
    time::{Duration, SystemTime},
};

/// Locks older than this are ignored; holders refresh at half this
/// interval.
pub const STALE_AFTER: Duration = Duration::from_secs(30 * 60);

/// Lock file content. The pruner does not read it, but a tag helps
/// humans tell who holds what.
const EXCLUSIVE: &[u8] = b"exclusive\n";

pub const LOCK_DIR: &str = ".lock";

#[must_use]
pub fn lock_dir(gcroots: &Path) -> PathBuf {
    gcroots.join(LOCK_DIR)
}

#[derive(Debug)]
struct LockEntry {
    name: PathBuf,
    age: Duration,
}

impl LockEntry {
    fn is_stale(&self) -> bool {
        self.age > STALE_AFTER
    }
}

/// Reads the lock directory; missing directory means no locks.
fn read_locks(dir: &Path) -> io::Result<Vec<LockEntry>> {
    let now = SystemTime::now();
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut locks = Vec::new();
    for entry in entries {
        let entry = entry?;
        let meta = entry.metadata()?;
        if !meta.is_file() {
            continue;
        }
        let age = now
            .duration_since(meta.modified()?)
            .unwrap_or(Duration::ZERO);
        locks.push(LockEntry {
            name: entry.path(),
            age,
        });
    }
    Ok(locks)
}

/// An exclusive lock held by the pruner. Dropping it removes the
/// lock file. A SIGKILL leaves the file behind, which other parties
/// ignore once it goes stale.
#[derive(Debug)]
pub struct ExclusiveLock {
    path: PathBuf,
}

impl Drop for ExclusiveLock {
    fn drop(&mut self) {
        if let Err(e) = fs::remove_file(&self.path) {
            eprintln!("Cannot remove lock {}: {e}", self.path.display());
        }
    }
}

#[derive(Debug)]
pub enum LockError {
    /// Fresh locks did not drain within the wait budget.
    Busy(Vec<PathBuf>),
    Io(io::Error),
}

impl std::fmt::Display for LockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockError::Busy(locks) => {
                write!(f, "cache is busy; fresh locks remain:")?;
                for l in locks {
                    write!(f, " {}", l.display())?;
                }
                Ok(())
            }
            LockError::Io(e) => write!(f, "{e}"),
        }
    }
}

impl From<io::Error> for LockError {
    fn from(e: io::Error) -> Self {
        LockError::Io(e)
    }
}

/// Acquire an exclusive lock: poll until no fresh lock from another
/// holder remains, create ours, recheck, back off and retry on
/// conflict.
///
/// # Errors
///
/// [`LockError::Busy`] if locks did not drain within `wait_budget`;
/// [`LockError::Io`] on filesystem errors.
pub fn acquire_exclusive(
    gcroots_dir: &Path,
    wait_budget: Duration,
    poll: Duration,
) -> Result<ExclusiveLock, LockError> {
    let dir = lock_dir(gcroots_dir);
    fs::create_dir_all(&dir)?;
    let id = format!("prune-{}-{:08x}", process::id(), rand_token());
    let path = dir.join(&id);

    let deadline = SystemTime::now() + wait_budget;
    loop {
        let fresh: Vec<_> = read_locks(&dir)?
            .into_iter()
            .filter(|l| !l.is_stale() && l.name != path)
            .collect();
        if fresh.is_empty() {
            // Create then re-check: a writer may have raced its own
            // shared lock in between.
            fs::write(&path, EXCLUSIVE)?;
            let competing: Vec<_> = read_locks(&dir)?
                .into_iter()
                .filter(|l| !l.is_stale() && l.name != path)
                .map(|l| l.name)
                .collect();
            if competing.is_empty() {
                return Ok(ExclusiveLock { path });
            }
            fs::remove_file(&path).ok();
            eprintln!("Lost the lock race to {competing:?}, retrying");
        }
        if SystemTime::now() >= deadline {
            let names: Vec<_> = fresh.into_iter().map(|l| l.name).collect();
            return Err(LockError::Busy(names));
        }
        std::thread::sleep(poll);
    }
}

/// Cheap uniqueness for lock file names: PID xor sub-second clock
/// guards against rapid PID reuse without pulling in a `rand` dep.
fn rand_token() -> u32 {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    nanos ^ process::id()
}

#[cfg(test)]
// In tests, panicking on a fixture-setup failure is exactly what we want.
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn write_lock(dir: &Path, name: &str, kind: &[u8], age: Duration) {
        let path = dir.join(name);
        fs::write(&path, kind).unwrap();
        fs::File::open(&path)
            .unwrap()
            .set_modified(SystemTime::now() - age)
            .unwrap();
    }

    #[test]
    fn acquires_when_no_locks() {
        let tmp = tempdir().unwrap();
        let lock = acquire_exclusive(tmp.path(), Duration::ZERO, Duration::ZERO).unwrap();
        let dir = lock_dir(tmp.path());
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
        drop(lock);
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
    }

    #[test]
    fn refuses_when_fresh_shared_lock_held() {
        let tmp = tempdir().unwrap();
        let dir = lock_dir(tmp.path());
        fs::create_dir_all(&dir).unwrap();
        write_lock(&dir, "ci-job", b"shared\n", Duration::from_secs(10));
        let err = acquire_exclusive(tmp.path(), Duration::ZERO, Duration::ZERO).unwrap_err();
        assert!(matches!(err, LockError::Busy(_)));
        // Did not leave a dangling lock behind.
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
    }

    #[test]
    fn ignores_stale_shared_lock() {
        let tmp = tempdir().unwrap();
        let dir = lock_dir(tmp.path());
        fs::create_dir_all(&dir).unwrap();
        write_lock(
            &dir,
            "crashed-ci-job",
            b"shared\n",
            STALE_AFTER + Duration::from_secs(1),
        );
        let lock = acquire_exclusive(tmp.path(), Duration::ZERO, Duration::ZERO).unwrap();
        drop(lock);
        // The stale lock is left for its (dead) owner to clean up.
        assert_eq!(fs::read_dir(&dir).unwrap().count(), 1);
    }
}
