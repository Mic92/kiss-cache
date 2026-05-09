use std::{env, path::PathBuf, process::ExitCode, time::Duration};

use kiss_cache::{
    prune::{self, Config, Progress},
    with_lock,
};

const USAGE: &str = "\
kiss-cache: a self-hosted Nix binary cache pruner

Usage: kiss-cache <COMMAND>

Commands:
  prune      Trim a binary cache according to GC roots
  with-lock  Run a publish command under a cooperative pruner lock

Run `kiss-cache <COMMAND> --help` for command-specific options.

Options:
  -h, --help     Print help
  -V, --version  Print version";

const PRUNE_USAGE: &str = "\
Trim Nix binary caches according to GC roots

Usage: kiss-cache prune [-n|--dry-run] [--lock-wait <SECS>] <CACHEDIR> <GCROOTS>...

Arguments:
  CACHEDIR    Cache directory
  GCROOTS     Directories of marker files naming store paths to keep

Options:
  -n, --dry-run         Do not actually delete files
      --lock-wait SECS  How long to wait for in-flight uploads [default: 600]
  -h, --help            Print help";

fn parse_prune_args(args: Vec<String>) -> Result<Config, lexopt::Error> {
    use lexopt::prelude::*;

    let mut dry_run = false;
    let mut lock_wait = Duration::from_secs(600);
    let mut positional: Vec<PathBuf> = Vec::new();
    let mut parser = lexopt::Parser::from_args(args);
    while let Some(arg) = parser.next()? {
        match arg {
            Short('n') | Long("dry-run") => dry_run = true,
            Long("lock-wait") => lock_wait = Duration::from_secs(parser.value()?.parse()?),
            Short('h') | Long("help") => {
                println!("{PRUNE_USAGE}");
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
        lock_wait,
    })
}

fn run_prune(args: Vec<String>) -> ExitCode {
    let config = match parse_prune_args(args) {
        Ok(config) => config,
        Err(e) => {
            eprintln!("error: {e}\n\n{PRUNE_USAGE}");
            return ExitCode::from(2);
        }
    };
    let progress = Progress::new(config.dry_run);
    if let Err(e) = prune::run(&config, &progress) {
        eprintln!("error: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn run_with_lock(args: &[String]) -> ExitCode {
    match with_lock::parse_args(args) {
        Ok(args) => with_lock::run(&args),
        Err(e) => {
            eprintln!("error: {e}");
            ExitCode::from(2)
        }
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.split_first() {
        Some((cmd, rest)) if cmd == "prune" => run_prune(rest.to_vec()),
        Some((cmd, rest)) if cmd == "with-lock" => run_with_lock(rest),
        Some((cmd, _)) if cmd == "-h" || cmd == "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some((cmd, _)) if cmd == "-V" || cmd == "--version" => {
            println!("kiss-cache {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some((cmd, _)) => {
            eprintln!("error: unknown command '{cmd}'\n\n{USAGE}");
            ExitCode::from(2)
        }
        None => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}
