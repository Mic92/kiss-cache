use std::{path::PathBuf, process::ExitCode};

use kiss_cache::prune::{self, Config, Progress};

const USAGE: &str = "\
Trim Nix binary caches according to GC roots

Usage: kiss-cache [-n|--dry-run] <CACHEDIR> <GCROOTS>...

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Directories of marker files naming store paths to keep

Options:
  -n, --dry-run  Do not actually delete files
  -h, --help     Print help
  -V, --version  Print version";

fn parse_args() -> Result<Config, lexopt::Error> {
    use lexopt::prelude::*;

    let mut dry_run = false;
    let mut positional: Vec<PathBuf> = Vec::new();
    let mut parser = lexopt::Parser::from_env();
    while let Some(arg) = parser.next()? {
        match arg {
            Short('n') | Long("dry-run") => dry_run = true,
            Short('h') | Long("help") => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            Short('V') | Long("version") => {
                println!("kiss-cache {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            Value(v) => positional.push(v.into()),
            _ => return Err(arg.unexpected()),
        }
    }

    let mut positional = positional.into_iter();
    let cache_dir = positional
        .next()
        .ok_or("missing required argument CACHEDIR")?;
    let gcroots: Vec<PathBuf> = positional.collect();
    if gcroots.is_empty() {
        return Err("missing required argument GCROOTS".into());
    }

    Ok(Config {
        dry_run,
        cache_dir,
        gcroots,
    })
}

fn main() -> ExitCode {
    let config = match parse_args() {
        Ok(config) => config,
        Err(e) => {
            eprintln!("error: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let progress = Progress::new(config.dry_run);
    prune::run(&config, &progress);
    ExitCode::SUCCESS
}
