use std::{collections::HashSet, fs, path::Path, process::ExitCode};

use indicatif::{HumanBytes, MultiProgress, ProgressBar, ProgressStyle};
use walkdir::WalkDir;

mod binary_cache;
mod dep_scan;
mod gcroots;

const USAGE: &str = "\
Trim Nix binary caches according to GC roots

Usage: nix-cache-cut [-n|--dry-run] <CACHEDIR> [GCROOTS...]

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Garbage collector roots [default: /nix/var/nix/gcroots]

Options:
  -n, --dry-run  Do not actually delete files
  -h, --help     Print help
  -V, --version  Print version";

struct Args {
    dry_run: bool,
    cache_dir: String,
    gcroots: Vec<String>,
}

fn parse_args() -> Result<Args, lexopt::Error> {
    use lexopt::prelude::*;

    let mut dry_run = false;
    let mut positional = Vec::new();
    let mut parser = lexopt::Parser::from_env();
    while let Some(arg) = parser.next()? {
        match arg {
            Short('n') | Long("dry-run") => dry_run = true,
            Short('h') | Long("help") => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            Short('V') | Long("version") => {
                println!("nix-cache-cut {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            Value(v) => positional.push(v.string()?),
            _ => return Err(arg.unexpected()),
        }
    }

    let mut positional = positional.into_iter();
    let cache_dir = positional
        .next()
        .ok_or("missing required argument CACHEDIR")?;
    let mut gcroots: Vec<String> = positional.collect();
    if gcroots.is_empty() {
        gcroots.push("/nix/var/nix/gcroots".to_owned());
    }

    Ok(Args {
        dry_run,
        cache_dir,
        gcroots,
    })
}

fn main() -> ExitCode {
    let args = match parse_args() {
        Ok(args) => args,
        Err(e) => {
            eprintln!("error: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    run(&args);
    ExitCode::SUCCESS
}

fn run(args: &Args) {
    let make_spinner = |color| {
        ProgressStyle::with_template(
            &"{spinner} {prefix:.bold.dim} {wide_bar:.COLOR} [{pos:.bold.dim}/{len:.bold}] {msg}"
                .replace("COLOR", color),
        )
        .unwrap()
        .tick_chars("⠁⠂⠄⡀⢀⠠⠐⠈ ")
    };
    let progress = MultiProgress::new();
    let progress_gcroots = progress.add(ProgressBar::new(0));
    progress_gcroots.set_prefix("Scanning GCROOTS");
    progress_gcroots.set_style(make_spinner("green.dim"));
    let progress_scanner = progress.add(ProgressBar::new(1));
    progress_scanner.set_prefix("Scanning dependencies");
    progress_scanner.set_style(make_spinner("green"));
    progress_scanner.tick();
    let progress_keep = progress.add(ProgressBar::new(1));
    progress_keep.set_prefix("Retaining archives");
    progress_keep.set_style(make_spinner("yellow"));
    progress_keep.tick();
    let msg_prefix = if args.dry_run { "NOT " } else { "" };
    let progress_rm_narinfo = progress.add(ProgressBar::new(1));
    progress_rm_narinfo.set_prefix(format!("{msg_prefix}Deleting .narinfo files"));
    progress_rm_narinfo.set_style(make_spinner("red"));
    progress_rm_narinfo.tick();
    let progress_rm_nar = progress.add(ProgressBar::new(1));
    progress_rm_nar.set_prefix(format!("{msg_prefix}Deleting .nar files"));
    progress_rm_nar.set_style(make_spinner("red.dim"));
    progress_rm_nar.tick();

    // Scan garbage-collector roots
    let mut gcroots = gcroots::GcRoots::new();
    for gcroot in &args.gcroots {
        gcroots.enqueue(gcroot);
    }
    let store_paths = gcroots.scan(&progress_gcroots);
    progress_gcroots.finish();

    // Construct cache abstraction
    let mut cache = binary_cache::BinaryCache::new(&args.cache_dir);
    // Scan gcroots dependencies
    let mut scanner = dep_scan::DependencyScanner::new();
    for path in store_paths {
        scanner.enqueue(path);
    }
    let scanner_seen = scanner.scan(&mut cache, &progress_scanner);
    progress_scanner.finish();

    // Statistics
    let (mut file_size, mut nar_size) = (0u64, 0u64);
    // Set of files to keep
    progress_keep.set_length(scanner_seen.len() as u64);
    let mut keep_infos = HashSet::with_capacity(scanner_seen.len());
    let mut keep_archives = HashSet::with_capacity(scanner_seen.len());
    let cache_path = cache.path.clone();
    for path in scanner_seen {
        let result = cache.get_info_by_store_path(&path).ok();
        progress_keep.inc(1);
        let Some(info) = result else { continue };
        keep_infos.insert(info.path);
        keep_archives.insert(cache_path.join(info.fields.get("URL").unwrap()));
        file_size += info.fields.get("FileSize").unwrap().parse::<u64>().unwrap();
        nar_size += info.fields.get("NarSize").unwrap().parse::<u64>().unwrap();
        progress_keep.set_message(format!(
            "{} in {} archive files",
            HumanBytes(nar_size),
            HumanBytes(file_size)
        ));
    }
    // free memory early
    drop(cache);
    progress_keep.finish_with_message(format!(
        "{} in {} archive files",
        HumanBytes(nar_size),
        HumanBytes(file_size)
    ));

    let rm_narinfo_size = sweep(&cache_path, &progress_rm_narinfo, args.dry_run, |path| {
        path.extension().is_some_and(|ext| ext == "narinfo") && !keep_infos.contains(path)
    });
    drop(keep_infos);
    progress_rm_narinfo.finish_with_message(format!("{}", HumanBytes(rm_narinfo_size)));

    let rm_nar_size = sweep(
        &cache_path.join("nar"),
        &progress_rm_nar,
        args.dry_run,
        |path| !keep_archives.contains(path),
    );
    drop(keep_archives);
    progress_rm_nar.finish_with_message(format!("{}", HumanBytes(rm_nar_size)));
}

/// Walk `dir` (depth 1) and delete every entry for which `should_delete` returns true.
/// Returns total size of matched files. Honors `dry_run`.
fn sweep(
    dir: &Path,
    progress: &ProgressBar,
    dry_run: bool,
    should_delete: impl Fn(&Path) -> bool,
) -> u64 {
    let mut total = 0;
    progress.set_length(0);
    for entry in WalkDir::new(dir).min_depth(1).max_depth(1) {
        let entry = entry.unwrap();
        let path = entry.path();
        if !should_delete(path) {
            continue;
        }
        progress.inc_length(1);

        if let Ok(meta) = fs::metadata(path) {
            total += meta.len();
            progress.set_message(format!("{}", HumanBytes(total)));
        } else {
            eprintln!("Cannot stat {}", path.display());
        }

        if !dry_run && let Err(e) = fs::remove_file(path) {
            eprintln!("Cannot remove {}: {}", path.display(), e);
        }

        progress.inc(1);
    }
    total
}
