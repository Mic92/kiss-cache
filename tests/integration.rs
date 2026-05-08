// In tests, panicking on a fixture-setup failure is exactly what we want.
#![allow(clippy::unwrap_used, clippy::expect_used)]

//! End-to-end test: build a fake binary cache and a gcroots tree on disk,
//! run the compiled binary against them, and assert which files survive.

use std::{fs, os::unix::fs::symlink, path::PathBuf, process::Command};

/// 32-character base32 nix store hashes (must be exactly 32 chars so that
/// `/nix/store/<hash>` is 43 bytes, matching the slicing in `binary_cache.rs`).
const HASH_ROOT: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const HASH_DEP: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const HASH_DRV: &str = "cccccccccccccccccccccccccccccccc";
const HASH_GARBAGE: &str = "dddddddddddddddddddddddddddddddd";

struct Fixture {
    tmp: tempfile::TempDir,
    cache: PathBuf,
    gcroots: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let cache = tmp.path().join("cache");
        let gcroots = tmp.path().join("gcroots");
        fs::create_dir_all(cache.join("nar")).unwrap();
        fs::create_dir_all(&gcroots).unwrap();
        Fixture {
            tmp,
            cache,
            gcroots,
        }
    }

    /// Create `<hash>.narinfo` plus its referenced `nar/<hash>.nar.xz` archive.
    fn add_narinfo(&self, hash: &str, name: &str, references: &[&str], deriver: Option<&str>) {
        let url = format!("nar/{hash}.nar.xz");
        let nar_path = self.cache.join(&url);
        fs::write(&nar_path, b"fake nar contents").unwrap();
        let nar_size = fs::metadata(&nar_path).unwrap().len();

        let refs = references
            .iter()
            .map(|h| format!("{h}-ref"))
            .collect::<Vec<_>>()
            .join(" ");
        let deriver_line = deriver
            .map(|h| format!("Deriver: {h}-{name}.drv\n"))
            .unwrap_or_default();
        let narinfo = format!(
            "StorePath: /nix/store/{hash}-{name}\n\
             URL: {url}\n\
             Compression: xz\n\
             FileHash: sha256:0000000000000000000000000000000000000000000000000000\n\
             FileSize: {nar_size}\n\
             NarHash: sha256:0000000000000000000000000000000000000000000000000000\n\
             NarSize: {nar_size}\n\
             References: {refs}\n\
             {deriver_line}"
        );
        fs::write(self.cache.join(format!("{hash}.narinfo")), narinfo).unwrap();
    }

    /// Create a gcroot symlink pointing at /nix/store/<hash>-<name>.
    fn add_gcroot(&self, link_name: &str, hash: &str, name: &str) {
        symlink(
            format!("/nix/store/{hash}-{name}"),
            self.gcroots.join(link_name),
        )
        .unwrap();
    }

    fn run(&self, dry_run: bool) {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_nix-cache-cut"));
        if dry_run {
            cmd.arg("-n");
        }
        cmd.arg(&self.cache).arg(&self.gcroots);
        let out = cmd.output().unwrap();
        assert!(
            out.status.success(),
            "exit={:?}\nstdout:\n{}\nstderr:\n{}",
            out.status,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr),
        );
    }

    fn narinfo_exists(&self, hash: &str) -> bool {
        self.cache.join(format!("{hash}.narinfo")).exists()
    }

    fn nar_exists(&self, hash: &str) -> bool {
        self.cache.join(format!("nar/{hash}.nar.xz")).exists()
    }
}

fn standard_fixture() -> Fixture {
    let fx = Fixture::new();
    // root -> dep (via References), root -> drv (via Deriver)
    fx.add_narinfo(HASH_ROOT, "root", &[HASH_DEP], Some(HASH_DRV));
    fx.add_narinfo(HASH_DEP, "dep", &[], None);
    fx.add_narinfo(HASH_DRV, "root.drv", &[], None);
    // unreachable from any gcroot
    fx.add_narinfo(HASH_GARBAGE, "garbage", &[], None);
    fx.add_gcroot("my-root", HASH_ROOT, "root");
    fx
}

#[test]
fn keeps_reachable_deletes_garbage() {
    let fx = standard_fixture();
    fx.run(false);

    for hash in [HASH_ROOT, HASH_DEP, HASH_DRV] {
        assert!(fx.narinfo_exists(hash), "{hash}.narinfo should be kept");
        assert!(fx.nar_exists(hash), "{hash}.nar.xz should be kept");
    }
    assert!(!fx.narinfo_exists(HASH_GARBAGE), "garbage narinfo deleted");
    assert!(!fx.nar_exists(HASH_GARBAGE), "garbage nar deleted");
}

#[test]
fn dry_run_deletes_nothing() {
    let fx = standard_fixture();
    fx.run(true);

    for hash in [HASH_ROOT, HASH_DEP, HASH_DRV, HASH_GARBAGE] {
        assert!(
            fx.narinfo_exists(hash),
            "{hash}.narinfo untouched in dry-run"
        );
        assert!(fx.nar_exists(hash), "{hash}.nar.xz untouched in dry-run");
    }
}

/// A gcroot can also be a plain file whose basename is `<hash>-<name>`.
/// Remote builders pushing to the cache via HTTP cannot create symlinks,
/// so they register roots by `PUT`ing an empty marker file to the gcroots
/// directory. The pruner must treat that file like a symlink to
/// `/nix/store/<basename>`.
#[test]
fn gcroot_marker_file_is_a_root() {
    let fx = Fixture::new();
    fx.add_narinfo(HASH_ROOT, "root", &[], None);
    fx.add_narinfo(HASH_GARBAGE, "garbage", &[], None);
    fs::write(fx.gcroots.join(format!("{HASH_ROOT}-root")), "").unwrap();

    fx.run(false);
    assert!(fx.narinfo_exists(HASH_ROOT));
    assert!(!fx.narinfo_exists(HASH_GARBAGE));
}

#[test]
fn gcroot_in_nested_dir_is_followed() {
    let fx = Fixture::new();
    fx.add_narinfo(HASH_ROOT, "root", &[], None);
    fx.add_narinfo(HASH_GARBAGE, "garbage", &[], None);
    // gcroots are scanned recursively
    let nested = fx.gcroots.join("auto/per-user");
    fs::create_dir_all(&nested).unwrap();
    symlink(
        format!("/nix/store/{HASH_ROOT}-root"),
        nested.join("result"),
    )
    .unwrap();

    fx.run(false);
    assert!(fx.narinfo_exists(HASH_ROOT));
    assert!(!fx.narinfo_exists(HASH_GARBAGE));
}

/// A gcroot symlink pointing at a store path that is too short to contain
/// a hash (e.g. /nix/store itself). Such garbage roots should be skipped,
/// not crash the whole run.
#[test]
fn short_store_path_root_is_skipped() {
    let fx = standard_fixture();
    symlink("/nix/store", fx.gcroots.join("bogus-root")).unwrap();

    fx.run(false);
    assert!(fx.narinfo_exists(HASH_ROOT));
    assert!(!fx.narinfo_exists(HASH_GARBAGE));
}

/// A reachable but malformed narinfo (missing required fields) must not
/// abort the run; it should just be skipped, leaving the rest of the cache
/// pruned correctly.
#[test]
fn malformed_narinfo_is_skipped() {
    let fx = standard_fixture();
    // Reachable from HASH_ROOT via References, but truncated.
    fs::write(
        fx.cache.join(format!("{HASH_DEP}.narinfo")),
        format!("StorePath: /nix/store/{HASH_DEP}-dep\n"),
    )
    .unwrap();

    fx.run(false);
    assert!(fx.narinfo_exists(HASH_ROOT), "good root kept");
    assert!(!fx.narinfo_exists(HASH_GARBAGE), "garbage deleted");
}

/// A non-dry-run pass writes a persistent closure cache. If a reachable
/// narinfo is then deleted out of band, the cached entry must not keep its
/// archive alive forever: the next run should notice the file is gone and
/// sweep the archive.
#[test]
fn closure_cache_does_not_resurrect_deleted_narinfo() {
    let fx = standard_fixture();
    // First pass: deletes garbage, writes the closure cache for ROOT/DEP/DRV.
    fx.run(false);
    assert!(fx.narinfo_exists(HASH_DEP));
    assert!(fx.nar_exists(HASH_DEP));

    // Delete DEP's narinfo out of band (e.g. cache repair, manual cleanup).
    fs::remove_file(fx.cache.join(format!("{HASH_DEP}.narinfo"))).unwrap();

    // Second pass: DEP's narinfo is gone, so its archive is orphaned and
    // must be swept even though the closure cache remembers it.
    fx.run(false);
    assert!(!fx.nar_exists(HASH_DEP), "orphaned nar must be swept");
    assert!(fx.narinfo_exists(HASH_ROOT));
    assert!(fx.nar_exists(HASH_ROOT));
}

/// A gcroot directory containing a *relative* symlink to another directory,
/// which in turn holds the actual store-path symlink. Nix produces such
/// chains (e.g. profiles/system -> system-1-link). The relative target must
/// be resolved against the symlink's parent directory, not the process CWD;
/// otherwise the real root is missed and its archives get deleted.
#[test]
fn relative_symlink_in_gcroots_is_resolved() {
    let fx = Fixture::new();
    fx.add_narinfo(HASH_ROOT, "root", &[], None);
    fx.add_narinfo(HASH_GARBAGE, "garbage", &[], None);

    // <tmp>/profiles/result -> /nix/store/<hash>-root
    let profiles = fx.tmp.path().join("profiles");
    fs::create_dir_all(&profiles).unwrap();
    symlink(
        format!("/nix/store/{HASH_ROOT}-root"),
        profiles.join("result"),
    )
    .unwrap();
    // <tmp>/gcroots/indirect -> ../profiles  (relative!)
    symlink("../profiles", fx.gcroots.join("indirect")).unwrap();

    fx.run(false);
    assert!(
        fx.narinfo_exists(HASH_ROOT),
        "root reachable via relative symlink must be kept"
    );
    assert!(!fx.narinfo_exists(HASH_GARBAGE));
}
