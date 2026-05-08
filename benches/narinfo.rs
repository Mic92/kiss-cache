// Benchmarks may unwrap; a panic during setup is the clearest failure mode.
#![allow(clippy::unwrap_used)]

use std::{fmt::Write as _, fs, hint::black_box, path::PathBuf};

use criterion::{Criterion, criterion_group, criterion_main};
use indicatif::ProgressBar;
use nix_cache_cut::{binary_cache::BinaryCache, dep_scan::DependencyScanner};

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

/// Build a synthetic cache: `n` narinfo files, each referencing a handful of
/// later ones, forming a DAG roughly shaped like a real closure.
fn build_cache(dir: &std::path::Path, n: u32) {
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
             Sig: cache.example.org-1:AAAA\n",
            drv = fake_drv_hash(i),
        );
        fs::write(dir.join(format!("{hash}.narinfo")), narinfo).unwrap();
    }
}

fn bench_dep_scan(c: &mut Criterion) {
    const N: u32 = 2000;
    let tmp = tempfile::tempdir().unwrap();
    build_cache(tmp.path(), N);
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

criterion_group!(benches, bench_dep_scan);
criterion_main!(benches);
