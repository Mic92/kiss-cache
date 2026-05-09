//! `kiss-cache with-lock`: run a publish command under a cooperative
//! pruner lock, then write a gcroot marker. Hides the fiddly parts of
//! the lock protocol so CI scripts publish safely with one call.
//!
//! The protocol matches `lock.rs` from the writer's side: take a
//! lock, refresh it while the publish command runs, write the
//! marker, release. Local markers (paths) reuse `lock.rs`'s
//! filesystem polling; remote markers (URLs) shell out to `curl`,
//! which is the only thing that can authenticate against the cache's
//! mTLS or bearer-token front. The server (`nixos/lock-guard.js`)
//! refuses lock PUTs while the pruner is running, so a remote lock
//! landing implies the prune finished.

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, ExitCode},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, SystemTime},
};

use crate::lock::{STALE_AFTER, lock_dir};

/// How often the refresher re-PUTs the lock. Half the staleness
/// threshold leaves slack for slow I/O and clock skew.
const REFRESH_INTERVAL: Duration = Duration::from_secs(5 * 60);
/// Bound every curl so a hung connection cannot block forever.
const CURL_TIMEOUT_SECS: &str = "30";

pub const USAGE: &str = "\
Run a publish command under a kiss-cache pruner lock, then write a
gcroot marker

Usage: kiss-cache with-lock [-h|--help] [--bearer TOKEN]
           <MARKER> <STORE-PATH> [CURL-OPT...] -- <COMMAND>...

Arguments:
  MARKER       The gcroot marker, either a URL
               (https://cache.example.org/gcroots/web1) or a local
               path inside the cache directory
               (/var/lib/nix-cache/gcroots/web1). The lock is taken
               at <gcroots>/.lock/<basename> next to it.
  STORE-PATH   The /nix/store path to write into the marker.
  CURL-OPT     Authentication flags passed to curl, e.g.
               --cert writer.pem --key writer.key --cacert ca.pem.
               Ignored for local markers.
  COMMAND      The publish command, typically `nix copy --to ... ...`.

Options:
  --bearer TOKEN   Send `Authorization: Bearer TOKEN` on every request
                   (OIDC vhost). Also exported to COMMAND as
                   $KISS_CACHE_TOKEN. The whole publish, including
                   COMMAND's own requests, must fit inside the token's
                   lifetime (5 min for GitHub Actions); neither nix nor
                   kiss-cache can refresh a token mid-publish.

The lock is taken before COMMAND, refreshed every 5 minutes while it
runs, and removed afterwards. If the lock cannot be taken the
publish does not run. See docs/pruner.md for the protocol.";

pub struct Args {
    marker: String,
    store_path: String,
    curl_opts: Vec<String>,
    command: Vec<String>,
    bearer: Option<String>,
}

/// Parse `kiss-cache with-lock` arguments. `args` does not include
/// the subcommand name.
///
/// # Errors
///
/// Returns the usage text if arguments are missing or malformed.
pub fn parse_args(args: &[String]) -> Result<Args, String> {
    if matches!(args.first().map(String::as_str), Some("-h" | "--help")) {
        println!("{USAGE}");
        std::process::exit(0);
    }
    let mut it = args.iter().cloned().peekable();
    let mut bearer = None;
    while let Some(flag) = it.peek() {
        match flag.as_str() {
            "--bearer" => {
                it.next();
                bearer = Some(it.next().ok_or("--bearer needs a token")?);
            }
            _ => break,
        }
    }
    let marker = it.next().ok_or(USAGE)?;
    let store_path = it.next().ok_or(USAGE)?;
    let mut curl_opts = Vec::new();
    let mut command = Vec::new();
    let mut sep = false;
    for a in it {
        if sep {
            command.push(a);
        } else if a == "--" {
            sep = true;
        } else {
            curl_opts.push(a);
        }
    }
    if !sep || command.is_empty() {
        return Err(format!("missing '-- COMMAND'\n\n{USAGE}"));
    }
    Ok(Args {
        marker,
        store_path,
        curl_opts,
        command,
        bearer,
    })
}

enum Backend {
    /// Marker is a filesystem path inside the cache directory.
    Local { gcroots: PathBuf },
    /// Marker is an HTTP(S) URL; lock and marker writes go through
    /// curl so they share the cache's authentication front.
    Remote { gcroots: String, curl: Vec<String> },
}

impl Backend {
    fn from_args(args: &Args) -> Self {
        if args.marker.starts_with("http://") || args.marker.starts_with("https://") {
            let gcroots = args
                .marker
                .rsplit_once('/')
                .map_or_else(String::new, |(p, _)| p.to_owned());
            let mut curl = vec![
                "--fail".into(),
                "--silent".into(),
                "--show-error".into(),
                "--max-time".into(),
                CURL_TIMEOUT_SECS.into(),
            ];
            if let Some(token) = &args.bearer {
                curl.push("-H".into());
                curl.push(format!("Authorization: Bearer {token}"));
            }
            curl.extend(args.curl_opts.iter().cloned());
            Backend::Remote { gcroots, curl }
        } else {
            let gcroots = Path::new(&args.marker)
                .parent()
                .map_or_else(PathBuf::new, Path::to_owned);
            Backend::Local { gcroots }
        }
    }

    /// Take the lock. Local mode polls the lock directory directly
    /// (the publish runs on the cache host, bypassing nginx). Remote
    /// mode PUTs through curl, retrying 503 while a prune runs.
    fn put_lock(&self, lock: &str) -> Result<(), String> {
        match self {
            Backend::Local { gcroots } => put_lock_local(&lock_dir(gcroots), Path::new(lock)),
            Backend::Remote { curl, .. } => run_curl(
                curl,
                &[
                    "--retry",
                    "60",
                    "--retry-delay",
                    "5",
                    "--retry-all-errors",
                    "-X",
                    "PUT",
                    "--data",
                    "shared",
                    lock,
                ],
            ),
        }
    }

    /// Refresh the lock. Local mode bumps mtime; remote mode re-PUTs.
    fn refresh_lock(&self, lock: &str) -> Result<(), String> {
        match self {
            Backend::Local { .. } => fs::File::open(lock)
                .and_then(|f| f.set_modified(SystemTime::now()))
                .map_err(|e| format!("cannot refresh lock {lock}: {e}")),
            Backend::Remote { curl, .. } => {
                run_curl(curl, &["-X", "PUT", "--data", "shared", lock])
            }
        }
    }

    fn del_lock(&self, lock: &str) {
        let _ = match self {
            Backend::Local { .. } => fs::remove_file(lock).map_err(|e| e.to_string()),
            Backend::Remote { curl, .. } => run_curl(curl, &["-X", "DELETE", lock]),
        };
    }

    /// Write the marker. Local mode writes a temp file and renames it
    /// for atomicity; remote mode PUTs the body.
    fn put_marker(&self, marker: &str, store_path: &str) -> Result<(), String> {
        match self {
            Backend::Local { gcroots } => {
                // Dot-prefixed temp file so the gcroots scanner
                // (which skips dotfiles) cannot read a half-written
                // or orphaned temp file as a marker.
                let job = Path::new(marker).file_name().unwrap_or_default();
                let tmp = gcroots.join(format!(".{}.tmp", job.to_string_lossy()));
                fs::write(&tmp, format!("{store_path}\n")).map_err(|e| e.to_string())?;
                fs::rename(&tmp, marker).map_err(|e| e.to_string())
            }
            Backend::Remote { curl, .. } => run_curl(
                curl,
                &[
                    "-X",
                    "PUT",
                    "--data-binary",
                    &format!("{store_path}\n"),
                    marker,
                ],
            ),
        }
    }

    fn lock_path(&self, job: &str) -> String {
        match self {
            Backend::Local { gcroots } => lock_dir(gcroots).join(job).display().to_string(),
            Backend::Remote { gcroots, .. } => format!("{gcroots}/.lock/{job}"),
        }
    }
}

fn run_curl(base: &[String], extra: &[&str]) -> Result<(), String> {
    let status = Command::new("curl")
        .args(base)
        .args(extra)
        .status()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("curl failed: {status}"))
    }
}

/// Like [`crate::lock::acquire_exclusive`] but for the writer side:
/// poll until no fresh `prune-*` lock, write our lock, recheck, retry
/// on conflict. The recheck resolves the create/create race with the
/// pruner; both back off if both raced. See `spec/prune.als`.
fn put_lock_local(dir: &Path, lock: &Path) -> Result<(), String> {
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    loop {
        while fresh_prune_lock(dir) {
            eprintln!("kiss-cache with-lock: waiting for prune to finish");
            thread::sleep(Duration::from_secs(5));
        }
        fs::write(lock, "shared\n").map_err(|e| e.to_string())?;
        if !fresh_prune_lock(dir) {
            return Ok(());
        }
        let _ = fs::remove_file(lock);
        thread::sleep(Duration::from_secs(1));
    }
}

fn fresh_prune_lock(dir: &Path) -> bool {
    let Ok(entries) = fs::read_dir(dir) else {
        return false;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.as_encoded_bytes().starts_with(b"prune-") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let Ok(mtime) = meta.modified() else { continue };
        if now.duration_since(mtime).unwrap_or_default() < STALE_AFTER {
            return true;
        }
    }
    false
}

/// Run a publish under a cooperative lock: take, refresh, run
/// command, write marker, release. The lock is named after the
/// marker so a re-run overwrites its own stale lock.
#[must_use]
pub fn run(args: &Args) -> ExitCode {
    let backend = Backend::from_args(args);
    let job = args
        .marker
        .rsplit_once('/')
        .map_or(args.marker.as_str(), |(_, j)| j);
    let lock = backend.lock_path(job);

    if let Err(e) = backend.put_lock(&lock) {
        eprintln!("kiss-cache with-lock: cannot take lock {lock}: {e}; not publishing");
        return ExitCode::FAILURE;
    }

    // Refresher: bump the lock periodically while the command runs.
    // A refresh failure is unsafe to ignore (the lock may have gone
    // stale and a prune could now race us), so it stops the publish.
    let refresh_failed = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let refresher = {
        let backend = Backend::from_args(args);
        let lock = lock.clone();
        let refresh_failed = Arc::clone(&refresh_failed);
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            loop {
                // Wake every second so a stop request is not delayed by
                // the full refresh interval.
                for _ in 0..REFRESH_INTERVAL.as_secs() {
                    if stop.load(Ordering::Relaxed) {
                        return;
                    }
                    thread::sleep(Duration::from_secs(1));
                }
                if backend.refresh_lock(&lock).is_err() {
                    refresh_failed.store(true, Ordering::Relaxed);
                    return;
                }
            }
        })
    };

    let result = run_publish(&backend, args, &lock, &refresh_failed);

    stop.store(true, Ordering::Relaxed);
    let _ = refresher.join();
    backend.del_lock(&lock);
    result
}

fn run_publish(
    backend: &Backend,
    args: &Args,
    lock: &str,
    refresh_failed: &AtomicBool,
) -> ExitCode {
    let mut cmd = Command::new(&args.command[0]);
    cmd.args(&args.command[1..]);
    if let Some(token) = &args.bearer {
        cmd.env("KISS_CACHE_TOKEN", token);
    }
    let status = cmd.status();
    if refresh_failed.load(Ordering::Relaxed) {
        eprintln!("kiss-cache with-lock: lost lock {lock}; publish aborted");
        return ExitCode::FAILURE;
    }
    match status {
        Ok(s) if s.success() => {}
        Ok(s) => {
            eprintln!("kiss-cache with-lock: command failed: {s}");
            return ExitCode::from(s.code().and_then(|c| u8::try_from(c).ok()).unwrap_or(1));
        }
        Err(e) => {
            eprintln!("kiss-cache with-lock: cannot run {}: {e}", args.command[0]);
            return ExitCode::FAILURE;
        }
    }
    if let Err(e) = backend.put_marker(&args.marker, &args.store_path) {
        eprintln!(
            "kiss-cache with-lock: cannot write marker {}: {e}",
            args.marker
        );
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
