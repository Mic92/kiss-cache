// Benchmarks may unwrap; a panic during setup is the clearest failure mode.
#![allow(clippy::unwrap_used)]

use std::{fmt::Write as _, fs, hint::black_box, os::unix::fs::symlink, path::PathBuf};

use criterion::{Criterion, criterion_group, criterion_main};
use indicatif::ProgressBar;
use nix_cache_cut::{
    binary_cache::BinaryCache,
    dep_scan::DependencyScanner,
    prune::{self, Config, Progress},
};

/// Fabricate a deterministic 32-char fake store hash from an index.
fn fake_hash(i: u32) -> String {
    format!("{i:0>32x}")
}

/// Distinct hash for the deriver. Real Nix store paths and their .drv files
/// never share a hash; reusing one here would let two enqueued store paths
/// resolve to the same narinfo file, which never happens in practice.
fn fake_drv_hash(i: u32) -> String {
    format!("d{i:0>31x}")
}

/// Build a synthetic cache: `n` reachable narinfo files (each referencing a
/// handful of later ones, forming a DAG roughly shaped like a real closure)
/// plus `garbage` unreachable narinfo+nar pairs that the pruner would delete.
fn build_cache(dir: &std::path::Path, n: u32, garbage: u32) {
    fs::create_dir_all(dir.join("nar")).unwrap();
    for i in 0..n {
        let hash = fake_hash(i);
        let mut refs = String::new();
        for j in 1..=8 {
            let r = i + j;
            if r < n {
                let _ = write!(refs, "{}-pkg ", fake_hash(r));
            }
        }
        write_narinfo(dir, &hash, &fake_drv_hash(i), &refs);
    }
    for i in 0..garbage {
        // High bit set so garbage hashes never collide with reachable ones.
        let hash = fake_hash(0x8000_0000 | i);
        write_narinfo(dir, &hash, &fake_drv_hash(0x8000_0000 | i), "");
        fs::write(dir.join(format!("nar/{hash}.nar.xz")), b"garbage").unwrap();
    }
}

fn write_narinfo(dir: &std::path::Path, hash: &str, drv: &str, refs: &str) {
    let narinfo = format!(
        "StorePath: /nix/store/{hash}-pkg\n\
         URL: nar/{hash}.nar.xz\n\
         Compression: xz\n\
         FileHash: sha256:0000000000000000000000000000000000000000000000000000\n\
         FileSize: 12345\n\
         NarHash: sha256:0000000000000000000000000000000000000000000000000000\n\
         NarSize: 67890\n\
         References: {refs}\n\
         Deriver: {drv}-pkg.drv\n\
         Sig: cache.example.org-1:AAAA\n"
    );
    fs::write(dir.join(format!("{hash}.narinfo")), narinfo).unwrap();
}

fn bench_dep_scan(c: &mut Criterion) {
    const N: u32 = 2000;
    let tmp = tempfile::tempdir().unwrap();
    build_cache(tmp.path(), N, 0);
    let progress = ProgressBar::hidden();
    let root = PathBuf::from(format!("/nix/store/{}-pkg", fake_hash(0)));

    let mut group = c.benchmark_group("dep_scan");
    // Default 100 samples is too noisy on a shared CI box for the ~5% deltas
    // we care about; trade longer wall-clock for tighter confidence intervals.
    group.sample_size(500);
    group.bench_function("dep_scan_2000", |b| {
        b.iter(|| {
            // BinaryCache holds an in-process narinfo cache, so re-create it
            // each iteration to measure cold parse + traversal, not HashMap hits.
            let mut cache = BinaryCache::new(tmp.path());
            let mut scanner = DependencyScanner::new();
            scanner.enqueue(root.clone());
            black_box(scanner.scan(&mut cache, &progress));
        });
    });
    group.finish();
}

/// Full end-to-end dry-run: gcroots scan + dependency closure + keep-set
/// construction + both sweep passes. Dry-run so the cache survives between
/// iterations.
fn bench_e2e_dry_run(c: &mut Criterion) {
    const N: u32 = 2000;
    const GARBAGE: u32 = 4000;
    let tmp = tempfile::tempdir().unwrap();
    let cache_dir = tmp.path().join("cache");
    let gcroots_dir = tmp.path().join("gcroots");
    build_cache(&cache_dir, N, GARBAGE);
    fs::create_dir_all(&gcroots_dir).unwrap();
    symlink(
        format!("/nix/store/{}-pkg", fake_hash(0)),
        gcroots_dir.join("root"),
    )
    .unwrap();

    let config = Config {
        dry_run: true,
        cache_dir,
        gcroots: vec![gcroots_dir],
    };

    let mut group = c.benchmark_group("prune");
    group.sample_size(200);
    group.bench_function("e2e_dry_run_2000_keep_4000_drop", |b| {
        b.iter(|| {
            prune::run(black_box(&config), &Progress::hidden());
        });
    });
    group.finish();
}

criterion_group!(benches, bench_dep_scan, bench_e2e_dry_run);
criterion_main!(benches);
